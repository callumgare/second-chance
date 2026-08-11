import Foundation
import AppKit
import CoreGraphics
import Vision
import Accelerate
import os

private let logger = Logger(subsystem: "com.secondchance.gamepuppeteer", category: "ComputerVision")

// Get environment variable for extra debugging
private let findImageExtraDebugging = Foundation.ProcessInfo.processInfo.environment["FIND_IMAGE_EXTRA_DEBUGGING"] == "true"

// MARK: - OCR & Screenshot

enum ScreenshotOCR {
    // Cache for template to avoid reconverting and downscaling on every search
    private static var cachedTemplate: (path: String, gray: vImage_Buffer, downscaled: vImage_Buffer)?
    
    /// Load cached template match location from disk
    private static func loadCachedLocation() -> TemplateMatchCache? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: cacheFilePath)),
              let cache = try? JSONDecoder().decode(TemplateMatchCache.self, from: data) else {
            return nil
        }
        return cache
    }
    
    /// Save template match location to disk for next run
    private static func saveCachedLocation(x: Int, y: Int) {
        let cache = TemplateMatchCache(x: x, y: y, timestamp: Date().timeIntervalSince1970)
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: URL(fileURLWithPath: cacheFilePath))
        }
    }
    
    /// Take a screenshot and return the file path
    static func captureScreen() -> String? {
        let timestamp = Int(Date().timeIntervalSince1970)
        let screenshotPath = "/tmp/game-test-\(timestamp).png"
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", screenshotPath]
        
        do {
            try task.run()
            task.waitUntilExit()
            
            if task.terminationStatus == 0 {
                return screenshotPath
            }
        } catch {
            logger.error("⚠️  Failed to capture screenshot: \(error, privacy: .public)")
        }
        
        return nil
    }
    
    /// Test template match quality at a specific position with detailed debug output
    private static func testSpecificPositionMatch(
        screenshotPath: String,
        templatePath: String,
        templateCG: CGImage,
        screenshotCG: CGImage,
        baseHeightRatio: CGFloat,
        screenshotData: UnsafePointer<UInt8>,
        screenshotWidth: Int,
        screenshotHeight: Int,
        debugX: Int,
        debugY: Int,
        searchStartX: Int,
        searchStartY: Int
    ) {
        logger.notice("  🔍 DEBUG: Testing match at specific position...")
        logger.notice("     Position: (\(debugX, privacy: .public), \(debugY, privacy: .public))")
        
        // Use the same scaling logic as the main search algorithm
        let targetHeight = CGFloat(screenshotCG.height) * baseHeightRatio
        let templateScaleFactor = targetHeight / CGFloat(templateCG.height)
        let targetWidth = CGFloat(templateCG.width) * templateScaleFactor
        let debugWidth = Int(targetWidth)
        let debugHeight = Int(targetHeight)
        
        logger.notice("     Template original size: \(templateCG.width, privacy: .public)x\(templateCG.height, privacy: .public)")
        logger.notice("     Scaled template size: \(debugWidth, privacy: .public)x\(debugHeight, privacy: .public) (scale factor: \(String(format: "%.4f", templateScaleFactor), privacy: .public))")
        
        // Scale the template using algorithm's scaling
        guard let debugScaledTemplate = scaleImage(templateCG, to: CGSize(width: debugWidth, height: debugHeight)) else {
            return
        }
        
        // Save color template BEFORE grayscale conversion
        let colorTemplatePath = screenshotPath.replacingOccurrences(of: ".png", with: "-debug-color-template.png")
        let colorTemplateImage = NSImage(cgImage: debugScaledTemplate, size: NSSize(width: debugWidth, height: debugHeight))
        if let tiffData = colorTemplateImage.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            try? pngData.write(to: URL(fileURLWithPath: colorTemplatePath))
            logger.notice("     💾 Saved color template (before conversion): \(colorTemplatePath, privacy: .public)")
        }
        
        guard let debugTemplateGray = convertToGrayscale(cgImage: debugScaledTemplate) else {
            return
        }
        
        let debugTemplateData = debugTemplateGray.data.assumingMemoryBound(to: UInt8.self)
        
        // Calculate correlation at this exact position
        let debugCorrelation = calculateNormalizedCorrelation(
            screenshot: screenshotData,
            screenshotWidth: screenshotWidth,
            screenshotHeight: screenshotHeight,
            template: debugTemplateData,
            templateWidth: debugWidth,
            templateHeight: debugHeight,
            offsetX: debugX,
            offsetY: debugY,
            sampleStep: 1
        )
        
        logger.notice("     Correlation: \(String(format: "%.4f", debugCorrelation), privacy: .public)")
        
        // Save grayscale template for inspection
        let grayTemplateImage = NSImage(size: NSSize(width: debugWidth, height: debugHeight))
        grayTemplateImage.lockFocus()
        if let grayContext = NSGraphicsContext.current?.cgContext {
            let colorSpace = CGColorSpaceCreateDeviceGray()
            if let provider = CGDataProvider(data: Data(bytes: debugTemplateData, count: debugWidth * debugHeight) as CFData),
               let grayImage = CGImage(width: debugWidth, height: debugHeight, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: debugWidth, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
                grayContext.draw(grayImage, in: CGRect(x: 0, y: 0, width: debugWidth, height: debugHeight))
            }
        }
        grayTemplateImage.unlockFocus()
        
        let grayTemplatePath = screenshotPath.replacingOccurrences(of: ".png", with: "-debug-gray-template.png")
        if let tiffData = grayTemplateImage.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            try? pngData.write(to: URL(fileURLWithPath: grayTemplatePath))
            logger.notice("     💾 Saved grayscale template: \(grayTemplatePath, privacy: .public)")
        }
        
        // Save grayscale screenshot region for comparison
        logger.notice("     DEBUG grayRegionImage extraction:")
        logger.notice("       screenshotData dimensions: \(screenshotWidth, privacy: .public)x\(screenshotHeight, privacy: .public)")
        logger.notice("       debugX=\(debugX, privacy: .public), debugY=\(debugY, privacy: .public)")
        logger.notice("       debugWidth=\(debugWidth, privacy: .public), debugHeight=\(debugHeight, privacy: .public)")
        logger.notice("       Extracting region: (\(debugX, privacy: .public),\(debugY, privacy: .public)) to (\(debugX+debugWidth, privacy: .public),\(debugY+debugHeight, privacy: .public))")
        
        let grayRegionImage = NSImage(size: NSSize(width: debugWidth, height: debugHeight))
        grayRegionImage.lockFocus()
        if let grayContext = NSGraphicsContext.current?.cgContext {
            let colorSpace = CGColorSpaceCreateDeviceGray()
            var regionData = [UInt8](repeating: 0, count: debugWidth * debugHeight)
            var pixelsOutOfBounds = 0
            for y in 0..<debugHeight {
                for x in 0..<debugWidth {
                    let srcX = debugX + x
                    let srcY = debugY + y
                    if srcX < screenshotWidth && srcY < screenshotHeight {
                        regionData[y * debugWidth + x] = screenshotData[srcY * screenshotWidth + srcX]
                    } else {
                        pixelsOutOfBounds += 1
                    }
                }
            }
            if pixelsOutOfBounds > 0 {
                logger.error("       ⚠️  \(pixelsOutOfBounds, privacy: .public) pixels out of bounds!")
            }
            if let provider = CGDataProvider(data: Data(regionData) as CFData),
               let grayImage = CGImage(width: debugWidth, height: debugHeight, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: debugWidth, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
                grayContext.draw(grayImage, in: CGRect(x: 0, y: 0, width: debugWidth, height: debugHeight))
            }
        }
        grayRegionImage.unlockFocus()
        
        let grayRegionPath = screenshotPath.replacingOccurrences(of: ".png", with: "-debug-gray-region.png")
        if let tiffData = grayRegionImage.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            try? pngData.write(to: URL(fileURLWithPath: grayRegionPath))
            logger.notice("     💾 Saved grayscale screenshot region: \(grayRegionPath, privacy: .public)")
        }
        
        // Save grayscale screenshot of entire search region with box around sampled area
        let grayFullRegionImage = NSImage(size: NSSize(width: screenshotWidth, height: screenshotHeight))
        grayFullRegionImage.lockFocus()
        if let grayContext = NSGraphicsContext.current?.cgContext {
            let colorSpace = CGColorSpaceCreateDeviceGray()
            if let provider = CGDataProvider(data: Data(bytes: screenshotData, count: screenshotWidth * screenshotHeight) as CFData),
               let grayImage = CGImage(width: screenshotWidth, height: screenshotHeight, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: screenshotWidth, space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
                grayContext.draw(grayImage, in: CGRect(x: 0, y: 0, width: screenshotWidth, height: screenshotHeight))
            }
        }
        
        // Draw box around the sampled region
        NSColor.systemYellow.setStroke()
        let sampledRect = CGRect(
            x: CGFloat(debugX),
            y: CGFloat(screenshotHeight - debugY - debugHeight),
            width: CGFloat(debugWidth),
            height: CGFloat(debugHeight)
        )
        let boxPath = NSBezierPath(rect: sampledRect)
        boxPath.lineWidth = 3.0
        boxPath.stroke()
        
        grayFullRegionImage.unlockFocus()
        
        let grayFullRegionPath = screenshotPath.replacingOccurrences(of: ".png", with: "-debug-gray-full-region.png")
        if let tiffData = grayFullRegionImage.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            try? pngData.write(to: URL(fileURLWithPath: grayFullRegionPath))
            logger.notice("     💾 Saved grayscale full search region: \(grayFullRegionPath, privacy: .public)")
        }
        
        // Create detailed debug visualization
        createDebugVisualization(
            screenshotPath: screenshotPath,
            templatePath: templatePath,
            debugX: debugX,
            debugY: debugY,
            debugWidth: debugWidth,
            debugHeight: debugHeight,
            debugCorrelation: debugCorrelation,
            searchStartX: searchStartX,
            searchStartY: searchStartY
        )
        
        free(debugTemplateGray.data)
    }
    
    /// Create heatmap visualization showing correlation scores across search region
    private static func createHeatmapVisualization(
        screenshotPath: String,
        scalePercent: Int,
        templateWidth: Int,
        templateHeight: Int,
        screenshotData: UnsafePointer<UInt8>,
        screenshotWidth: Int,
        screenshotHeight: Int,
        templateData: UnsafePointer<UInt8>,
        searchStartX: Int,
        searchStartY: Int,
        searchEndX: Int,
        searchEndY: Int,
        coarseStride: Int
    ) {
        guard let debugImage = NSImage(contentsOfFile: screenshotPath),
              let cgImage = debugImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }
        
        let imageHeight = cgImage.height
        let heatmapPath = screenshotPath.replacingOccurrences(of: ".png", with: "-heatmap-scale\(scalePercent).png")
        
        let newImage = NSImage(size: debugImage.size)
        newImage.lockFocus()
        debugImage.draw(at: .zero, from: NSRect(origin: .zero, size: debugImage.size), operation: .copy, fraction: 1.0)
        
        // Draw heatmap cells for each position we checked
        for y in Swift.stride(from: searchStartY, to: searchEndY - templateHeight, by: coarseStride) {
            for x in Swift.stride(from: searchStartX, to: searchEndX - templateWidth, by: coarseStride) {
                let correlation = calculateNormalizedCorrelation(
                    screenshot: screenshotData,
                    screenshotWidth: screenshotWidth,
                    screenshotHeight: screenshotHeight,
                    template: templateData,
                    templateWidth: templateWidth,
                    templateHeight: templateHeight,
                    offsetX: x,
                    offsetY: y,
                    sampleStep: 1
                )
                
                // Map correlation to color (blue=low, green=medium, red=high)
                let hue: CGFloat
                let saturation: CGFloat = 1.0
                let brightness: CGFloat = 1.0
                let alpha: CGFloat = 0.5
                let corr = CGFloat(correlation)
                
                if corr < 0 {
                    hue = 0.66  // Blue for negative/no correlation
                } else if corr < 0.5 {
                    // Blue (0.66) to cyan (0.5) for 0-0.5
                    hue = 0.66 - (corr * 0.32)
                } else if corr < 0.7 {
                    // Cyan (0.5) to green (0.33) for 0.5-0.7
                    hue = 0.5 - ((corr - 0.5) * 0.85)
                } else if corr < 0.85 {
                    // Green (0.33) to yellow (0.16) for 0.7-0.85
                    hue = 0.33 - ((corr - 0.7) * 1.13)
                } else {
                    // Yellow (0.16) to red (0.0) for 0.85-1.0
                    hue = 0.16 - ((corr - 0.85) * 1.07)
                }
                
                let color = NSColor(calibratedHue: hue, saturation: saturation, brightness: brightness, alpha: alpha)
                color.setFill()
                
                // Convert to bottom-left coordinates
                let rect = NSRect(
                    x: CGFloat(x),
                    y: CGFloat(imageHeight - y - templateHeight),
                    width: CGFloat(templateWidth),
                    height: CGFloat(templateHeight)
                )
                NSBezierPath(rect: rect).fill()
            }
        }
        
        // Draw scale info
        let scaleLabel = "Scale: \(scalePercent)% - Template: \(templateWidth)x\(templateHeight)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .bold),
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black,
            .strokeWidth: -4.0
        ]
        (scaleLabel as NSString).draw(at: CGPoint(x: 10, y: CGFloat(imageHeight) - 30), withAttributes: attributes)
        
        // Draw legend
        let legendY = CGFloat(imageHeight) - 60
        let legendColors: [(label: String, hue: CGFloat)] = [
            ("< 0", 0.66),
            ("0.5", 0.5),
            ("0.7", 0.33),
            ("0.85", 0.16),
            ("1.0", 0.0)
        ]
        
        for (index, item) in legendColors.enumerated() {
            let x = CGFloat(10 + index * 60)
            let rect = NSRect(x: x, y: legendY, width: 50, height: 20)
            NSColor(calibratedHue: item.hue, saturation: 1.0, brightness: 1.0, alpha: 0.8).setFill()
            NSBezierPath(rect: rect).fill()
            NSColor.black.setStroke()
            NSBezierPath(rect: rect).stroke()
            
            let labelAttr: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: NSColor.white,
                .strokeColor: NSColor.black,
                .strokeWidth: -3.0
            ]
            (item.label as NSString).draw(at: CGPoint(x: x + 5, y: legendY + 3), withAttributes: labelAttr)
        }
        
        newImage.unlockFocus()
        
        if let tiffData = newImage.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            try? pngData.write(to: URL(fileURLWithPath: heatmapPath))
            logger.notice("    💾 Saved heatmap: \(heatmapPath, privacy: .public)")
        }
    }
    
    /// Create debug visualization showing template match at specific position
    private static func createDebugVisualization(
        screenshotPath: String,
        templatePath: String,
        debugX: Int,
        debugY: Int,
        debugWidth: Int,
        debugHeight: Int,
        debugCorrelation: Float,
        searchStartX: Int,
        searchStartY: Int
    ) {
        guard let debugImage = NSImage(contentsOfFile: screenshotPath),
              let cgImage = debugImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }
        
        let imageWidth = cgImage.width
        let imageHeight = cgImage.height
        let debugPath = screenshotPath.replacingOccurrences(of: ".png", with: "-debug-specific-position.png")
        
        // Convert cropped region coordinates to full screenshot coordinates
        let fullDebugX = debugX + searchStartX
        let fullDebugY = debugY + searchStartY
        
        logger.notice("     Screenshot dimensions: \(imageWidth, privacy: .public)x\(imageHeight, privacy: .public)")
        logger.notice("     Test position (cropped region): (\(debugX, privacy: .public), \(debugY, privacy: .public))")
        logger.notice("     Test position (full screenshot): (\(fullDebugX, privacy: .public), \(fullDebugY, privacy: .public))")
        
        // Check if coordinates are within bounds of full screenshot
        let inBounds = fullDebugX >= 0 && fullDebugY >= 0 &&
                      fullDebugX + debugWidth <= imageWidth &&
                      fullDebugY + debugHeight <= imageHeight
        logger.notice("     Position in bounds: \(inBounds, privacy: .public)")
        
        if !inBounds {
            if fullDebugX < 0 { logger.error("       ⚠️  X coordinate (\(fullDebugX, privacy: .public)) is negative") }
            if fullDebugY < 0 { logger.error("       ⚠️  Y coordinate (\(fullDebugY, privacy: .public)) is negative") }
            if fullDebugX + debugWidth > imageWidth {
                logger.error("       ⚠️  Right edge (\(fullDebugX + debugWidth, privacy: .public)) exceeds image width (\(imageWidth, privacy: .public))")
            }
            if fullDebugY + debugHeight > imageHeight {
                logger.error("       ⚠️  Bottom edge (\(fullDebugY + debugHeight, privacy: .public)) exceeds image height (\(imageHeight, privacy: .public))")
            }
        }
        
        let newImage = NSImage(size: debugImage.size)
        newImage.lockFocus()
        debugImage.draw(at: .zero, from: NSRect(origin: .zero, size: debugImage.size), operation: .copy, fraction: 1.0)
        
        // Draw the test region (convert to macOS coordinate system with bottom-left origin)
        let testRect = CGRect(
            x: CGFloat(fullDebugX),
            y: CGFloat(imageHeight - fullDebugY - debugHeight),
            width: CGFloat(debugWidth),
            height: CGFloat(debugHeight)
        )
        
        logger.notice("     Overlay rect (bottom-left origin): x=\(testRect.origin.x, privacy: .public), y=\(testRect.origin.y, privacy: .public), w=\(testRect.width, privacy: .public), h=\(testRect.height, privacy: .public)")
        
        // Overlay template with transparency
        if let templateImage = NSImage(contentsOfFile: templatePath) {
            let scaledTemplate = NSImage(size: NSSize(width: debugWidth, height: debugHeight))
            scaledTemplate.lockFocus()
            templateImage.draw(in: NSRect(origin: .zero, size: scaledTemplate.size))
            scaledTemplate.unlockFocus()
            
            scaledTemplate.draw(at: testRect.origin, from: NSRect(origin: .zero, size: scaledTemplate.size), operation: NSCompositingOperation.sourceOver, fraction: 0.5)
        }
        
        // Draw border
        let borderColor: NSColor = debugCorrelation >= 0.85 ? .systemGreen : (debugCorrelation >= 0.7 ? .systemYellow : .systemRed)
        borderColor.setStroke()
        let border = NSBezierPath(rect: testRect)
        border.lineWidth = 4.0
        border.stroke()
        
        // Draw info label
        let label = "Test Position: (\(fullDebugX), \(fullDebugY))\nSize: \(debugWidth)x\(debugHeight)\nCorrelation: \(String(format: "%.4f", debugCorrelation))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .bold),
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black,
            .strokeWidth: -4.0
        ]
        let labelRect = NSRect(x: testRect.origin.x + 5, y: testRect.origin.y + testRect.height + 10, width: 400, height: 100)
        (label as NSString).draw(in: labelRect, withAttributes: attributes)
        
        newImage.unlockFocus()
        
        if let tiffData = newImage.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            try? pngData.write(to: URL(fileURLWithPath: debugPath))
            logger.notice("     💾 Saved debug visualization: \(debugPath, privacy: .public)")
        }
    }
    
    /// Create visualization showing search region boundaries
    private static func createSearchRegionVisualization(
        screenshotPath: String,
        searchStartX: Int,
        searchStartY: Int,
        searchEndX: Int,
        searchEndY: Int
    ) {
        guard let debugImage = NSImage(contentsOfFile: screenshotPath),
              let cgImage = debugImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }
        
        let debugPath = screenshotPath.replacingOccurrences(of: ".png", with: "-search-region.png")
        let imageHeight = cgImage.height
        
        // Draw search region rectangle (convert from top-left to bottom-left coordinates)
        let searchRect = CGRect(
            x: CGFloat(searchStartX),
            y: CGFloat(imageHeight - searchEndY),
            width: CGFloat(searchEndX - searchStartX),
            height: CGFloat(searchEndY - searchStartY)
        )
        
        // Create annotated image and save directly
        let newImage = NSImage(size: debugImage.size)
        newImage.lockFocus()
        debugImage.draw(at: .zero, from: NSRect(origin: .zero, size: debugImage.size), operation: .copy, fraction: 1.0)
        
        NSColor.systemRed.withAlphaComponent(0.3).setFill()
        NSBezierPath(rect: searchRect).fill()
        NSColor.systemRed.setStroke()
        let border = NSBezierPath(rect: searchRect)
        border.lineWidth = 3.0
        border.stroke()
        
        let label = "Search Region"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .bold),
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black,
            .strokeWidth: -3.0
        ]
        let labelSize = (label as NSString).size(withAttributes: attributes)
        (label as NSString).draw(at: CGPoint(x: searchRect.origin.x + 5, y: searchRect.origin.y + searchRect.height - labelSize.height - 5), withAttributes: attributes)
        
        newImage.unlockFocus()
        
        if let tiffData = newImage.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            try? pngData.write(to: URL(fileURLWithPath: debugPath))
            logger.notice("  💾 Saved search region: \(debugPath, privacy: .public)")
        }
    }
    
    /// Create visualization showing all candidate matches found at all scales
    private static func createAllMatchesVisualization(
        screenshotPath: String,
        allScaleMatches: [(scaleIndex: Int, scale: CGFloat, matches: [(x: Int, y: Int, correlation: Float)])],
        scaledTemplates: [(scale: CGFloat, cgImage: CGImage, width: Int, height: Int)]
    ) {
        guard let debugImage = NSImage(contentsOfFile: screenshotPath),
              let cgImage = debugImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }
        
        let imageHeight = cgImage.height
        let debugPath = screenshotPath.replacingOccurrences(of: ".png", with: "-all-matches.png")
        
        let newImage = NSImage(size: debugImage.size)
        newImage.lockFocus()
        debugImage.draw(at: .zero, from: NSRect(origin: .zero, size: debugImage.size), operation: .copy, fraction: 1.0)
        
        // Show top 5 matches from each scale
        for scaleMatch in allScaleMatches {
            let topMatches = scaleMatch.matches.sorted { $0.correlation > $1.correlation }.prefix(5)
            for (index, match) in topMatches.enumerated() {
                let scalePercent = Int(scaleMatch.scale * 100)
                let templateInfo = scaledTemplates[scaleMatch.scaleIndex]
                
                // Convert from top-left to bottom-left coordinates
                let rect = CGRect(
                    x: CGFloat(match.x),
                    y: CGFloat(imageHeight - match.y - templateInfo.height),
                    width: CGFloat(templateInfo.width),
                    height: CGFloat(templateInfo.height)
                )
                
                // Draw semi-transparent box
                NSColor.systemBlue.withAlphaComponent(0.2).setFill()
                NSBezierPath(rect: rect).fill()
                
                // Draw border
                NSColor.systemBlue.setStroke()
                let border = NSBezierPath(rect: rect)
                border.lineWidth = 2.0
                border.stroke()
                
                // Draw label
                let label = "S\(scalePercent)%-#\(index+1): \(String(format: "%.2f", match.correlation))"
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 12, weight: .bold),
                    .foregroundColor: NSColor.white,
                    .strokeColor: NSColor.black,
                    .strokeWidth: -3.0
                ]
                (label as NSString).draw(at: CGPoint(x: rect.origin.x + 2, y: rect.origin.y + 2), withAttributes: attributes)
            }
        }
        
        newImage.unlockFocus()
        
        if let tiffData = newImage.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            try? pngData.write(to: URL(fileURLWithPath: debugPath))
            logger.notice("  💾 Saved all matches visualization: \(debugPath, privacy: .public)")
        }
    }
    
    /// Create visualization showing the final matched template location
    private static func createFinalMatchVisualization(
        screenshotPath: String,
        matchX: Int,
        matchY: Int,
        templateWidth: Int,
        templateHeight: Int,
        correlation: Float
    ) {
        guard let debugImage = NSImage(contentsOfFile: screenshotPath),
              let cgImage = debugImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }
        
        let imageHeight = cgImage.height
        let matchRect = CGRect(
            x: CGFloat(matchX),
            y: CGFloat(imageHeight - matchY - templateHeight),
            width: CGFloat(templateWidth),
            height: CGFloat(templateHeight)
        )
        let debugPath = screenshotPath.replacingOccurrences(of: ".png", with: "-final-match.png")
        
        let newImage = NSImage(size: debugImage.size)
        newImage.lockFocus()
        debugImage.draw(at: .zero, from: NSRect(origin: .zero, size: debugImage.size), operation: .copy, fraction: 1.0)
        
        NSColor.systemGreen.withAlphaComponent(0.3).setFill()
        NSBezierPath(rect: matchRect).fill()
        NSColor.systemGreen.setStroke()
        let border = NSBezierPath(rect: matchRect)
        border.lineWidth = 3.0
        border.stroke()
        
        let label = "Match: \(String(format: "%.2f", correlation))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .bold),
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black,
            .strokeWidth: -3.0
        ]
        let labelSize = (label as NSString).size(withAttributes: attributes)
        (label as NSString).draw(at: CGPoint(x: matchRect.origin.x + 5, y: matchRect.origin.y + matchRect.height - labelSize.height - 5), withAttributes: attributes)
        
        newImage.unlockFocus()
        
        if let tiffData = newImage.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            try? pngData.write(to: URL(fileURLWithPath: debugPath))
            logger.notice("  💾 Saved final match: \(debugPath, privacy: .public)")
        }
    }
    
    /// Scale a CGImage to a specific size
    private static func scaleImage(_ image: CGImage, to size: CGSize) -> CGImage? {
        // Use RGB color space for compatibility
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        
        // Use a standard RGBA format that's widely supported
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0, // Let system calculate
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            logger.error("    ⚠️  Failed to create CGContext for scaling")
            return nil
        }
        
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        
        return context.makeImage()
    }
    
    /// Find a template image within a screenshot using Accelerate framework
    static func findImage(_ templatePath: String, in screenshotPath: String, minConfidence: Float = 0.5) -> CGRect? {
        let startTime = Date()
        var stepStartTime = Date()
        logger.notice("\n⏱️  Starting template matching...")
        
        guard let screenshot = NSImage(contentsOfFile: screenshotPath),
              let screenshotCG = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let template = NSImage(contentsOfFile: templatePath),
              let templateCG = template.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            logger.error("⚠️  Failed to load images for template matching")
            return nil
        }
        logger.notice("⏱️  [\(String(format: "%.3f", Date().timeIntervalSince(stepStartTime)), privacy: .public)s] Loaded images")
        stepStartTime = Date()
        
        // Use only base scale of 6.62% of screenshot height for careful search
        let baseHeightRatio: CGFloat = 0.0662
        let scaleVariations: [CGFloat] = [1.0] // Base scale only
        
        var scaledTemplates: [(scale: CGFloat, cgImage: CGImage, width: Int, height: Int)] = []
        
        for variation in scaleVariations {
            let targetHeightRatio = baseHeightRatio * variation
            let targetHeight = CGFloat(screenshotCG.height) * targetHeightRatio
            let templateScaleFactor = targetHeight / CGFloat(templateCG.height)
            let targetWidth = CGFloat(templateCG.width) * templateScaleFactor
            
            if let scaledTemplate = scaleImage(templateCG, to: CGSize(width: Int(targetWidth), height: Int(targetHeight))) {
                scaledTemplates.append((scale: variation, cgImage: scaledTemplate, width: Int(targetWidth), height: Int(targetHeight)))
            }
        }
        
        if scaledTemplates.isEmpty {
            logger.error("⚠️  Failed to create any scaled templates")
            return nil
        }
        
        logger.notice("  → Prepared \(scaledTemplates.count, privacy: .public) template scales (\(scaleVariations.map { Int($0 * 100) }.map { "\($0)%" }.joined(separator: ", "), privacy: .public))")
        logger.notice("⏱️  [\(String(format: "%.3f", Date().timeIntervalSince(stepStartTime)), privacy: .public)s] Scaled templates")
        stepStartTime = Date()
        
        if findImageExtraDebugging {
            // Save template image for debugging
            if let templateNS = NSImage(contentsOfFile: templatePath) {
                let templateDebugPath = screenshotPath.replacingOccurrences(of: ".png", with: "-template.png")
                if let tiffData = templateNS.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiffData),
                   let pngData = bitmap.representation(using: .png, properties: [:]) {
                    try? pngData.write(to: URL(fileURLWithPath: templateDebugPath))
                    logger.notice("  💾 Saved template: \(templateDebugPath, privacy: .public)")
                }
            }
            logger.notice("⏱️  [\(String(format: "%.3f", Date().timeIntervalSince(stepStartTime)), privacy: .public)s] Saved debug template")
            stepStartTime = Date()
        }
        
        // Calculate search region BEFORE converting to grayscale
        // Search in bottom-right corner (bottom sixth AND right third intersection)
        let fullWidth = screenshotCG.width
        let fullHeight = screenshotCG.height
        let searchStartX = (fullWidth * 2) / 3  // Right third starts at 2/3
        let searchStartY = (fullHeight * 5) / 6  // Bottom sixth starts at 5/6
        let searchWidth = fullWidth - searchStartX
        let searchHeight = fullHeight - searchStartY
        
        logger.notice("  → Full screenshot: \(fullWidth, privacy: .public)x\(fullHeight, privacy: .public)")
        logger.notice("  → Search region: x[\(searchStartX, privacy: .public)-\(fullWidth, privacy: .public)], y[\(searchStartY, privacy: .public)-\(fullHeight, privacy: .public)] (\(searchWidth, privacy: .public)x\(searchHeight, privacy: .public))")
        
        // Crop screenshot to search region only (huge performance win!)
        let searchRect = CGRect(x: searchStartX, y: searchStartY, width: searchWidth, height: searchHeight)
        guard let croppedScreenshot = screenshotCG.cropping(to: searchRect) else {
            logger.error("⚠️  Failed to crop screenshot to search region")
            return nil
        }
        
        // Convert ONLY the cropped region to grayscale (18x faster!)
        guard let screenshotGray = convertToGrayscale(cgImage: croppedScreenshot) else {
            logger.error("⚠️  Failed to convert screenshot to grayscale")
            return nil
        }
        logger.notice("⏱️  [\(String(format: "%.3f", Date().timeIntervalSince(stepStartTime)), privacy: .public)s] Converted search region to grayscale")
        stepStartTime = Date()
        
        // Use cached template or create new one
        let templateGray: vImage_Buffer
        let templateSmall: vImage_Buffer
        
        if let cached = cachedTemplate, cached.path == templatePath {
            // Reuse cached template
            templateGray = cached.gray
            templateSmall = cached.downscaled
        } else {
            // Free old cached template if it exists
            if let old = cachedTemplate {
                free(old.gray.data)
                free(old.downscaled.data)
            }
            
            // Convert and downscale new template
            guard let newTemplateGray = convertToGrayscale(cgImage: templateCG) else {
                logger.error("⚠️  Failed to convert template to grayscale")
                free(screenshotGray.data)
                return nil
            }
            
            let scale = 2
            guard let newTemplateSmall = downscaleBuffer(newTemplateGray, scale: scale) else {
                logger.error("⚠️  Failed to downscale template")
                free(screenshotGray.data)
                free(newTemplateGray.data)
                return nil
            }
            
            // Cache the template
            templateGray = newTemplateGray
            templateSmall = newTemplateSmall
            cachedTemplate = (templatePath, newTemplateGray, newTemplateSmall)
        }
        
        // Now working with cropped screenshot, so coordinates are relative to crop
        let screenshotWidth = Int(screenshotGray.width)   // This is searchWidth
        let screenshotHeight = Int(screenshotGray.height) // This is searchHeight
        
        // Since we cropped to search region, search the entire cropped image
        let cropSearchStartX = 0
        let cropSearchStartY = 0
        let cropSearchEndX = screenshotWidth
        let cropSearchEndY = screenshotHeight
        
        logger.notice("  → Searching entire cropped region: \(screenshotWidth, privacy: .public)x\(screenshotHeight, privacy: .public)")
        
        // Save debug screenshot showing search region (use full screenshot for visualization)
        if findImageExtraDebugging {
            createSearchRegionVisualization(
                screenshotPath: screenshotPath,
                searchStartX: searchStartX,
                searchStartY: searchStartY,
                searchEndX: fullWidth,
                searchEndY: fullHeight
            )
            logger.notice("⏱️  [\(String(format: "%.3f", Date().timeIntervalSince(stepStartTime)), privacy: .public)s] Saved search region debug")
            stepStartTime = Date()
        }
        
        let screenshotData = screenshotGray.data.assumingMemoryBound(to: UInt8.self)
        
        // DEBUG: Test specific position match quality using actual algorithm scaling
        if findImageExtraDebugging {
            // Full screenshot coordinates - convert to cropped region coordinates
            let debugXFull = 749 // 5306 / 2
            let debugYFull = 547 // 3592 / 2
            let debugX = debugXFull - searchStartX
            let debugY = debugYFull - searchStartY
            
            testSpecificPositionMatch(
                screenshotPath: screenshotPath,
                templatePath: templatePath,
                templateCG: templateCG,
                screenshotCG: screenshotCG,
                baseHeightRatio: baseHeightRatio,
                screenshotData: screenshotData,
                screenshotWidth: screenshotWidth,
                screenshotHeight: screenshotHeight,
                debugX: debugX,
                debugY: debugY,
                searchStartX: searchStartX,
                searchStartY: searchStartY
            )
            
            logger.notice("⏱️  [\(String(format: "%.3f", Date().timeIntervalSince(stepStartTime)), privacy: .public)s] Debug position test")
            stepStartTime = Date()
        }
        
        var globalBestMatch: (x: Int, y: Int, correlation: Float, scaleIndex: Int, templateWidth: Int, templateHeight: Int)? = nil
        var bestTemplateGray: vImage_Buffer? = nil
        var allScaleMatches: [(scaleIndex: Int, scale: CGFloat, matches: [(x: Int, y: Int, correlation: Float)])] = []
        
        // Try each scale variation
        for (scaleIndex, scaleInfo) in scaledTemplates.enumerated() {
            let scalePercent = Int(scaleInfo.scale * 100)
            logger.notice("  → [Scale \(scaleIndex + 1, privacy: .public)/\(scaledTemplates.count, privacy: .public)] Searching at \(scalePercent, privacy: .public)% (\(scaleInfo.width, privacy: .public)x\(scaleInfo.height, privacy: .public))...")
            
            let templateWidth = scaleInfo.width
            let templateHeight = scaleInfo.height
            
            // Skip if template is larger than search area
            guard templateWidth < (cropSearchEndX - cropSearchStartX) && templateHeight < (cropSearchEndY - cropSearchStartY) else {
                logger.notice("    → Template too large for search area, skipping")
                continue
            }
            
            // Convert template to grayscale
            guard let templateGray = convertToGrayscale(cgImage: scaleInfo.cgImage) else {
                logger.notice("    → Failed to convert template to grayscale, skipping")
                continue
            }
            let templateData = templateGray.data.assumingMemoryBound(to: UInt8.self)
            logger.notice("    ⏱️  [\(String(format: "%.3f", Date().timeIntervalSince(stepStartTime)), privacy: .public)s] Template grayscale conversion")
            stepStartTime = Date()
            
            // STAGE 1: Coarse search with optimized stride for speed
            // Scale values based on screenshot width (reference: 2500px uses stride=10, sampleStep=3)
            let referenceWidth: CGFloat = 2500.0
            let scaleFactor = CGFloat(fullWidth) / referenceWidth
            let coarseStride = max(1, Int(10.0 * scaleFactor))  // Scale stride
            let coarseSampleStep = max(1, Int(3.0 * scaleFactor))  // Scale sample step
            
            logger.notice("    → Resolution-scaled search: stride=\(coarseStride, privacy: .public), sampleStep=\(coarseSampleStep, privacy: .public) (width=\(fullWidth, privacy: .public), scale=\(String(format: "%.2f", scaleFactor), privacy: .public))")
            
            var coarseMatches: [(x: Int, y: Int, correlation: Float)] = []
            
            for y in Swift.stride(from: cropSearchStartY, to: cropSearchEndY - templateHeight, by: coarseStride) {
                for x in Swift.stride(from: cropSearchStartX, to: cropSearchEndX - templateWidth, by: coarseStride) {
                    let correlation = calculateNormalizedCorrelation(
                        screenshot: screenshotData,
                        screenshotWidth: screenshotWidth,
                        screenshotHeight: screenshotHeight,
                        template: templateData,
                        templateWidth: templateWidth,
                        templateHeight: templateHeight,
                        offsetX: x,
                        offsetY: y,
                        sampleStep: coarseSampleStep
                    )
                    
                    if correlation > 0.6 {
                        coarseMatches.append((x, y, correlation))
                    }
                }
            }
            
            logger.notice("    ⏱️  [\(String(format: "%.3f", Date().timeIntervalSince(stepStartTime)), privacy: .public)s] Coarse search completed")
            stepStartTime = Date()
            
            // Create heatmap visualization for this scale
            if findImageExtraDebugging {
                createHeatmapVisualization(
                    screenshotPath: screenshotPath,
                    scalePercent: Int(scaleInfo.scale * 100),
                    templateWidth: templateWidth,
                    templateHeight: templateHeight,
                    screenshotData: screenshotData,
                    screenshotWidth: screenshotWidth,
                    screenshotHeight: screenshotHeight,
                    templateData: templateData,
                    searchStartX: cropSearchStartX,
                    searchStartY: cropSearchStartY,
                    searchEndX: cropSearchEndX,
                    searchEndY: cropSearchEndY,
                    coarseStride: coarseStride
                )
                logger.notice("    ⏱️  [\(String(format: "%.3f", Date().timeIntervalSince(stepStartTime)), privacy: .public)s] Heatmap generation")
                stepStartTime = Date()
            }
            
            if coarseMatches.isEmpty {
                logger.notice("    → No promising matches found")
                free(templateGray.data)
                continue
            }
            
            logger.notice("    → Found \(coarseMatches.count, privacy: .public) coarse candidates")
            
            // Save debug info for this scale
            allScaleMatches.append((scaleIndex: scaleIndex, scale: scaleInfo.scale, matches: coarseMatches))
            
            // Sort and take top candidates (reduced from 15 to 5 for speed)
            let topCandidates = coarseMatches.sorted { $0.correlation > $1.correlation }.prefix(5)
            
            // STAGE 2: Fine search around each coarse candidate
            let fineSearchRadius = coarseStride / 2  // Smaller radius for speed
            let fineStride = max(1, Int(2.0 * scaleFactor))  // Scale fine stride
            let fineSampleStep = max(1, Int(2.0 * scaleFactor))  // Scale fine sample step
            
            logger.notice("    → Fine search: stride=\(fineStride, privacy: .public), sampleStep=\(fineSampleStep, privacy: .public), radius=\(fineSearchRadius, privacy: .public)")
            
            for candidate in topCandidates {
                let fineStartX = max(cropSearchStartX, candidate.x - fineSearchRadius)
                let fineEndX = min(cropSearchEndX - templateWidth, candidate.x + fineSearchRadius)
                let fineStartY = max(cropSearchStartY, candidate.y - fineSearchRadius)
                let fineEndY = min(cropSearchEndY - templateHeight, candidate.y + fineSearchRadius)
                
                for y in Swift.stride(from: fineStartY, through: fineEndY, by: fineStride) {
                    for x in Swift.stride(from: fineStartX, through: fineEndX, by: fineStride) {
                        let correlation = calculateNormalizedCorrelation(
                            screenshot: screenshotData,
                            screenshotWidth: screenshotWidth,
                            screenshotHeight: screenshotHeight,
                            template: templateData,
                            templateWidth: templateWidth,
                            templateHeight: templateHeight,
                            offsetX: x,
                            offsetY: y,
                            sampleStep: fineSampleStep
                        )
                        
                        if globalBestMatch == nil || correlation > globalBestMatch!.correlation {
                            // Free the old best template only if it's different from current template
                            if let oldBest = bestTemplateGray, oldBest.data != templateGray.data {
                                free(oldBest.data)
                            }
                            globalBestMatch = (x, y, correlation, scaleIndex, templateWidth, templateHeight)
                            bestTemplateGray = templateGray
                        }
                    }
                }
            }
            
            logger.notice("    ⏱️  [\(String(format: "%.3f", Date().timeIntervalSince(stepStartTime)), privacy: .public)s] Fine search completed")
            stepStartTime = Date()
            
            // Only free template if it's not the best one
            if bestTemplateGray == nil || bestTemplateGray!.data != templateGray.data {
                free(templateGray.data)
            }
        }
        
        // Keep screenshot buffer for refinement - don't free yet
        
        // Save debug visualization of all matches found at all scales
        if findImageExtraDebugging {
            createAllMatchesVisualization(
                screenshotPath: screenshotPath,
                allScaleMatches: allScaleMatches,
                scaledTemplates: scaledTemplates
            )
            logger.notice("⏱️  [\(String(format: "%.3f", Date().timeIntervalSince(stepStartTime)), privacy: .public)s] All-matches debug")
            stepStartTime = Date()
        }
        
        // Check if we found a match
        guard let bestMatch = globalBestMatch else {
            logger.notice("  ✗ No matches found across any scale")
            if findImageExtraDebugging {
                logger.notice("  💾 Check debug images:")
                logger.notice("     - \(screenshotPath.replacingOccurrences(of: ".png", with: "-search-region.png"), privacy: .public)")
                logger.notice("     - \(screenshotPath.replacingOccurrences(of: ".png", with: "-all-matches.png"), privacy: .public)")
            }
            return nil
        }
        
        logger.notice("  ℹ️  Best match: scale=\(Int(scaledTemplates[bestMatch.scaleIndex].scale * 100), privacy: .public)% at (\(bestMatch.x, privacy: .public), \(bestMatch.y, privacy: .public)) confidence=\(String(format: "%.2f", bestMatch.correlation), privacy: .public)")
        
        // Reuse the saved best-matching template (already converted to grayscale)
        guard let templateGray = bestTemplateGray else {
            logger.notice("  ✗ No template data saved for refinement")
            free(screenshotGray.data)
            return nil
        }
        
        let templateData = templateGray.data.assumingMemoryBound(to: UInt8.self)
        let templateWidth = bestMatch.templateWidth
        let templateHeight = bestMatch.templateHeight
        
        // Reuse screenshot (already converted to grayscale)
        let screenshotDataRefined = screenshotData
        
        // STAGE 3: Pixel-perfect refinement
        var refinedMatch = (x: bestMatch.x, y: bestMatch.y, correlation: bestMatch.correlation)
        let refineRange = 3  // Slightly larger to compensate for coarser fine search
        
        for dy in Swift.stride(from: -refineRange, through: refineRange, by: 1) {
            for dx in Swift.stride(from: -refineRange, through: refineRange, by: 1) {
                let x = bestMatch.x + dx
                let y = bestMatch.y + dy
                
                // Simple bounds check without search region constraints
                guard x >= 0 && y >= 0 && 
                      x <= screenshotWidth - templateWidth && 
                      y <= screenshotHeight - templateHeight else {
                    continue
                }
                
                let correlation = calculateNormalizedCorrelation(
                    screenshot: screenshotDataRefined,
                    screenshotWidth: screenshotWidth,
                    screenshotHeight: screenshotHeight,
                    template: templateData,
                    templateWidth: templateWidth,
                    templateHeight: templateHeight,
                    offsetX: x,
                    offsetY: y,
                    sampleStep: 1  // Pixel-perfect
                )
                
                if correlation > refinedMatch.correlation {
                    refinedMatch = (x, y, correlation)
                }
            }
        }
        
        logger.notice("⏱️  [\(String(format: "%.3f", Date().timeIntervalSince(stepStartTime)), privacy: .public)s] Refinement completed")
        stepStartTime = Date()
        
        // Free buffers
        free(screenshotGray.data)
        free(templateGray.data)
        
        // Check if best match meets minimum confidence threshold
        let lowerThreshold = minConfidence * 0.9  // Slightly lower threshold (10% tolerance)
        guard refinedMatch.correlation >= lowerThreshold else {
            logger.notice("  ✗ Template not found (best: \(String(format: "%.2f", refinedMatch.correlation), privacy: .public), threshold: \(String(format: "%.2f", lowerThreshold), privacy: .public))")
            return nil
        }
        
        let scalePercent = Int(scaledTemplates[bestMatch.scaleIndex].scale * 100)
        logger.notice("  ✓ Found template at (\(refinedMatch.x, privacy: .public), \(refinedMatch.y, privacy: .public)) scale=\(scalePercent, privacy: .public)% confidence=\(String(format: "%.2f", refinedMatch.correlation), privacy: .public)")
        
        // Save debug screenshot showing final match (convert coordinates back to full image)
        if findImageExtraDebugging {
            createFinalMatchVisualization(
                screenshotPath: screenshotPath,
                matchX: refinedMatch.x + searchStartX,
                matchY: refinedMatch.y + searchStartY,
                templateWidth: templateWidth,
                templateHeight: templateHeight,
                correlation: refinedMatch.correlation
            )
            logger.notice("⏱️  [\(String(format: "%.3f", Date().timeIntervalSince(stepStartTime)), privacy: .public)s] Final match debug")
        }
        
        let totalTime = Date().timeIntervalSince(startTime)
        logger.notice("⏱️  TOTAL: [\(String(format: "%.3f", totalTime), privacy: .public)s]")
        
        // Convert coordinates back to full screenshot space
        return CGRect(
            x: CGFloat(refinedMatch.x + searchStartX),
            y: CGFloat(refinedMatch.y + searchStartY),
            width: CGFloat(templateWidth),
            height: CGFloat(templateHeight)
        )
    }
    
    /// Downscale a vImage buffer by the given scale factor (simple decimation - no averaging)
    private static func downscaleBuffer(_ buffer: vImage_Buffer, scale: Int) -> vImage_Buffer? {
        let originalWidth = Int(buffer.width)
        let originalHeight = Int(buffer.height)
        let newWidth = originalWidth / scale
        let newHeight = originalHeight / scale
        
        guard newWidth > 0 && newHeight > 0 else {
            return nil
        }
        
        // Allocate buffer for downscaled data
        let downscaledData = UnsafeMutablePointer<UInt8>.allocate(capacity: newWidth * newHeight)
        
        let sourceData = buffer.data.assumingMemoryBound(to: UInt8.self)
        
        // Simple decimation - just take every Nth pixel (much faster than averaging)
        for dy in 0..<newHeight {
            for dx in 0..<newWidth {
                let sourceX = dx * scale
                let sourceY = dy * scale
                downscaledData[dy * newWidth + dx] = sourceData[sourceY * originalWidth + sourceX]
            }
        }
        
        return vImage_Buffer(
            data: downscaledData,
            height: vImagePixelCount(newHeight),
            width: vImagePixelCount(newWidth),
            rowBytes: newWidth
        )
    }
    
    /// Convert CGImage to grayscale vImage buffer using vImage for speed
    private static func convertToGrayscale(cgImage: CGImage) -> vImage_Buffer? {
        let width = cgImage.width
        let height = cgImage.height
        
        // Get source image data
        guard let dataProvider = cgImage.dataProvider,
              let data = dataProvider.data,
              let pixels = CFDataGetBytePtr(data) else {
            return nil
        }
        
        // Allocate buffer for grayscale data
        let grayData = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
        
        let grayBuffer = vImage_Buffer(
            data: grayData,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: width
        )
        
        // Fast path: if already grayscale, just copy one channel
        // Otherwise convert with red emphasis for debugging
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        let bytesPerRow = cgImage.bytesPerRow
        
        logger.notice("        DEBUG convertToGrayscale: \(width, privacy: .public)x\(height, privacy: .public), bitsPerPixel=\(cgImage.bitsPerPixel, privacy: .public), bytesPerPixel=\(bytesPerPixel, privacy: .public)")
        
        if bytesPerPixel == 1 {
            // Already grayscale - just copy
            logger.notice("        DEBUG: Image already grayscale, copying directly")
            memcpy(grayData, pixels, width * height)
        } else {
            // Red emphasis: pure red appears bright, other colors darker
            // Formula: gray = R - max(G, B), clamped to 0-255
            logger.notice("        DEBUG: Applying red-emphasis conversion")
            
            // Optimized loop: process pixels more efficiently
            var dstIndex = 0
            var srcIndex = 0
            
            for _ in 0..<height {
                for _ in 0..<width {
                    let r = pixels[srcIndex]
                    let g = pixels[srcIndex + 1]
                    let b = pixels[srcIndex + 2]
                    
                    // Highlight red: pure red = brightest, non-red = darker
                    // Using UInt8 arithmetic directly avoids Int conversions
                    let maxGB = max(g, b)
                    let redness = r > maxGB ? r &- maxGB : 0
                    grayData[dstIndex] = redness
                    
                    srcIndex += bytesPerPixel
                    dstIndex += 1
                }
                // Skip to next row (handles row padding)
                srcIndex = srcIndex - (width * bytesPerPixel) + bytesPerRow
            }
        }
        
        return grayBuffer
    }
    
    /// Calculate normalized cross-correlation between template and screenshot region
    private static func calculateNormalizedCorrelation(
        screenshot: UnsafePointer<UInt8>,
        screenshotWidth: Int,
        screenshotHeight: Int,
        template: UnsafePointer<UInt8>,
        templateWidth: Int,
        templateHeight: Int,
        offsetX: Int,
        offsetY: Int,
        sampleStep: Int = 2
    ) -> Float {
        var sumTemplate: Float = 0
        var sumScreenshot: Float = 0
        var sumTemplateSq: Float = 0
        var sumScreenshotSq: Float = 0
        var sumProduct: Float = 0
        var n: Float = 0
        
        for ty in stride(from: 0, to: templateHeight, by: sampleStep) {
            for tx in stride(from: 0, to: templateWidth, by: sampleStep) {
                let sx = offsetX + tx
                let sy = offsetY + ty
                
                let templatePixel = Float(template[ty * templateWidth + tx])
                let screenshotPixel = Float(screenshot[sy * screenshotWidth + sx])
                
                sumTemplate += templatePixel
                sumScreenshot += screenshotPixel
                sumTemplateSq += templatePixel * templatePixel
                sumScreenshotSq += screenshotPixel * screenshotPixel
                sumProduct += templatePixel * screenshotPixel
                n += 1
            }
        }
        
        // Normalized cross-correlation formula
        let numerator = sumProduct - (sumTemplate * sumScreenshot / n)
        let denomTemplate = sumTemplateSq - (sumTemplate * sumTemplate / n)
        let denomScreenshot = sumScreenshotSq - (sumScreenshot * sumScreenshot / n)
        
        let denominator = sqrt(denomTemplate * denomScreenshot)
        
        if denominator < 0.0001 {
            return 0.0
        }
        
        return numerator / denominator
    }
    
    /// Perform OCR on an image and find multiple texts
    static func findText(_ searchTexts: [String], in imagePath: String, app: NSRunningApplication? = nil) -> [String: CGRect] {
        guard let image = NSImage(contentsOfFile: imagePath),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            logger.error("⚠️  Failed to load image for OCR")
            return [:]
        }
        
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        
        do {
            try handler.perform([request])
            
            guard let observations = request.results else {
                return [:]
            }
            
            // Print all detected text for debugging (only if game is still focused)
            if let app = app {
                let frontmostApp = NSWorkspace.shared.frontmostApplication
                let isFocused = frontmostApp?.processIdentifier == app.processIdentifier
                
                if isFocused {
                    logger.notice("  → Detected text on screen:")
                    for (index, observation) in observations.enumerated() {
                        guard let candidate = observation.topCandidates(1).first else { continue }
                        logger.notice("     [\(index, privacy: .public)] '\(candidate.string, privacy: .public)' (confidence: \(String(format: "%.2f", candidate.confidence), privacy: .public))")
                    }
                }
            } else {
                // If no app provided, always print (backward compatibility)
                logger.notice("  → Detected text on screen:")
                for (index, observation) in observations.enumerated() {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    logger.notice("     [\(index, privacy: .public)] '\(candidate.string, privacy: .public)' (confidence: \(String(format: "%.2f", candidate.confidence), privacy: .public))")
                }
            }
            
            var foundTexts: [String: CGRect] = [:]
            
            // Search for each text in observations
            for searchText in searchTexts {
                for observation in observations {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    
                    if candidate.string.lowercased().contains(searchText.lowercased()) {
                        let boundingBox = observation.boundingBox
                        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
                        
                        // For annotation: Keep Vision's bottom-left coordinates (NSImage also uses bottom-left)
                        let annotationRect = CGRect(
                            x: boundingBox.minX * imageSize.width,
                            y: boundingBox.minY * imageSize.height,
                            width: boundingBox.width * imageSize.width,
                            height: boundingBox.height * imageSize.height
                        )
                        
                        // For clicking: Convert to top-left origin (screen coordinates)
                        let clickRect = CGRect(
                            x: boundingBox.minX * imageSize.width,
                            y: (1 - boundingBox.maxY) * imageSize.height,
                            width: boundingBox.width * imageSize.width,
                            height: boundingBox.height * imageSize.height
                        )
                        
                        logger.notice("  ✓ Found '\(searchText, privacy: .public)' - matched text: '\(candidate.string, privacy: .public)' at (\(Int(clickRect.midX), privacy: .public), \(Int(clickRect.midY), privacy: .public))")
                        
                        // Draw a box around the found text and save annotated screenshot
                        saveAnnotatedScreenshot(image: image, rect: annotationRect, originalPath: imagePath, label: searchText)
                        
                        foundTexts[searchText] = clickRect
                        break  // Found this search text, move to next one
                    }
                }
            }
            
            return foundTexts
        } catch {
            logger.error("⚠️  OCR failed: \(error, privacy: .public)")
        }
        
        return [:]
    }
    
    /// Save debug image showing search locations with template overlay when no match is found
    private static func saveNoMatchDebugImage(
        screenshot: NSImage,
        template: CGImage,
        matches: [(x: Int, y: Int, correlation: Float)],
        screenshotHeight: Int,
        templateWidth: Int,
        templateHeight: Int,
        screenshotPath: String
    ) {
        let debugPath = screenshotPath.replacingOccurrences(of: ".png", with: "-no-match-debug.png")
        
        // Create annotated image
        let annotatedImage = NSImage(size: screenshot.size)
        annotatedImage.lockFocus()
        
        // Draw original screenshot
        screenshot.draw(at: .zero, from: NSRect(origin: .zero, size: screenshot.size), operation: .copy, fraction: 1.0)
        
        // Draw semi-transparent colored rectangles for search positions
        for (index, match) in matches.enumerated() {
            let rect = CGRect(
                x: CGFloat(match.x),
                y: CGFloat(screenshotHeight) - CGFloat(match.y) - CGFloat(templateHeight),
                width: CGFloat(templateWidth),
                height: CGFloat(templateHeight)
            )
            
            // Color by correlation: red (low) to yellow (high)
            let normalizedCorr = min(1.0, max(0.0, match.correlation))
            let color = NSColor(hue: 0.0 + (0.15 * CGFloat(normalizedCorr)), saturation: 0.8, brightness: 0.9, alpha: 0.2)
            color.setFill()
            NSBezierPath(rect: rect).fill()
            
            // Draw border for top 5
            if index < 5 {
                let borderColor = NSColor(hue: 0.0 + (0.15 * CGFloat(normalizedCorr)), saturation: 0.9, brightness: 1.0, alpha: 0.7)
                borderColor.setStroke()
                let borderPath = NSBezierPath(rect: rect)
                borderPath.lineWidth = index == 0 ? 3.0 : 2.0
                borderPath.stroke()
                
                // Show correlation value
                let text = String(format: "%.2f", match.correlation)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: 14),
                    .foregroundColor: NSColor.white,
                    .strokeColor: NSColor.black,
                    .strokeWidth: -3.0
                ]
                let attrString = NSAttributedString(string: text, attributes: attributes)
                attrString.draw(at: NSPoint(x: rect.minX + 5, y: rect.minY + 5))
            }
        }
        
        // Overlay the template image at the best match location with higher opacity
        if let bestMatch = matches.first {
            let overlayRect = CGRect(
                x: CGFloat(bestMatch.x),
                y: CGFloat(screenshotHeight) - CGFloat(bestMatch.y) - CGFloat(templateHeight),
                width: CGFloat(templateWidth),
                height: CGFloat(templateHeight)
            )
            
            // Create NSImage from CGImage for drawing
            let templateNS = NSImage(cgImage: template, size: NSSize(width: templateWidth, height: templateHeight))
            
            // Draw template with 50% opacity
            templateNS.draw(in: overlayRect, from: NSRect(origin: .zero, size: templateNS.size), operation: .sourceOver, fraction: 0.5)
            
            // Draw bright border around template overlay
            NSColor.cyan.withAlphaComponent(0.9).setStroke()
            let templateBorder = NSBezierPath(rect: overlayRect)
            templateBorder.lineWidth = 4.0
            templateBorder.stroke()
            
            // Label
            let label = "Template (looking for this)"
            let labelAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 16),
                .foregroundColor: NSColor.cyan,
                .strokeColor: NSColor.black,
                .strokeWidth: -4.0
            ]
            let labelString = NSAttributedString(string: label, attributes: labelAttributes)
            labelString.draw(at: NSPoint(x: overlayRect.minX, y: overlayRect.maxY + 5))
        }
        
        annotatedImage.unlockFocus()
        
        // Save debug image
        if let tiffData = annotatedImage.tiffRepresentation,
           let bitmapImage = NSBitmapImageRep(data: tiffData),
           let pngData = bitmapImage.representation(using: .png, properties: [:]) {
            try? pngData.write(to: URL(fileURLWithPath: debugPath))
            logger.notice("  📸 Saved no-match debug image with template overlay:")
            logger.notice("     \(debugPath, privacy: .public)")
        }
    }
    
    /// Draw a red box around detected text and save annotated screenshot
    static func saveAnnotatedScreenshotMultiple(image: NSImage, rects: [(rect: CGRect, label: String)], originalPath: String) {
        let annotatedPath = originalPath.replacingOccurrences(of: ".png", with: "-annotated.png")
        
        // Create a new image with the boxes drawn on it
        let newImage = NSImage(size: image.size)
        newImage.lockFocus()
        
        // Draw original image
        image.draw(at: .zero, from: NSRect(origin: .zero, size: image.size), operation: .copy, fraction: 1.0)
        
        // Colors for different ranks
        let colors = [
            NSColor.red,      // Best match
            NSColor.orange,   // 2nd
            NSColor.yellow,   // 3rd
            NSColor.green,    // 4th-5th
            NSColor.cyan,     // 6th-7th
            NSColor.blue,     // 8th-9th
            NSColor.purple    // 10th
        ]
        
        for (index, rectInfo) in rects.enumerated() {
            let colorIndex = min(index, colors.count - 1)
            let color = colors[colorIndex]
            
            // Draw box
            color.setStroke()
            let boxPath = NSBezierPath(rect: rectInfo.rect)
            boxPath.lineWidth = 3.0
            boxPath.stroke()
            
            // Draw center point
            color.setFill()
            let centerPoint = CGPoint(x: rectInfo.rect.midX, y: rectInfo.rect.midY)
            let centerRect = CGRect(x: centerPoint.x - 4, y: centerPoint.y - 4, width: 8, height: 8)
            NSBezierPath(ovalIn: centerRect).fill()
            
            // Draw label
            let labelText = NSAttributedString(
                string: rectInfo.label,
                attributes: [
                    .font: NSFont.boldSystemFont(ofSize: 14),
                    .foregroundColor: color,
                    .strokeColor: NSColor.black,
                    .strokeWidth: -3.0
                ]
            )
            labelText.draw(at: CGPoint(x: rectInfo.rect.minX, y: rectInfo.rect.maxY + 5))
        }
        
        newImage.unlockFocus()
        
        // Save annotated image
        if let tiffData = newImage.tiffRepresentation,
           let bitmapImage = NSBitmapImageRep(data: tiffData),
           let pngData = bitmapImage.representation(using: .png, properties: [:]) {
            try? pngData.write(to: URL(fileURLWithPath: annotatedPath))
            logger.notice("  📸 Saved annotated screenshot with \(rects.count, privacy: .public) matches: \(annotatedPath, privacy: .public)")
        }
    }
    
    static func saveAnnotatedScreenshot(image: NSImage, rect: CGRect, originalPath: String, label: String? = nil) {
        let annotatedPath = originalPath.replacingOccurrences(of: ".png", with: "-annotated.png")
        
        // Create a new image with the box drawn on it
        let newImage = NSImage(size: image.size)
        newImage.lockFocus()
        
        // Draw original image
        image.draw(at: .zero, from: NSRect(origin: .zero, size: image.size), operation: .copy, fraction: 1.0)
        
        // Draw red box around detected text
        NSColor.red.setStroke()
        let boxPath = NSBezierPath(rect: rect)
        boxPath.lineWidth = 4.0
        boxPath.stroke()
        
        // Draw center point
        NSColor.green.setFill()
        let centerPoint = CGPoint(x: rect.midX, y: rect.midY)
        let centerRect = CGRect(x: centerPoint.x - 5, y: centerPoint.y - 5, width: 10, height: 10)
        NSBezierPath(ovalIn: centerRect).fill()
        
        // Draw label if provided
        if let label = label {
            let labelText = NSAttributedString(
                string: label,
                attributes: [
                    .font: NSFont.boldSystemFont(ofSize: 16),
                    .foregroundColor: NSColor.yellow,
                    .strokeColor: NSColor.black,
                    .strokeWidth: -3.0
                ]
            )
            labelText.draw(at: CGPoint(x: rect.minX, y: rect.maxY + 5))
        }
        
        newImage.unlockFocus()
        
        // Save annotated image
        if let tiffData = newImage.tiffRepresentation,
           let bitmapImage = NSBitmapImageRep(data: tiffData),
           let pngData = bitmapImage.representation(using: .png, properties: [:]) {
            try? pngData.write(to: URL(fileURLWithPath: annotatedPath))
            logger.notice("  📸 Saved annotated screenshot: \(annotatedPath, privacy: .public)")
        }
    }
    
    /// Search for a single text in a screenshot (single attempt)
    static func searchForText(_ searchText: String) -> CGPoint? {
        logger.notice("🔍 Searching for '\(searchText, privacy: .public)'...")
        
        guard let screenshotPath = captureScreen() else {
            return nil
        }
        
        let results = findText([searchText], in: screenshotPath)
        
        // Clean up screenshot
        try? FileManager.default.removeItem(atPath: screenshotPath)
        
        if let rect = results[searchText] {
            return CGPoint(x: rect.midX, y: rect.midY)
        }
        
        return nil
    }
    
    /// Search for multiple texts in a screenshot (single attempt)
    static func searchForText(_ searchTexts: [String]) -> [String: CGPoint] {
        if searchTexts.count == 1 {
            logger.notice("🔍 Searching for '\(searchTexts[0], privacy: .public)'...")
        } else {
            let textList = searchTexts.map { "'\($0)'" }.joined(separator: ", ")
            logger.notice("🔍 Searching for multiple texts: \(textList, privacy: .public)")
        }
        
        guard let screenshotPath = captureScreen() else {
            return [:]
        }
        
        let results = findText(searchTexts, in: screenshotPath)
        
        var foundTexts: [String: CGPoint] = [:]
        for (text, rect) in results {
            foundTexts[text] = CGPoint(x: rect.midX, y: rect.midY)
        }
        
        // Save screenshot for inspection
        logger.notice("  📸 Screenshot saved: \(screenshotPath, privacy: .public)")
        
        return foundTexts
    }
    
    /// Search for text in screenshots periodically (single text)
    static func searchForTextPeriodically(_ searchText: String, interval: TimeInterval, maxAttempts: Int) -> CGPoint? {
        // Call the array version with a single-element array
        let results = searchForTextPeriodically([searchText], interval: interval, maxAttempts: maxAttempts)
        return results[searchText]
    }
    
    /// Search for multiple texts in screenshots periodically
    static func searchForTextPeriodically(_ searchTexts: [String], interval: TimeInterval, maxAttempts: Int) -> [String: CGPoint] {
        if searchTexts.count == 1 {
            logger.notice("🔍 Searching for '\(searchTexts[0], privacy: .public)' in screenshots...")
        } else {
            let textList = searchTexts.map { "'\($0)'" }.joined(separator: ", ")
            logger.notice("🔍 Searching for multiple texts in screenshots: \(textList, privacy: .public)")
        }
        
        for attempt in 1...maxAttempts {
            logger.notice("  → Attempt \(attempt, privacy: .public)/\(maxAttempts, privacy: .public)")
            
            let foundTexts = searchForText(searchTexts)
            
            // If we found at least one text, return results
            if !foundTexts.isEmpty {
                return foundTexts
            }
            
            if attempt < maxAttempts {
                Thread.sleep(forTimeInterval: interval)
            }
        }
        
        logger.notice("  ✗ None of the texts found after \(maxAttempts, privacy: .public) attempts")
        return [:]
    }
}

// MARK: - Screen Analysis

/// Points of interest found in a game screenshot.
struct ScreenAnalysisResult {
    /// "Exit Game", "Quit" text, or quit button matched via template image
    var quitButton: CGRect?
    /// "interactive" text (Her Interactive logo) location
    var interactiveLogo: CGRect?
}

/// Resolves the path to the quit-button template image from the app bundle.
private func resolveQuitButtonImagePath() -> String {
    if let bundled = Bundle.main.path(forResource: "quit-button", ofType: "png") {
        return bundled
    }
    // Dev fallback: search upward from executable for the source tree
    let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    var dir = scriptDir
    for _ in 0..<10 {
        dir = dir.deletingLastPathComponent()
        let candidate = dir.appendingPathComponent("GamePuppeteer/assets/quit-button.png").path
        if FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
    }
    fatalError("quit-button.png not found in bundle or source tree. Add it to the GamePuppeteer target's Copy Bundle Resources build phase.")
}

/// Analyzes a screenshot for quit-related UI elements.
/// Can be used standalone against a saved screenshot for debugging.
func analyzeScreenshot(at screenshotPath: String, app: NSRunningApplication? = nil) -> ScreenAnalysisResult {
    let logger = Logger(subsystem: "com.secondchance.gamepuppeteer", category: "ScreenAnalysis")
    let quitButtonImagePath = resolveQuitButtonImagePath()

    let dispatchGroup = DispatchGroup()
    var foundTexts: [String: CGRect] = [:]
    var quitButtonLocation: CGRect?

    dispatchGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        foundTexts = ScreenshotOCR.findText(["Exit Game", "Quit", "interactive"], in: screenshotPath, app: app)
        dispatchGroup.leave()
    }

    dispatchGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        quitButtonLocation = ScreenshotOCR.findImage(quitButtonImagePath, in: screenshotPath)
        dispatchGroup.leave()
    }

    dispatchGroup.wait()

    let result = ScreenAnalysisResult(
        quitButton: foundTexts["Exit Game"] ?? foundTexts["Quit"] ?? quitButtonLocation,
        interactiveLogo: foundTexts["interactive"]
    )

    logger.notice("Screen analysis results:")
    if let r = result.quitButton { logger.notice("  Quit button: \(Int(r.minX), privacy: .public),\(Int(r.minY), privacy: .public) \(Int(r.width), privacy: .public)x\(Int(r.height), privacy: .public)") }
    if let r = result.interactiveLogo { logger.notice("  Interactive logo: \(Int(r.minX), privacy: .public),\(Int(r.minY), privacy: .public) \(Int(r.width), privacy: .public)x\(Int(r.height), privacy: .public)") }
    if result.quitButton == nil && result.interactiveLogo == nil {
        logger.notice("  (nothing found)")
    }

    return result
}
