import Foundation

/// The page's files: a request's path under the web root, a folder's `index.html` for a folder.
nonisolated enum WebFiles {
    /// nil when there's no such file (the caller keeps its own answer); a failure for a path that can't be one.
    static func serve(_ rawPath: String, from root: URL) -> Result<APIResponse, APIError>? {
        guard let path = rawPath.removingPercentEncoding else { return .failure(APIError(400, "Invalid percent encoding in URL")) }
        guard !path.contains("..") else { return .failure(.badRequest) }
        var url = root.appendingPathComponent(path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        if isDir.boolValue {
            // a folder's address ends in a slash, so the page's relative links resolve inside it
            guard path.hasSuffix("/") else {
                return .success(APIResponse(status: 301, headers: ["Location": rawPath + "/"]))
            }
            url = url.appendingPathComponent("index.html")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        }
        return .success(APIResponse(status: 200, headers: ["Content-Type": contentType(url.pathExtension)], body: .file(url)))
    }

    static func contentType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": "text/html"
        case "js", "mjs": "text/javascript"
        case "css": "text/css"
        case "json", "map": "application/json"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "ico": "image/x-icon"
        case "woff": "font/woff"
        case "woff2": "font/woff2"
        case "ttf": "font/ttf"
        case "wasm": "application/wasm"
        case "txt": "text/plain"
        default: "application/octet-stream"
        }
    }
}
