import Foundation
import WrappBuilder

/// Whether the downloads engines are made from are still where their
/// modules say: a release whose engine can't be fetched builds nothing for
/// anyone who hasn't prepared it already (docs/modules.md#engine-packages).
enum EngineSources {
    /// One source that didn't answer as its module says it should.
    struct Problem: CustomStringConvertible {
        let module: String
        let version: String
        let source: String
        let url: String
        let reason: String

        var description: String { "\(module) \(version)'s \(source) at \(url): \(reason)" }
    }

    /// Ask each listed version's sources' first URL for its headers: it must
    /// answer 200 with the size the module names.
    static func check(modules root: URL, session: URLSession = .shared) async throws -> [Problem] {
        let modules = try ModuleLoader(root: root).loadAll().get()
        var problems: [Problem] = []
        for module in modules {
            for version in module.manifest.versions where version.withdrawn != true {
                for source in version.package?.sources ?? [] {
                    guard let first = source.urls.first, let url = URL(string: first) else { continue }
                    let problem = { (reason: String) in
                        Problem(module: module.manifest.id, version: version.version, source: source.id, url: first, reason: reason)
                    }
                    var request = URLRequest(url: url, timeoutInterval: 30)
                    request.httpMethod = "HEAD"
                    do {
                        let (_, response) = try await session.data(for: request)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        if status != 200 {
                            problems.append(problem("it answered \(status)"))
                        } else if let size = source.size, response.expectedContentLength != size {
                            problems.append(problem("it is \(response.expectedContentLength) bytes, not \(size)"))
                        }
                    } catch {
                        problems.append(problem(error.localizedDescription))
                    }
                }
            }
        }
        return problems
    }
}
