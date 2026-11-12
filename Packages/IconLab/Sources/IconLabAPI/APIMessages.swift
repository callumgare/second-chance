import Foundation

/// A request to the API, as any host received it: an HTTP server, or the app's URL scheme handler.
nonisolated public struct APIRequest: Sendable {
    /// `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`.
    public var method: String
    /// The path as sent, still percent-encoded (`/api/programs/skifree`): a parameter in it reaches the route as it
    /// was sent, as the server before this one gave them.
    public var path: String
    /// The query's items, percent-decoded.
    public var query: [URLQueryItem]
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, query: [URLQueryItem] = [], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method.uppercased()
        self.path = path.isEmpty ? "/" : path
        self.query = query
        self.headers = headers
        self.body = body
    }

    /// A request for a URL (its path and query; the scheme and host are the host's business).
    public init(method: String, url: URL, headers: [String: String] = [:], body: Data = Data()) {
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        self.init(method: method, path: parts?.percentEncodedPath ?? url.path, query: parts?.queryItems ?? [], headers: headers, body: body)
    }

    /// The first query item called `name`.
    public func query(_ name: String) -> String? {
        guard let item = query.first(where: { $0.name == name }) else { return nil }
        return item.value ?? ""
    }
}

/// The API's answer.
nonisolated public struct APIResponse: Sendable {
    public enum Body: Sendable {
        case empty
        case data(Data)
        /// A file to stream from disk (an image, a page's file); the API has checked it's there.
        case file(URL)
    }

    public var status: Int
    public var headers: [String: String]
    public var body: Body

    public init(status: Int = 200, headers: [String: String] = [:], body: Body = .empty) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// The body as bytes, reading a file body from disk: for hosts that don't stream.
    public func bodyData() throws -> Data {
        switch body {
        case .empty: Data()
        case .data(let d): d
        case .file(let url): try Data(contentsOf: url)
        }
    }
}

/// An answer that isn't a success, as `{"error": {"message": …}}` when it has a message, and an empty body when it
/// hasn't (the shape the API has always given).
nonisolated public struct APIError: Error, CustomStringConvertible {
    public var status: Int
    public var message: String?

    public init(_ status: Int, _ message: String? = nil) {
        self.status = status
        self.message = message
    }

    public static let badRequest = APIError(400)
    public static let notFound = APIError(404)
    public static let internalServerError = APIError(500)

    public var description: String { "\(status)\(message.map { ": \($0)" } ?? "")" }

    var response: APIResponse {
        guard let message else { return APIResponse(status: status) }
        struct Format: Encodable {
            struct Inner: Encodable { let message: String }
            let error: Inner
        }
        let data = (try? JSONEncoder().encode(Format(error: .init(message: message)))) ?? Data()
        return APIResponse(status: status, headers: ["Content-Type": "application/json; charset=utf-8"], body: .data(data))
    }
}
