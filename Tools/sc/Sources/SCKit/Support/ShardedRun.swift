import Foundation
import Noora
import WrappBuilder

/// `sc test integration --shard-on <host>[,<host>…]`: one integration run
/// split into shards, each run in a test session on another Mac, gathered
/// into one table naming each row's Mac and session
/// (docs/testing.md#sharding-a-run-across-macs).
///
/// The sc the person runs is the coordinator. It claims free test sessions
/// on each Mac, as many as the Mac takes shards (`shardCount`), hands out
/// the games by which installers each Mac has, runs each shard as
/// `sc --on <user>@<host>:<path> test integration <its games>`, and reads
/// back the results each shard writes (`--results-json`). Sessions are
/// released at the end, on failure and on Ctrl-C too.

/// What a shard writes for the coordinator to read back: its rows as its own
/// table shows them, its exit status and its failures.
struct ShardResult: Codable, Sendable, Equatable {
    var status: Int32
    var rows: [GameBoard.Row]
    /// `<test>: <failure>` for each failed test, for the hints.
    var failures: [String]
    /// Where the run's result bundle is, on the Mac it ran on.
    var bundle: String?
}

// MARK: - Handing out games

/// Which session each game runs in. Pure, so the choice can be tested.
enum ShardPlan {
    /// A game to run, with how big its build is (the bigger, the earlier
    /// it's handed out) and the installers it needs, as `installerKeys` names
    /// them.
    struct Game: Equatable, Sendable {
        var slug: String
        var weight: Int64
        var needs: Set<String>
    }

    /// Somewhere a shard runs: one test session, and the installers its Mac
    /// has. A Mac running several shards is several slots with its name.
    struct Slot: Equatable, Sendable {
        var name: String
        var has: Set<String>
    }

    struct Assignment: Equatable, Sendable {
        /// The games for each slot, in the slots' order.
        var shards: [[Game]]
        /// Games no slot can run: none has their installers.
        var unrunnable: [Game]
    }

    /// The biggest builds first, each to the least loaded slot that has its
    /// installers (which, with sizes unknown, goes round-robin). A slot
    /// that lacks them can still run a game whose installers this Mac will
    /// send it (`sentFromHere`, which every `--on` sync copies), but only
    /// when no slot already has them.
    static func assign(_ games: [Game], to slots: [Slot], sentFromHere: Set<String> = []) -> Assignment {
        var shards = Array(repeating: [Game](), count: slots.count)
        var load = Array(repeating: Int64(0), count: slots.count)
        var unrunnable: [Game] = []
        let ordered = games.enumerated().sorted { lhs, rhs in
            lhs.element.weight != rhs.element.weight ? lhs.element.weight > rhs.element.weight : lhs.offset < rhs.offset
        }.map(\.element)
        for game in ordered {
            var candidates = slots.indices.filter { game.needs.isSubset(of: slots[$0].has) }
            if candidates.isEmpty {
                candidates = slots.indices.filter { game.needs.isSubset(of: slots[$0].has.union(sentFromHere)) }
            }
            let best = candidates.min { lhs, rhs in
                if load[lhs] != load[rhs] { return load[lhs] < load[rhs] }
                if shards[lhs].count != shards[rhs].count { return shards[lhs].count < shards[rhs].count }
                return lhs < rhs
            }
            guard let best else {
                unrunnable.append(game)
                continue
            }
            shards[best].append(game)
            load[best] += game.weight
        }
        return Assignment(shards: shards, unrunnable: unrunnable)
    }

    /// The installers a listing of an installers store holds (paths in it,
    /// a line each): `disk/<slug>` for a game whose disc edition's images
    /// are all there, as the disc suite needs, and `her-download/<slug>`
    /// for one with a Her download (`Games.herDownloads`).
    static func installerKeys(listing: [String], manifests: [Manifest]) -> Set<String> {
        let editions = InstallersStore.editions(inListing: listing, manifests: manifests)
        var keys = Set<String>()
        for manifest in manifests {
            for edition in manifest.editions where editions.contains("\(manifest.id)/\(edition.id)") {
                switch edition.source {
                case .disc: keys.insert("disk/\(manifest.name)")
                case .herDownload: keys.insert("her-download/\(manifest.name)")
                case .steam, .bigFish, .download: break
                }
            }
        }
        return keys
    }

    /// The installers `game` needs for the sources that test it: a disc
    /// game's images for the disc suite, its download for the Her suite.
    static func needs(_ slug: String, sources: [IntegrationSource]) -> Set<String> {
        Set(sources.compactMap { source in
            switch source {
            case .disk: "disk/\(slug)"
            case .herDownload: "her-download/\(slug)"
            case .steam, .bigFish, .bigFishTrial, .download: nil
            }
        })
    }
}

// MARK: - Gathering the results

/// One shard's end, merged into the run's table by `ShardReport.merge`.
struct ShardOutcome: Sendable {
    enum Result: Sendable {
        /// It ran and wrote its results, passing or not.
        case reported(ShardResult)
        /// It never got as far as reporting: ssh failed, the session was
        /// lost, the build there failed. Not a test failure, and not retried.
        case infrastructure(String)
    }

    var mac: String
    var session: String
    /// The rows it was given: shown, unrun, when it didn't report.
    var planned: [GameBoard.Row]
    var result: Result
}

enum ShardReport {
    struct Row: Sendable, Equatable {
        var mac: String
        var session: String
        var row: GameBoard.Row
    }

    static let infrastructureStatus = "infra failed"
    static let unrunnableStatus = "no Mac"

    /// Every shard's rows in one list, in `order`'s order of games (the
    /// catalogue's), each naming where it ran; unrun rows for a shard that
    /// didn't report and for games no Mac could run. Fails when any shard
    /// failed, didn't report, or a game couldn't be run anywhere.
    static func merge(_ outcomes: [ShardOutcome], unrunnable: [GameBoard.Row] = [], order: [String]) -> (rows: [Row], failed: Bool) {
        var rows: [Row] = []
        var failed = !unrunnable.isEmpty
        for outcome in outcomes {
            switch outcome.result {
            case .reported(let result):
                if result.status != 0 || result.rows.contains(where: { $0.status == "failed" }) { failed = true }
                rows += result.rows.map { Row(mac: outcome.mac, session: outcome.session, row: $0) }
            case .infrastructure:
                failed = true
                rows += outcome.planned.map { planned in
                    var row = planned
                    row.status = infrastructureStatus
                    return Row(mac: outcome.mac, session: outcome.session, row: row)
                }
            }
        }
        rows += unrunnable.map { planned in
            var row = planned
            row.status = unrunnableStatus
            return Row(mac: "", session: "", row: row)
        }
        let position = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let sources = IntegrationSource.allCases.map(\.rawValue)
        // A Her download's Mac row is "<slug> mac".
        let rank: (Row) -> (Int, Int, String) = { row in
            let slug = row.row.slug.hasSuffix(" mac") ? String(row.row.slug.dropLast(4)) : row.row.slug
            return (position[slug] ?? Int.max, sources.firstIndex(of: row.row.source) ?? Int.max, row.row.slug)
        }
        let sorted = rows.enumerated().sorted { lhs, rhs in
            let left = rank(lhs.element), right = rank(rhs.element)
            if left != right { return left < right }
            return lhs.offset < rhs.offset
        }.map(\.element)
        return (sorted, failed)
    }

    static func table(_ rows: [Row], showSource: Bool) -> (headers: [String], rows: [StyledTableRow]) {
        let games = TestRunner.gameTable(rows.map(\.row), showSource: showSource)
        let styled: [StyledTableRow] = zip(rows, games.rows).map { row, cells in
            [.plain(row.mac.isEmpty ? "—" : "\(row.session)@\(row.mac)")] + cells
        }
        return (["Session"] + games.headers, styled)
    }
}

// MARK: - Running it

struct ShardCoordinator: Sendable {
    let session: Session
    /// What `--source` asked for.
    let sources: [IntegrationSource]
    /// The options each shard's run is given (`forwardedOptions`).
    let forwarded: [String]
    /// `--shard-on`'s Macs, each `<host>[:<path>]` as `--on` takes it.
    let macs: [String]
    /// `--shards-per-mac`, or nil for each Mac's own (`shardCount`).
    var shardsPerMac: Int?
    /// `--shard`'s sessions, as given, in place of `macs`.
    var sessions: [String] = []
    /// Whether `--build-concurrency` was given, which then holds for every
    /// shard (`shardOptions`).
    var buildConcurrencyGiven = false

    /// How many shards a Mac runs at once. A Mac launches about one game
    /// per two performance cores before Wine slows sharply (measured on an
    /// M1 Max: docs/historical-plans/2026-11-06-puppet-toolkit.md#outcome),
    /// and a build loads it like a launch; a shard builds and launches a game
    /// at a time (`shardOptions`), so one shard per four performance cores.
    static func shardCount(performanceCores: Int, requested: Int?) -> Int {
        requested ?? max(1, performanceCores / 4)
    }

    /// A shard's options: the run's, and, when its Mac runs several shards
    /// and no `--build-concurrency` was given, one build at a time, as each
    /// shard's own default (`IntegrationOptions.defaultBuildConcurrency`)
    /// counts the whole Mac's cores.
    static func shardOptions(_ forwarded: [String], shardsOnMac: Int, buildConcurrencyGiven: Bool) -> [String] {
        shardsOnMac > 1 && !buildConcurrencyGiven ? forwarded + ["--build-concurrency", "1"] : forwarded
    }

    var ui: UI { session.ui }
    var repo: Repo { session.repo }

    /// A Mac to shard onto: where its checkout is, and the session claimed
    /// there.
    struct Mac: Sendable {
        /// As given, for `--on`.
        var raw: String
        /// Without any `user@`, so a test user can be put in front.
        var host: String
        var path: String
        var user: String?
        var installers: Set<String> = []
        var problem: String?
        /// How many shards run on this session's Mac, this one among them.
        var shardsOnMac = 1

        /// `--shard`'s: the session to claim, rather than any free one.
        var wantedUser: String?

        /// The Mac this runs on: its sessions are claimed and released, and
        /// its installers listed, here, as SSH to this Mac as you needn't work.
        var isThisMac: Bool { RuntimeCopy.isThisMac(host) }
        var name: String { isThisMac ? ScreenLease.shortHostName() : host }
        /// Who to SSH to for this Mac's test users.
        var sshHost: String { isThisMac ? "localhost" : host }
        /// Where `--on` reaches the console user's checkout (for `session`).
        var consoleTarget: String { "\(raw.split(separator: ":", maxSplits: 1).first.map(String.init) ?? host):\(path)" }
        /// `session` commands' `--on`: none for this Mac.
        var consoleArguments: [String] { isThisMac ? [] : ["--on", consoleTarget] }
        /// Where `--on` reaches the claimed session's checkout.
        func sessionTarget(_ user: String) -> String { "\(user)@\(sshHost):\(path)" }
        /// `<user>@<mac>`, as sessions are named everywhere.
        func label(_ user: String) -> String { "\(user)@\(name)" }
    }

    /// `--shard`'s sessions, each `<user>` (this Mac's), `<user>@<host>`, or
    /// either with `:<path>` for the checkout there (default as `--on`'s).
    static func parseSession(_ entry: String, localRoot: URL) -> Mac {
        let (place, path) = entry.firstIndex(of: ":").map { (String(entry[..<$0]), String(entry[entry.index(after: $0)...])) } ?? (entry, nil)
        let user = place.split(separator: "@", maxSplits: 1).first.map(String.init) ?? place
        let host = place.contains("@") ? String(place.split(separator: "@", maxSplits: 1)[1]) : "localhost"
        let raw = path.map { "\(host):\($0)" } ?? host
        let target = Remote.parse(raw, localRoot: localRoot)
        return Mac(raw: raw, host: host, path: target.path, wantedUser: user)
    }

    /// `--shard`'s sessions as `prepare` takes them: one entry per Mac, in
    /// the order first named, with its first session's checkout, and the
    /// users to claim on each, every one named.
    static func plan(_ sessions: [Mac]) -> (macs: [Mac], users: [String: [String]]) {
        var seen: Set<String> = []
        let macs = sessions.filter { seen.insert($0.host).inserted }
        return (macs, Dictionary(grouping: sessions, by: \.host).mapValues { $0.compactMap(\.wantedUser) })
    }

    static func parseMacs(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The sc that runs each step: this checkout's, built as `./sc` builds it.
    private var sc: String { repo.root.appendingPathComponent("sc").path }

    func run(games requested: [CatalogGame], stamp: String) async throws {
        let named = !sessions.isEmpty
        let plan = Self.plan(sessions.map { Self.parseSession($0, localRoot: repo.root) })
        var macs = named ? plan.macs : self.macs.map { raw -> Mac in
            let target = Remote.parse(raw, localRoot: repo.root)
            let host = target.host.split(separator: "@").last.map(String.init) ?? target.host
            return Mac(raw: raw, host: host, path: target.path)
        }
        let games = requested.isEmpty ? Catalog.games : requested
        let purpose = session.purpose ?? "sharded integration run (\(games.count) game\(games.count == 1 ? "" : "s"))"
        // Long enough for the run, renewed by nothing: released at the end.
        let minutes = min(480, 60 + 20 * games.count)

        // Each Mac's installers and its sessions, Macs side by side: a Mac
        // (or a session asked for) with none to give is kept, to say why.
        let wanted = named ? plan.users : [:]
        macs = await withTaskGroup(of: (Int, [Mac]).self) { group in
            for (index, mac) in macs.enumerated() {
                group.addTask { (index, await prepare(mac, users: wanted[mac.host], purpose: purpose, minutes: minutes)) }
            }
            var prepared = Array(repeating: [Mac](), count: macs.count)
            for await (index, sessions) in group { prepared[index] = sessions }
            return prepared.flatMap { $0 }
        }
        let claimed = macs.filter { $0.user != nil }
        do {
            for mac in macs {
                if let user = mac.user {
                    ui.detail("Claimed \(mac.label(user)) (\(mac.installers.count) installer\(mac.installers.count == 1 ? "" : "s") there).")
                } else {
                    ui.warning("\(mac.wantedUser.map(mac.label) ?? mac.name) won't run a shard: \(mac.problem ?? "no test session")")
                }
            }
            try Task.checkCancellation()
            guard !claimed.isEmpty else {
                throw SCError(named ? "None of those test sessions could be claimed, so nothing was tested."
                                    : "No Mac had a test session to run a shard in, so nothing was tested.",
                              hints: ["See each Mac's sessions: sc --on <host> session list"])
            }
            try await runShards(on: claimed, games: games, sources: sources, purpose: purpose, stamp: stamp)
        } catch {
            // Cancelled or failed: stop what's running there and give the
            // sessions back, uncancelled, before saying so.
            await Task.detached { [self] in await finish(claimed, stopRuns: true) }.value
            throw error
        }
        await finish(claimed, stopRuns: false)
    }

    // MARK: Before

    /// The Mac's sessions for this run, as many as it takes shards, each a
    /// `Mac` with its user; or the Mac alone, with why, when it gave none.
    /// `--new`: sessions of the run's own, never one this agent session (or
    /// person) already holds for other work, which its release would end.
    /// One claim at a time, as each takes a session the last left free.
    private func prepare(_ mac: Mac, users named: [String]?, purpose: String, minutes: Int) async -> [Mac] {
        var mac = mac
        mac.installers = await installers(on: mac)
        if let named {
            // `--shard`'s: just those sessions, each claimed by name.
            var results: [Mac] = []
            for user in named {
                var session = mac
                session.wantedUser = user
                switch await claim(on: mac, user: user, purpose: purpose, minutes: minutes) {
                case .claimed(let claimed): session.user = claimed
                case .noneFree: session.problem = "someone else has it leased."
                case .failed(let why): session.problem = "couldn't claim it: \(why)"
                }
                results.append(session)
            }
            let claimed = results.filter { $0.user != nil }.count
            return results.map { var session = $0; session.shardsOnMac = max(1, claimed); return session }
        }
        let wanted = Self.shardCount(performanceCores: await performanceCores(on: mac), requested: shardsPerMac)
        var sessions: [Mac] = []
        while sessions.count < wanted {
            let outcome = await claim(on: mac, user: nil, purpose: purpose, minutes: minutes)
            guard case .claimed(let user) = outcome else {
                if sessions.isEmpty {
                    if case .failed(let why) = outcome {
                        mac.problem = "couldn't claim a test session there: \(why)"
                    } else {
                        mac.problem = "no test session there is free."
                    }
                    return [mac]
                }
                ui.warning("\(mac.name) takes \(wanted) shards, but only \(sessions.count) of its test sessions \(sessions.count == 1 ? "was" : "were") free.")
                break
            }
            var session = mac
            session.user = user
            sessions.append(session)
        }
        return sessions.map { var session = $0; session.shardsOnMac = sessions.count; return session }
    }

    enum ClaimOutcome: Sendable {
        case claimed(String)
        case noneFree
        case failed(String)
    }

    /// One of the Mac's test sessions leased to this run: `user`, or any
    /// free one. As `session claim` does it, and through it: on this Mac
    /// its function (`SessionClaimCommand.claim`), on another the command,
    /// run there, as that Mac holds its pool and leases.
    private func claim(on mac: Mac, user: String?, purpose: String, minutes: Int) async -> ClaimOutcome {
        if mac.isThisMac {
            do {
                // `new`: a session of the run's own, never one already held
                // for other work, which its release would end.
                return .claimed(try await SessionClaimCommand.claim(user, new: true, seconds: TimeInterval(minutes * 60), session: session,
                                                                    policy: session.leasePolicy, purpose: purpose).user)
            } catch let error as SCError where error.exitCode == ScreenLease.heldExitCode {
                return .noneFree
            } catch {
                return .failed("\(error)")
            }
        }
        let (status, lines) = await runSC(mac.consoleArguments + ["session", "claim"] + (user.map { [$0] } ?? [])
                                              + ["--json", "--new", "--for", "\(minutes)m", "--purpose", purpose],
                                          log: "shard-claim-\(mac.name)-\(user ?? "any")")
        if let claimed = lines.reversed().lazy.compactMap(Claim.parse).first { return .claimed(claimed.user) }
        return status == ScreenLease.heldExitCode ? .noneFree : .failed("exit \(status): \(Self.tail(lines))")
    }

    /// Give a session back, as `session release` does: here with its
    /// function, on another Mac with the command run there.
    private func release(_ user: String, on mac: Mac) async -> String? {
        if mac.isThisMac {
            do {
                _ = try await ScreenLease.releaseTaken(session, user: user)
                return nil
            } catch {
                return "\(error)"
            }
        }
        let (status, lines) = await runSC(mac.consoleArguments + ["session", "release", user], log: "shard-release-\(mac.name)-\(user)")
        return status == 0 ? nil : "exit \(status): \(Self.tail(lines))"
    }

    /// The Mac's performance cores (all its cores where there are no
    /// levels, on Intel), as `SystemLoad` counts them; 4, one shard, when it
    /// can't be asked.
    private func performanceCores(on mac: Mac) async -> Int {
        if mac.isThisMac { return IntegrationOptions.fastCoreCount }
        let host = mac.raw.split(separator: ":", maxSplits: 1).first.map(String.init) ?? mac.host
        let script = "sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || sysctl -n hw.physicalcpu"
        guard let result = try? await Proc.collect("ssh", ["-T", host, "/bin/bash -c \(Remote.quote(script))"]), result.succeeded,
              let cores = Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) else { return 4 }
        return cores
    }

    /// The line `session claim --json` prints.
    struct Claim: Codable, Equatable {
        var host: String
        var user: String
        var expires: Date?

        static func parse(_ line: String) -> Claim? {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{") else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(Claim.self, from: Data(trimmed.utf8))
        }
    }

    /// The installers in a Mac's store. Its own environment can't be read
    /// from here, so it's the Mac's store at the usual place.
    private func installers(on mac: Mac) async -> Set<String> {
        if mac.isThisMac { return localInstallers }
        let store = Remote.quote(InstallersStore.defaultRoot.path)
        let command = "cd \(store) 2>/dev/null && find -L . -mindepth 2 -maxdepth 4 -type f"
        let host = mac.raw.split(separator: ":", maxSplits: 1).first.map(String.init) ?? mac.host
        guard let result = try? await Proc.collect("ssh", ["-T", host, command]), result.succeeded else { return [] }
        return ShardPlan.installerKeys(listing: result.output.split(whereSeparator: \.isNewline).map(String.init), manifests: repo.manifests)
    }

    private var localInstallers: Set<String> {
        let root = repo.installers.root
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var listing: [String] = []
        while let url = walker?.nextObject() as? URL {
            let path = String(url.path.dropFirst(root.path.count + 1))
            if path.split(separator: "/").count >= 4 { walker?.skipDescendants() }
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue { listing.append(path) }
        }
        return ShardPlan.installerKeys(listing: listing, manifests: repo.manifests)
    }

    // MARK: During

    private func runShards(on macs: [Mac], games: [CatalogGame], sources: [IntegrationSource], purpose: String, stamp: String) async throws {
        let local = localInstallers
        let everywhere = macs.reduce(local) { $0.union($1.installers) }
        let soldOnDisc = Set(Catalog.games.filter { $0.hasEdition(source: "disc", repo: repo) }.map(\.slug))
        let toDownload = Set(DownloadSourceOptions().availableGames(repo: repo).map(\.slug))
        let withHerDownloads = Set(everywhere.filter { $0.hasPrefix("her-download/") }.map { String($0.dropFirst("her-download/".count)) })
        let sizes = IntegrationSizes(testResults: repo.testResults).load()

        // What each game is tested from, as the runner there will decide.
        var planned: [String: (game: CatalogGame, sources: [IntegrationSource])] = [:]
        var order: [String] = []
        for game in games {
            let testing = sources.filter { $0.tests(game, discs: soldOnDisc, herDownloads: withHerDownloads, downloads: toDownload) }
            guard !testing.isEmpty else { continue }
            planned[game.slug] = (game, testing)
            order.append(game.slug)
        }
        guard !order.isEmpty else {
            throw SCError("None of those games can be built from \(sources.map(\.rawValue).joined(separator: " or ")).")
        }
        let toAssign = order.compactMap { slug -> ShardPlan.Game? in
            guard let entry = planned[slug] else { return nil }
            let measured = entry.sources.compactMap { sizes["\($0.rawValue)/\(slug)"] }.reduce(0, +)
            // Unmeasured: a disc's worth for each disc, so bigger games still go first.
            let weight = measured > 0 ? measured : Int64(max(1, entry.game.diskCount)) * 700_000_000
            return ShardPlan.Game(slug: slug, weight: weight, needs: ShardPlan.needs(slug, sources: entry.sources))
        }
        let slots = macs.map { ShardPlan.Slot(name: $0.name, has: $0.installers) }
        let assignment = ShardPlan.assign(toAssign, to: slots, sentFromHere: local)
        let rowsFor: (ShardPlan.Game) -> [GameBoard.Row] = { game in
            guard let entry = planned[game.slug] else { return [] }
            return entry.sources.map { GameBoard.Row(source: $0.rawValue, slug: game.slug, engine: entry.game.engine, status: "pending") }
        }
        for (mac, shard) in zip(macs, assignment.shards) where !shard.isEmpty {
            ui.detail("\(mac.label(mac.user ?? "?")): \(shard.map(\.slug).joined(separator: ", "))")
        }
        for (name, count) in Dictionary(grouping: macs, by: \.name).mapValues(\.count).sorted(by: { $0.key < $1.key }) where count > 1 {
            ui.detail("\(name) runs \(count) shards at once, building a game at a time each\(buildConcurrencyGiven ? " (or as --build-concurrency says)" : "").")
        }
        if !assignment.unrunnable.isEmpty {
            ui.warning("No Mac has the installers for \(assignment.unrunnable.map(\.slug).joined(separator: ", ")), so they won't be tested.")
        }

        let outcomes = try await withThrowingTaskGroup(of: ShardOutcome.self) { group in
            for (mac, shard) in zip(macs, assignment.shards) where !shard.isEmpty {
                guard let user = mac.user else { continue }
                let slugs = shard.map(\.slug), rows = shard.flatMap(rowsFor)
                group.addTask {
                    try await runShard(on: mac, user: user, games: slugs, planned: rows, purpose: purpose, stamp: stamp)
                }
            }
            var outcomes: [ShardOutcome] = []
            for try await outcome in group { outcomes.append(outcome) }
            return outcomes
        }
        try Task.checkCancellation()
        try await report(outcomes, unrunnable: assignment.unrunnable.flatMap(rowsFor), order: Catalog.games.map(\.slug), sources: sources)
    }

    /// `sc test integration`'s options, as given here, for a shard's run.
    /// Not `--wrapps-dir`, a path here, nor the lease's flags: a shard runs
    /// under the session's claim.
    static func forwardedOptions(_ integration: IntegrationOptions) -> [String] {
        var arguments = ["--source", integration.source, "--refresh-wrapp", integration.refreshWrapp.rawValue,
                         "--disk-margin", "\(integration.diskMargin)"]
        if let count = integration.buildConcurrency { arguments += ["--build-concurrency", "\(count)"] }
        if integration.ignoreLoad { arguments.append("--ignore-load") }
        if integration.keepFailedBuilds { arguments.append("--keep-failed-builds") }
        if integration.keepRecordings { arguments.append("--keep-recordings") }
        // Always this Mac's build, sent by the sync: a test user has no
        // signing certificate to build the app with.
        arguments.append("--skip-app-build")
        return arguments
    }

    private func runShard(on mac: Mac, user: String, games: [String], planned: [GameBoard.Row],
                          purpose: String, stamp: String) async throws -> ShardOutcome {
        let resultsFile = "test-results/\(stamp)-shard-\(mac.name)-\(user).json"
        let label = mac.label(user)
        let options = Self.shardOptions(forwarded, shardsOnMac: mac.shardsOnMac, buildConcurrencyGiven: buildConcurrencyGiven)
        let arguments = ["--on", mac.sessionTarget(user), "test", "integration"] + games + options
            + ["--results-json", resultsFile, "--open-report", "never", "--purpose", purpose]
        ui.line(ui.format("\(.primary("▸ \(label): sc test integration \(games.joined(separator: " "))"))"))
        let (status, lines) = await runSC(arguments, log: "shard-\(mac.name)-\(user)") { line in
            // The run's own story, game by game; the rest is in the log.
            if line.hasPrefix("▸ ") { ui.line("  \(label) \(line)") }
        }
        try Task.checkCancellation()
        let fetched = try? await Proc.collect("ssh", ["-T", "\(user)@\(mac.sshHost)", "cat \(Remote.shellPath(mac.path))/\(Remote.quote(resultsFile))"])
        if let fetched, fetched.succeeded, let result = try? JSONDecoder().decode(ShardResult.self, from: Data(fetched.output.utf8)) {
            return ShardOutcome(mac: mac.name, session: user, planned: planned, result: .reported(result))
        }
        let why = switch status {
        case 255: "lost the connection to \(mac.host)"
        case ScreenLease.heldExitCode: "\(label)'s screen was leased to someone else"
        default: "it stopped before reporting (exit \(status)): \(Self.tail(lines))"
        }
        return ShardOutcome(mac: mac.name, session: user, planned: planned, result: .infrastructure(why))
    }

    // MARK: After

    private func report(_ outcomes: [ShardOutcome], unrunnable: [GameBoard.Row], order: [String], sources: [IntegrationSource]) async throws {
        let merged = ShardReport.merge(outcomes, unrunnable: unrunnable, order: order)
        let table = ShardReport.table(merged.rows, showSource: sources != [.disk])
        await ui.table(headers: table.headers, rows: table.rows)
        var hints: [String] = []
        for outcome in outcomes {
            switch outcome.result {
            case .reported(let result):
                hints += result.failures.prefix(10).map { "\(outcome.session)@\(outcome.mac): \($0)" }
                if let bundle = result.bundle { hints.append("\(outcome.session)@\(outcome.mac)'s results: \(bundle) (on \(outcome.mac))") }
            case .infrastructure(let why):
                ui.warning("\(outcome.session)@\(outcome.mac)'s shard didn't report, so its games weren't tested: \(why)")
            }
        }
        let warned = merged.rows.filter { !$0.row.warnings.isEmpty }
        if !warned.isEmpty {
            let lines = warned.flatMap { row in row.row.warnings.map { "  ▸ \(row.row.slug) (\(row.session)@\(row.mac)): \($0)" } }
            ui.warning("Passing or not, these games had something to look into:\n\(lines.joined(separator: "\n"))")
        }
        let counts = Dictionary(grouping: merged.rows, by: \.row.status).mapValues(\.count)
        let summary = counts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        guard merged.failed else {
            ui.success(TerminalTextBuilder.text("Sharded integration run: \(summary)"))
            return
        }
        throw SCError("Sharded integration run: \(summary)", hints: hints)
    }

    /// Stop any shard still running there (after Ctrl-C or a failure here),
    /// then give back every session claimed.
    private func finish(_ macs: [Mac], stopRuns: Bool) async {
        await withTaskGroup(of: Void.self) { group in
            for mac in macs {
                guard let user = mac.user else { continue }
                group.addTask {
                    if stopRuns {
                        _ = await runSC(["--on", mac.sessionTarget(user), "attach", "--stop"], log: "shard-stop-\(mac.name)-\(user)")
                    }
                    if let problem = await release(user, on: mac) {
                        let command = (["sc"] + mac.consoleArguments + ["session", "release", user]).joined(separator: " ")
                        ui.warning("Couldn't release \(mac.label(user)): \(problem)",
                                   next: TerminalTextBuilder.text("Release it by hand: \(command)"))
                    } else {
                        ui.detail("Released \(mac.label(user)).")
                    }
                }
            }
        }
    }

    // MARK: Running sc

    /// Run this checkout's sc with its raw output kept in a log, and return
    /// its status and lines. A failure to start it is a status, not a throw.
    private func runSC(_ arguments: [String], log: String, onLine: @escaping @Sendable (String) -> Void = { _ in }) async -> (Int32, [String]) {
        let collected = LineCollector()
        do {
            let (sink, _) = try ui.logOnly(log, observers: [])
            let status = try await Proc.stream(sc, arguments + ["--logs", "raw"], cwd: repo.root) { raw in
                let line = raw.replacingOccurrences(of: "\r", with: "")
                collected.append(line)
                await sink.line(line)
                onLine(line)
            }
            return (status, collected.lines)
        } catch {
            return (Task.isCancelled ? 130 : 1, collected.lines + ["\(error.localizedDescription)"])
        }
    }

    /// The last few non-blank lines, for saying why something failed.
    static func tail(_ lines: [String], count: Int = 3) -> String {
        lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(count).joined(separator: " / ")
    }
}

/// Lines from a child's output, gathered from its reader.
final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ line: String) { lock.withLock { stored.append(line) } }
    var lines: [String] { lock.withLock { stored } }
}
