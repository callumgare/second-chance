import Foundation
import WrappBuilder

/// Whether the downloads engines are made from are still where their
/// modules say: a release whose engine can't be fetched builds nothing for
/// anyone who hasn't prepared it already (docs/modules.md#engine-packages).
public nonisolated enum EngineSources {
    /// What went wrong with a source, which decides what to do about it.
    enum Kind: Int, Comparable, Sendable {
        /// 404 or 410: the file isn't at that address any more.
        case gone
        /// It answered 200 with another size: a different file is there now.
        case changed
        /// 401 or 403: the server wouldn't let the check have it.
        case refused
        /// 429 or a 5xx: the server's trouble, likely for a while only.
        case serverTrouble
        /// Any other answer.
        case unexpected
        /// No answer at all: the connection failed or timed out.
        case unreachable

        /// Whether it means the module points at the wrong place, rather
        /// than that the check couldn't tell.
        var moved: Bool { self == .gone || self == .changed }

        /// What to do about it, for someone looking after the modules.
        var advice: String {
            switch self {
            case .gone:
                "A download that has gone: point the module at where it is now, or at an archived copy (docs/modules.md#engine-packages)."
            case .changed:
                "A download whose size changed is another file now: find the one the module's sha256 names, or add a new version for the new one."
            case .refused:
                "A refused download may need a sign-in: check the source's headers in its module.yaml, and that the download and this check both send them."
            case .serverTrouble:
                "A server in trouble is usually so for a while only: try again later."
            case .unexpected:
                "Open the address in a browser to see what it answers."
            case .unreachable:
                "Check this Mac's connection to the internet, then try again."
            }
        }

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// One source that didn't answer as its module says it should.
    public struct Problem: CustomStringConvertible, Sendable {
        let module: String
        let version: String
        let source: String
        let url: String
        let kind: Kind
        let reason: String

        public var description: String { "\(module) \(version)'s \(source) at \(url): \(reason)" }
    }

    /// What a status other than 200 means.
    static func kind(ofStatus status: Int) -> Kind {
        switch status {
        case 404, 410: .gone
        case 401, 403: .refused
        case 429, 500...599: .serverTrouble
        default: .unexpected
        }
    }

    /// The reason a status other than 200 gives, as a problem's line says it.
    static func reason(forStatus status: Int) -> String {
        let name = HTTPURLResponse.localizedString(forStatusCode: status)
        return switch kind(ofStatus: status) {
        case .gone: "it isn't there any more (\(status) \(name))"
        case .refused: "the server refused it (\(status) \(name))"
        case .serverTrouble: "the server had trouble answering (\(status) \(name))"
        default: "it answered \(status) \(name), not 200"
        }
    }

    /// One line saying what the problems were, as a whole.
    public static func summary(_ problems: [Problem]) -> String {
        if problems.allSatisfy(\.kind.moved) {
            return problems.count == 1
                ? "an engine's download isn't where its module says."
                : "\(problems.count) engine downloads aren't where their modules say."
        }
        return problems.count == 1
            ? "an engine's download couldn't be checked."
            : "\(problems.count) engine downloads couldn't be checked."
    }

    /// What to do about the problems: one piece of advice for each kind.
    public static func advice(_ problems: [Problem]) -> [String] {
        Set(problems.map(\.kind)).sorted().map(\.advice)
    }

    /// Ask each listed version's sources' first URL for its headers: it must
    /// answer 200 with the size the module names. The source's headers go
    /// with it, as they do with the download.
    public static func check(modules root: URL, session: URLSession = .shared) async throws -> [Problem] {
        let modules = try ModuleLoader(root: root).loadAll().get()
        var problems: [Problem] = []
        for module in modules {
            for version in module.manifest.versions where version.withdrawn != true {
                for source in version.package?.sources ?? [] {
                    guard let first = source.urls.first, let url = URL(string: first) else { continue }
                    let problem = { (kind: Kind, reason: String) in
                        Problem(module: module.manifest.id, version: version.version, source: source.id, url: first, kind: kind, reason: reason)
                    }
                    var request = URLRequest(url: url, timeoutInterval: 30)
                    request.httpMethod = "HEAD"
                    // As the download sends them: ghcr.io's anonymous sign-in, say.
                    for (name, value) in source.headers ?? [:] { request.setValue(value, forHTTPHeaderField: name) }
                    do {
                        let (_, response) = try await session.data(for: request)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        if status != 200 {
                            problems.append(problem(kind(ofStatus: status), reason(forStatus: status)))
                        } else if let size = source.size, response.expectedContentLength != size {
                            problems.append(problem(.changed, "it is \(response.expectedContentLength) bytes, not the \(size) its module says"))
                        }
                    } catch {
                        problems.append(problem(.unreachable, "no answer (\(error.localizedDescription))"))
                    }
                }
            }
        }
        return problems
    }
}
