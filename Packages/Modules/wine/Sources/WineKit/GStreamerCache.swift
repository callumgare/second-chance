//
//  GStreamerCache.swift
//  WineKit
//
//  GStreamer's plugin cache (its registry) for each copy of Wine's
//  GStreamer, built before a game needs it.
//
//  Wine decodes media through GStreamer (DirectShow and Media Foundation:
//  an MP3 played through MCI). GStreamer keeps what each of its ~200
//  plugins offers in a registry file, by default one per Mac user
//  (~/.cache/gstreamer-1.0/registry.x86_64.bin), keyed by each plugin's
//  path. Every wrapp carries its own copy of GStreamer, so every wrapp that
//  used it left the shared file stale for the next, and the next rescanned
//  every plugin inside the game process the first time it opened a media
//  file: Iji's title screen froze for a minute, its main thread waiting on
//  quartz's filter thread while winegstreamer started up. Each copy now has
//  a registry of its own, under Second Chance's caches, named by where that
//  copy is, and it's built outside the game: by GStreamer's own
//  gst-inspect, with the environment Wine gives the game, so the game finds
//  it fresh. The first load of a plugin from a new place is slow under
//  Rosetta (about a minute for them all, on a quiet Mac), later ones aren't
//  (about 2 s for the whole scan).

import CryptoKit
import Foundation
import Logging
import ProcessKit

nonisolated extension Wine {
    /// The GStreamer framework this Wine decodes media with: the engine's own
    /// (a WineHQ build's) or the wrapper template's.
    public var gstreamerFramework: URL {
        gstreamerPlugins.deletingLastPathComponent().deletingLastPathComponent()
    }

    /// GStreamer's plugin cache for this copy of it: one per place a copy is,
    /// so wrapps never leave each other's stale.
    public var gstreamerRegistry: URL {
        Self.gstreamerRegistry(for: gstreamerFramework)
    }

    /// Where the plugin cache of the GStreamer framework at `framework` is.
    static func gstreamerRegistry(for framework: URL, caches: URL? = nil) -> URL {
        let key = SHA256.hash(data: Data(framework.standardizedFileURL.path.utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        let root = caches ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("SecondChance/gstreamer/registry-\(key).x86_64.bin")
    }

    /// GStreamer's own tool, which builds the cache as it starts.
    var gstreamerInspect: URL {
        gstreamerFramework.appendingPathComponent("Commands/gst-inspect-1.0")
    }

    /// Builds this copy's plugin cache when it hasn't one, before a game
    /// needs it; nothing when it has (GStreamer itself rescans only plugins
    /// that changed, and a wrapp's don't). Never throws: a game without the
    /// cache only waits for GStreamer to build it, as before.
    public func warmGStreamerCache(logger: Logger, timeout: Duration = .seconds(300)) async {
        let registry = gstreamerRegistry
        guard !FileManager.default.fileExists(atPath: registry.path) else { return }
        let inspect = gstreamerInspect
        guard FileManager.default.isExecutableFile(atPath: inspect.path) else {
            logger.notice("[GStreamer] No gst-inspect in \(gstreamerFramework.path): the game builds GStreamer's plugin cache itself")
            return
        }
        do {
            try FileManager.default.createDirectory(at: registry.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            logger.warning("[GStreamer] Couldn't make the folder for GStreamer's plugin cache: \(error)")
            return
        }
        logger.notice("[GStreamer] Building GStreamer's plugin cache for this copy of Wine (\(registry.lastPathComponent))")
        let started = ContinuousClock.now
        let environment = self.environment
        do {
            let result = try await withThrowingTaskGroup(of: ProcessOutput?.self) { group in
                group.addTask { try await Process.output(of: inspect.path, ["coreelements"], environment: environment) }
                group.addTask { try await Task.sleep(for: timeout); return nil }
                let first = try await group.next() ?? nil
                group.cancelAll()
                return first
            }
            let took = ContinuousClock.now - started
            if let result, result.succeeded, FileManager.default.fileExists(atPath: registry.path) {
                logger.notice("[GStreamer] Plugin cache built in \(took.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1))))")
            } else if let result {
                logger.warning("[GStreamer] gst-inspect exited \(result.status) without a plugin cache: \(result.errorOutput.suffix(300))")
            } else {
                logger.warning("[GStreamer] Gave up building the plugin cache after \(timeout): the game will build it")
            }
        } catch {
            logger.warning("[GStreamer] Couldn't build the plugin cache: \(error)")
        }
    }
}
