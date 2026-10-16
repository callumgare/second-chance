import Foundation
import AppKit
import CoreGraphics
import Accelerate
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.WrappPuppeteer.TemplateMatcher")

/// Set to `true` to write heatmaps, search-region and match visualisations
/// next to each screenshot. Slow — debugging only.
let findImageExtraDebugging = Foundation.ProcessInfo.processInfo.environment["FIND_IMAGE_EXTRA_DEBUGGING"] == "true"

/// With extra debugging on, `FIND_IMAGE_DEBUG_PROBE=x,y` (full-screenshot pixel
/// coordinates) also scores the template at that one position and writes the
/// images compared there — for answering "why didn't it match *here*?".
private let findImageDebugProbe: CGPoint? = {
    guard let raw = Foundation.ProcessInfo.processInfo.environment["FIND_IMAGE_DEBUG_PROBE"] else { return nil }
    let parts = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count == 2 else {
        logger.error("⚠️  Ignoring FIND_IMAGE_DEBUG_PROBE='\(raw)' — expected 'x,y'")
        return nil
    }
    return CGPoint(x: parts[0], y: parts[1])
}()

/// How colour pixels are reduced to the single channel that gets correlated.
enum GrayscaleConversion {
    /// Standard perceived brightness. A sensible default for most templates.
    case luminance
    /// `R - max(G, B)`: pure red is brightest, everything else darkens. Makes a
    /// red template stand out against busy, non-red artwork.
    case redEmphasis
}

/// Tuning for one template search. The defaults search the whole screenshot
/// for the template at its own pixel size; a caller that knows where its
/// target sits and how big it renders should say so — cropping the search
/// region is by far the biggest speed win.
struct TemplateMatchOptions {
    /// Part of the screenshot to search, in unit coordinates with a top-left
    /// origin: `(0, 0, 1, 1)` is the whole screenshot,
    /// `(0.5, 0.5, 0.5, 0.5)` the bottom-right quarter.
    var searchRegion = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// Resize the template so its height is this fraction of the screenshot's
    /// height, for targets that scale with the screen. `nil` keeps the
    /// template's own pixel size.
    var templateHeightFraction: CGFloat?
    /// Multipliers on the template size to also try, for targets whose size
    /// varies. Each one costs a full search.
    var scaleVariations: [CGFloat] = [1.0]
    var grayscale: GrayscaleConversion = .luminance
    /// Best correlation (−1…1) a match needs to be reported. 10% tolerance is
    /// applied below this.
    var minConfidence: Float = 0.5
    /// Correlation a coarse-pass position needs to be refined further.
    var candidateThreshold: Float = 0.6
}

/// Normalised cross-correlation template matching on the CPU, using a
/// coarse → fine → pixel-perfect search.
enum TemplateMatcher {
    /// Find a template image within a screenshot. Returns the match rect in
    /// screenshot pixels, top-left origin.
    static func findImage(_ templatePath: String, in screenshotPath: String, options: TemplateMatchOptions = TemplateMatchOptions()) -> CGRect? {
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
        logger.notice("⏱️  [\(String(format: "%.3f", Date().timeIntervalSince(stepStartTime)))s] Loaded images")
        stepStartTime = Date()

        var scaledTemplates: [(scale: CGFloat, cgImage: CGImage, width: Int, height: Int)] = []

        for variation in options.scaleVariations {
            let size = scaledTemplateSize(template: templateCG, screenshotHeight: screenshotCG.height, options: options, variation: variation)
            if let scaledTemplate = scaleImage(templateCG, to: CGSize(width: size.width, height: size.height)) {
                scaledTemplates.append((scale: variation, cgImage: scaledTemplate, width: size.width, height: size.height))
            }
        }

        if scaledTemplates.isEmpty {
            logger.error("⚠️  Failed to create any scaled templates")
            return nil
        }

        logger.notice("  → Prepared \(scaledTemplates.count) template scales (\(options.scaleVariations.map { "\(Int($0 * 100))%" }.joined(separator: ", ")))")
        logger.notice("⏱️  [\(String(format: "%.3f", Date().timeIntervalSince(stepStartTime)))s] Scaled templates")
        stepStartTime = Date()

        if findImageExtraDebugging {
            TemplateMatchDebugImages.saveTemplate(templatePath: templatePath, screenshotPath: screenshotPath)
            logger.notice("⏱️  [\(String(format: "%.3f", Date().timeIntervalSince(stepStartTime)))s] Saved debug template")
            stepStartTime = Date()
        }

        // Calculate the search region BEFORE converting to grayscale
        let fullWidth = screenshotCG.width
        let fullHeight = screenshotCG.height
        let searchStartX = max(0, Int(CGFloat(fullWidth) * options.searchRegion.minX))
        let searchStartY = max(0, Int(CGFloat(fullHeight) * options.searchRegion.minY))
        let searchEndX = min(fullWidth, Int(CGFloat(fullWidth) * options.searchRegion.maxX))
        let searchEndY = min(fullHeight, Int(CGFloat(fullHeight) * options.searchRegion.maxY))
        let searchWidth = searchEndX - searchStartX
        let searchHeight = searchEndY - searchStartY

        logger.notice("  → Full screenshot: \(fullWidth)x\(fullHeight)")
        logger.notice("  → Search region: x[\(searchStartX)-\(searchEndX)], y[\(searchStartY)-\(searchEndY)] (\(searchWidth)x\(searchHeight))")

        // Crop the screenshot to the search region only (huge performance win!)
        let searchRect = CGRect(x: searchStartX, y: searchStartY, width: searchWidth, height: searchHeight)
        guard searchWidth > 0, searchHeight > 0,
              let croppedScreenshot = screenshotCG.cropping(to: searchRect) else {
            logger.error("⚠️  Failed to crop screenshot to search region")
            return nil
        }

        // Convert ONLY the cropped region to grayscale (much faster)
        guard let screenshotGray = convertToGrayscale(cgImage: croppedScreenshot, conversion: options.grayscale) else {
            logger.error("⚠️  Failed to convert screenshot to grayscale")
            return nil
        }
        logger.notice("⏱️  [\(String(format: "%.3f", Date().timeIntervalSince(stepStartTime)))s] Converted search region to grayscale")
        stepStartTime = Date()

        // Coordinates from here on are relative to the crop
        let screenshotWidth = Int(screenshotGray.width)
        let screenshotHeight = Int(screenshotGray.height)

        logger.notice("  → Searching entire cropped region: \(screenshotWidth)x\(screenshotHeight)")

        if findImageExtraDebugging {
            TemplateMatchDebugImages.searchRegion(
                screenshotPath: screenshotPath,
                searchStartX: searchStartX,
                searchStartY: searchStartY,
                searchEndX: searchEndX,
                searchEndY: searchEndY
            )
            logger.notice("⏱️  [\(String(format: "%.3f", Date().timeIntervalSince(stepStartTime)))s] Saved search region debug")
            stepStartTime = Date()
        }

        let screenshotData = screenshotGray.data.assumingMemoryBound(to: UInt8.self)

        if findImageExtraDebugging, let probe = findImageDebugProbe {
            probeSpecificPosition(
                screenshotPath: screenshotPath,
                templatePath: templatePath,
                templateCG: templateCG,
                templateSize: scaledTemplateSize(template: templateCG, screenshotHeight: fullHeight, options: options, variation: 1.0),
                options: options,
                screenshotData: screenshotData,
                screenshotWidth: screenshotWidth,
                screenshotHeight: screenshotHeight,
                debugX: Int(probe.x) - searchStartX,
                debugY: Int(probe.y) - searchStartY,
                searchStartX: searchStartX,
                searchStartY: searchStartY
            )
            logger.notice("⏱️  [\(String(format: "%.3f", Date().timeIntervalSince(stepStartTime)))s] Debug position test")
            stepStartTime = Date()
        }

        var globalBestMatch: (x: Int, y: Int, correlation: Float, scaleIndex: Int, templateWidth: Int, templateHeight: Int)? = nil
        var bestTemplateGray: vImage_Buffer? = nil
        var allScaleMatches: [(scaleIndex: Int, scale: CGFloat, matches: [(x: Int, y: Int, correlation: Float)])] = []

        // Try each scale variation
        for (scaleIndex, scaleInfo) in scaledTemplates.enumerated() {
            let scalePercent = Int(scaleInfo.scale * 100)
            logger.notice("  → [Scale \(scaleIndex + 1)/\(scaledTemplates.count)] Searching at \(scalePercent)% (\(scaleInfo.width)x\(scaleInfo.height))...")

            let templateWidth = scaleInfo.width
            let templateHeight = scaleInfo.height

            guard templateWidth < screenshotWidth && templateHeight < screenshotHeight else {
                logger.notice("    → Template too large for search area, skipping")
                continue
            }

            guard let templateGray = convertToGrayscale(cgImage: scaleInfo.cgImage, conversion: options.grayscale) else {
                logger.notice("    → Failed to convert template to grayscale, skipping")
                continue
            }
            let templateData = templateGray.data.assumingMemoryBound(to: UInt8.self)
            logger.notice("    ⏱️  [\(String(format: "%.3f", Date().timeIntervalSince(stepStartTime)))s] Template grayscale conversion")
            stepStartTime = Date()

            // STAGE 1: Coarse search. Stride and sampling scale with the
            // screenshot width (reference: 2500px uses stride=10, sampleStep=3).
            let referenceWidth: CGFloat = 2500.0
            let scaleFactor = CGFloat(fullWidth) / referenceWidth
            let coarseStride = max(1, Int(10.0 * scaleFactor))
            let coarseSampleStep = max(1, Int(3.0 * scaleFactor))

            logger.notice("    → Resolution-scaled search: stride=\(coarseStride), sampleStep=\(coarseSampleStep) (width=\(fullWidth), scale=\(String(format: "%.2f", scaleFactor)))")

            var coarseMatches: [(x: Int, y: Int, correlation: Float)] = []

            for y in Swift.stride(from: 0, to: screenshotHeight - templateHeight, by: coarseStride) {
                for x in Swift.stride(from: 0, to: screenshotWidth - templateWidth, by: coarseStride) {
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

                    if correlation > options.candidateThreshold {
                        coarseMatches.append((x, y, correlation))
                    }
                }
            }

            logger.notice("    ⏱️  [\(String(format: "%.3f", Date().timeIntervalSince(stepStartTime)))s] Coarse search completed")
            stepStartTime = Date()

            if findImageExtraDebugging {
                TemplateMatchDebugImages.heatmap(
                    screenshotPath: screenshotPath,
                    scalePercent: scalePercent,
                    templateWidth: templateWidth,
                    templateHeight: templateHeight,
                    searchEndX: screenshotWidth,
                    searchEndY: screenshotHeight,
                    coarseStride: coarseStride,
                    offsetX: searchStartX,
                    offsetY: searchStartY
                ) { x, y in
                    calculateNormalizedCorrelation(
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
                }
                logger.notice("    ⏱️  [\(String(format: "%.3f", Date().timeIntervalSince(stepStartTime)))s] Heatmap generation")
                stepStartTime = Date()
            }

            if coarseMatches.isEmpty {
                logger.notice("    → No promising matches found")
                free(templateGray.data)
                continue
            }

            logger.notice("    → Found \(coarseMatches.count) coarse candidates")

            allScaleMatches.append((scaleIndex: scaleIndex, scale: scaleInfo.scale, matches: coarseMatches))

            let topCandidates = coarseMatches.sorted { $0.correlation > $1.correlation }.prefix(5)

            // STAGE 2: Fine search around each coarse candidate
            let fineSearchRadius = coarseStride / 2
            let fineStride = max(1, Int(2.0 * scaleFactor))
            let fineSampleStep = max(1, Int(2.0 * scaleFactor))

            logger.notice("    → Fine search: stride=\(fineStride), sampleStep=\(fineSampleStep), radius=\(fineSearchRadius)")

            for candidate in topCandidates {
                let fineStartX = max(0, candidate.x - fineSearchRadius)
                let fineEndX = min(screenshotWidth - templateWidth, candidate.x + fineSearchRadius)
                let fineStartY = max(0, candidate.y - fineSearchRadius)
                let fineEndY = min(screenshotHeight - templateHeight, candidate.y + fineSearchRadius)

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

                        if correlation > (globalBestMatch?.correlation ?? -.infinity) {
                            // Free the old best template only if it's a different buffer
                            if let oldBest = bestTemplateGray, oldBest.data != templateGray.data {
                                free(oldBest.data)
                            }
                            globalBestMatch = (x, y, correlation, scaleIndex, templateWidth, templateHeight)
                            bestTemplateGray = templateGray
                        }
                    }
                }
            }

            logger.notice("    ⏱️  [\(String(format: "%.3f", Date().timeIntervalSince(stepStartTime)))s] Fine search completed")
            stepStartTime = Date()

            // Only free the template if it isn't the best one
            if bestTemplateGray?.data != templateGray.data {
                free(templateGray.data)
            }
        }

        if findImageExtraDebugging {
            TemplateMatchDebugImages.allMatches(
                screenshotPath: screenshotPath,
                allScaleMatches: allScaleMatches,
                templateSizes: scaledTemplates.map { (width: $0.width, height: $0.height) },
                offsetX: searchStartX,
                offsetY: searchStartY
            )
            logger.notice("⏱️  [\(String(format: "%.3f", Date().timeIntervalSince(stepStartTime)))s] All-matches debug")
            stepStartTime = Date()
        }

        guard let bestMatch = globalBestMatch, let templateGray = bestTemplateGray else {
            logger.notice("  ✗ No matches found across any scale")
            if findImageExtraDebugging {
                logger.notice("  💾 Check debug images:")
                logger.notice("     - \(screenshotPath.replacingOccurrences(of: ".png", with: "-search-region.png"))")
                logger.notice("     - \(screenshotPath.replacingOccurrences(of: ".png", with: "-all-matches.png"))")
            }
            free(screenshotGray.data)
            return nil
        }

        logger.notice("  ℹ️  Best match: scale=\(Int(scaledTemplates[bestMatch.scaleIndex].scale * 100))% at (\(bestMatch.x), \(bestMatch.y)) confidence=\(String(format: "%.2f", bestMatch.correlation))")

        let templateData = templateGray.data.assumingMemoryBound(to: UInt8.self)
        let templateWidth = bestMatch.templateWidth
        let templateHeight = bestMatch.templateHeight

        // STAGE 3: Pixel-perfect refinement
        var refinedMatch = (x: bestMatch.x, y: bestMatch.y, correlation: bestMatch.correlation)
        let refineRange = 3

        for dy in Swift.stride(from: -refineRange, through: refineRange, by: 1) {
            for dx in Swift.stride(from: -refineRange, through: refineRange, by: 1) {
                let x = bestMatch.x + dx
                let y = bestMatch.y + dy

                guard x >= 0 && y >= 0 &&
                      x <= screenshotWidth - templateWidth &&
                      y <= screenshotHeight - templateHeight else {
                    continue
                }

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

                if correlation > refinedMatch.correlation {
                    refinedMatch = (x, y, correlation)
                }
            }
        }

        logger.notice("⏱️  [\(String(format: "%.3f", Date().timeIntervalSince(stepStartTime)))s] Refinement completed")
        stepStartTime = Date()

        free(screenshotGray.data)
        free(templateGray.data)

        let lowerThreshold = options.minConfidence * 0.9  // 10% tolerance
        guard refinedMatch.correlation >= lowerThreshold else {
            logger.notice("  ✗ Template not found (best: \(String(format: "%.2f", refinedMatch.correlation)), threshold: \(String(format: "%.2f", lowerThreshold)))")
            return nil
        }

        let scalePercent = Int(scaledTemplates[bestMatch.scaleIndex].scale * 100)
        logger.notice("  ✓ Found template at (\(refinedMatch.x), \(refinedMatch.y)) scale=\(scalePercent)% confidence=\(String(format: "%.2f", refinedMatch.correlation))")

        // Convert coordinates back to full screenshot space
        let result = CGRect(
            x: CGFloat(refinedMatch.x + searchStartX),
            y: CGFloat(refinedMatch.y + searchStartY),
            width: CGFloat(templateWidth),
            height: CGFloat(templateHeight)
        )

        if findImageExtraDebugging {
            TemplateMatchDebugImages.finalMatch(screenshotPath: screenshotPath, match: result, correlation: refinedMatch.correlation)
            logger.notice("⏱️  [\(String(format: "%.3f", Date().timeIntervalSince(stepStartTime)))s] Final match debug")
        }

        logger.notice("⏱️  TOTAL: [\(String(format: "%.3f", Date().timeIntervalSince(startTime)))s]")

        return result
    }

    // MARK: - Private

    /// The pixel size the template is searched at for a given scale variation.
    private static func scaledTemplateSize(template: CGImage, screenshotHeight: Int, options: TemplateMatchOptions, variation: CGFloat) -> (width: Int, height: Int) {
        let baseHeight: CGFloat
        if let fraction = options.templateHeightFraction {
            baseHeight = CGFloat(screenshotHeight) * fraction
        } else {
            baseHeight = CGFloat(template.height)
        }
        let targetHeight = baseHeight * variation
        let targetWidth = CGFloat(template.width) * (targetHeight / CGFloat(template.height))
        return (Int(targetWidth), Int(targetHeight))
    }

    /// Score the template at one position, logging the correlation and saving
    /// the images that were compared.
    private static func probeSpecificPosition(
        screenshotPath: String,
        templatePath: String,
        templateCG: CGImage,
        templateSize: (width: Int, height: Int),
        options: TemplateMatchOptions,
        screenshotData: UnsafePointer<UInt8>,
        screenshotWidth: Int,
        screenshotHeight: Int,
        debugX: Int,
        debugY: Int,
        searchStartX: Int,
        searchStartY: Int
    ) {
        logger.notice("  🔍 DEBUG: Testing match at specific position (\(debugX + searchStartX), \(debugY + searchStartY))...")

        let debugWidth = templateSize.width
        let debugHeight = templateSize.height
        guard debugX >= 0, debugY >= 0,
              debugX + debugWidth <= screenshotWidth,
              debugY + debugHeight <= screenshotHeight else {
            logger.error("     ⚠️  Probe position is outside the search region — nothing to score")
            return
        }

        guard let scaledTemplate = scaleImage(templateCG, to: CGSize(width: debugWidth, height: debugHeight)),
              let templateGray = convertToGrayscale(cgImage: scaledTemplate, conversion: options.grayscale) else {
            return
        }
        defer { free(templateGray.data) }

        let templateData = templateGray.data.assumingMemoryBound(to: UInt8.self)
        let correlation = calculateNormalizedCorrelation(
            screenshot: screenshotData,
            screenshotWidth: screenshotWidth,
            screenshotHeight: screenshotHeight,
            template: templateData,
            templateWidth: debugWidth,
            templateHeight: debugHeight,
            offsetX: debugX,
            offsetY: debugY,
            sampleStep: 1
        )
        logger.notice("     Template \(templateCG.width)x\(templateCG.height) scaled to \(debugWidth)x\(debugHeight)")
        logger.notice("     Correlation: \(String(format: "%.4f", correlation))")

        TemplateMatchDebugImages.probe(
            screenshotPath: screenshotPath,
            templatePath: templatePath,
            colorTemplate: scaledTemplate,
            grayTemplate: templateData,
            grayScreenshot: screenshotData,
            screenshotWidth: screenshotWidth,
            screenshotHeight: screenshotHeight,
            debugX: debugX,
            debugY: debugY,
            debugWidth: debugWidth,
            debugHeight: debugHeight,
            correlation: correlation,
            searchStartX: searchStartX,
            searchStartY: searchStartY
        )
    }

    /// Scale a CGImage to a specific size
    private static func scaleImage(_ image: CGImage, to size: CGSize) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
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

    /// Convert a CGImage to a single-channel buffer. The caller frees `.data`.
    private static func convertToGrayscale(cgImage: CGImage, conversion: GrayscaleConversion) -> vImage_Buffer? {
        let width = cgImage.width
        let height = cgImage.height

        guard let dataProvider = cgImage.dataProvider,
              let data = dataProvider.data,
              let pixels = CFDataGetBytePtr(data) else {
            return nil
        }

        let grayData = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
        let grayBuffer = vImage_Buffer(
            data: grayData,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: width
        )

        let bytesPerPixel = cgImage.bitsPerPixel / 8
        let bytesPerRow = cgImage.bytesPerRow

        logger.debug("convertToGrayscale: \(width)x\(height), bitsPerPixel=\(cgImage.bitsPerPixel), conversion=\(conversion)")

        if bytesPerPixel == 1 {
            // Already grayscale — copy row by row to drop any row padding
            for row in 0..<height {
                memcpy(grayData + row * width, pixels + row * bytesPerRow, width)
            }
            return grayBuffer
        }

        // Assumes RGB(A) channel order, which is what both screencapture PNGs
        // and scaleImage's context produce.
        var dstIndex = 0
        for row in 0..<height {
            var srcIndex = row * bytesPerRow
            for _ in 0..<width {
                let r = pixels[srcIndex]
                let g = pixels[srcIndex + 1]
                let b = pixels[srcIndex + 2]

                switch conversion {
                case .redEmphasis:
                    let maxGB = max(g, b)
                    grayData[dstIndex] = r > maxGB ? r &- maxGB : 0
                case .luminance:
                    // Rec. 601 weights in fixed point (77 + 150 + 29 = 256)
                    grayData[dstIndex] = UInt8((77 * Int(r) + 150 * Int(g) + 29 * Int(b)) >> 8)
                }

                srcIndex += bytesPerPixel
                dstIndex += 1
            }
        }

        return grayBuffer
    }

    /// Normalized cross-correlation between the template and the screenshot
    /// region at an offset, sampling every `sampleStep` pixels.
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

        let numerator = sumProduct - (sumTemplate * sumScreenshot / n)
        let denomTemplate = sumTemplateSq - (sumTemplate * sumTemplate / n)
        let denomScreenshot = sumScreenshotSq - (sumScreenshot * sumScreenshot / n)

        let denominator = sqrt(denomTemplate * denomScreenshot)

        if denominator < 0.0001 {
            return 0.0
        }

        return numerator / denominator
    }
}
