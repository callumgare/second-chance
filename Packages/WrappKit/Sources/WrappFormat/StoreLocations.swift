//
//  StoreLocations.swift
//  WrappFormat
//
//  Where each store lives on disk, so the builder and the wrapp agree
//  (decision 23 of the builders plan; docs/wrappfile.md#stores).

import Foundation

/// The folders stores live in, by retention and scope:
///
/// ```text
/// keep, app      <Application Support>/<app id>/stores/<owner>/<name>/
/// keep, global   <Application Support>/SecondChance/stores/<owner>/<name>/
/// cache, app     <Caches>/SecondChance/stores/<app id>/<owner>/<name>/
/// cache, global  <Caches>/SecondChance/stores/global/<owner>/<name>/
/// session        <session folder>/<owner>/<name>/
/// ```
///
/// Under test, `SECOND_CHANCE_APP_SUPPORT_DIR` moves an app's own stores,
/// so a test launch starts with none and never touches the person's saves.
/// The global ones stay where they are (`sharedAppSupport`): the
/// integration tests' Steam builds sign in with the saved Steam session, as
/// they always have.
nonisolated public struct StoreLocations: Sendable, Equatable {
    /// Where an app's own kept stores are.
    public let appSupport: URL
    /// Where global kept stores, and locks, are.
    public let sharedAppSupport: URL
    public let caches: URL
    /// The build's or launch's own folder for its session stores, removed
    /// when it ends.
    public let session: URL

    public init(appSupport: URL, sharedAppSupport: URL? = nil, caches: URL, session: URL) {
        self.appSupport = appSupport
        self.sharedAppSupport = sharedAppSupport ?? appSupport
        self.caches = caches
        self.session = session
    }

    /// The real roots, an app's own moved under test; `session` is the
    /// caller's to make and remove.
    public static func current(session: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> StoreLocations {
        StoreLocations(appSupport: UserFilesLayout.appSupport(environment: environment), sharedAppSupport: realAppSupport,
                       caches: realCaches, session: session)
    }

    /// `~/Library/Application Support`.
    public static var realAppSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    /// `~/Library/Caches`.
    public static var realCaches: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0] }

    /// A global kept store's folder, where every build and app finds it:
    /// `steam:sign-in`'s, say.
    public static func shared(owner: String, name: String) -> URL {
        realAppSupport.appendingPathComponent("SecondChance/stores", isDirectory: true)
            .appendingPathComponent(owner, isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    /// A global cache store's folder.
    public static func sharedCache(owner: String, name: String) -> URL {
        realCaches.appendingPathComponent("SecondChance/stores/global", isDirectory: true)
            .appendingPathComponent(owner, isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    /// A global lock's file: `steam:steam`'s, which every Steam app takes.
    public static func sharedLockFile(owner: String, name: String) -> URL {
        realAppSupport.appendingPathComponent("SecondChance/stores/locks", isDirectory: true).appendingPathComponent("\(owner).\(name).lock")
    }

    /// A store's folder. `retention` is `keep`, `cache` or `session`, and
    /// `global` its scope's being global; `appID` the app it's for.
    public func folder(owner: String, name: String, retention: String, global: Bool, appID: String) -> URL {
        switch retention {
        case "session":
            return session.appendingPathComponent(owner, isDirectory: true).appendingPathComponent(name, isDirectory: true)
        case "cache":
            return caches.appendingPathComponent("SecondChance/stores", isDirectory: true)
                .appendingPathComponent(global ? "global" : appID, isDirectory: true)
                .appendingPathComponent(owner, isDirectory: true).appendingPathComponent(name, isDirectory: true)
        default:
            if global {
                return sharedAppSupport.appendingPathComponent("SecondChance/stores", isDirectory: true)
                    .appendingPathComponent(owner, isDirectory: true).appendingPathComponent(name, isDirectory: true)
            }
            return UserFilesLayout(appSupport: appSupport, bundleID: appID).store(owner: owner, name: name)
        }
    }

    /// Where a lock's file is: beside the global stores for a global lock,
    /// in the app's folder for an app's.
    public func lockFile(owner: String, name: String, global: Bool, appID: String) -> URL {
        let folder = global ? sharedAppSupport.appendingPathComponent("SecondChance/stores/locks", isDirectory: true)
            : UserFilesLayout(appSupport: appSupport, bundleID: appID).folder.appendingPathComponent("stores/locks", isDirectory: true)
        return folder.appendingPathComponent("\(owner).\(name).lock")
    }
}
