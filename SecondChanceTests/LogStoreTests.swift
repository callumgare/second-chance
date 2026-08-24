//
//  LogStoreTests.swift
//  SecondChanceTests
//
//  Exercises the LogStore ring: ordering under concurrent emission, the
//  subscribe contract (no gap, no duplicate), eviction and truncation, the
//  formatter styles, and the disk mirror.
//
//  Note: LogStore.shared is process-wide in the test host, hence .serialized.

import Testing
import Foundation
@testable import SecondChance

@Suite("LogStore", .serialized)
struct LogStoreTests {

    // MARK: - Ordering

    @Test("Concurrent emission preserves global seq ordering per subscriber")
    func concurrentOrdering() async throws {
        let store = LogStore.shared
        let (before, cancelBefore) = store.subscribe { _ in }
        // Drain whatever came before so the batch we assert on is clean.
        cancelBefore()
        _ = before

        let counter = Counter()
        let group = DispatchGroup()

        // 8 threads × 100 appends, each batch tagged with its thread index.
        for t in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                for i in 0..<100 {
                    store.append(level: "notice",
                                 label: "au.gare.callum.second-chance.Test.Ordering",
                                 message: "t\(t)-i\(i)")
                    counter.increment()
                }
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + 10)

        let (entries, _) = store.snapshot()
        let tagged = entries.filter { $0.label.hasSuffix("Test.Ordering") && $0.message.hasPrefix("t") }
        #expect(tagged.count == 800, "expected 800 entries, got \(tagged.count)")

        // Monotonic seq across all entries (the ring assigns under one lock).
        for i in 1..<tagged.count {
            #expect(tagged[i].seq > tagged[i - 1].seq, "seq not monotonic at \(i)")
        }
    }

    // MARK: - Subscribe contract

    @Test("Subscribe: snapshot then live batches — no gap, no duplicate")
    func subscribeContract() async throws {
        let store = LogStore.shared

        // Unique label so this test only sees its own entries.
        let label = "au.gare.callum.second-chance.Test.Subscribe-\(UUID().uuidString)"

        // 3 entries before subscribing → they must be in the snapshot.
        for i in 0..<3 {
            store.append(level: "notice", label: label, message: "pre-\(i)")
        }

        let collector = EntryCollector()
        let (snapshot, cancel) = store.subscribe { batch in
            Task { await collector.add(batch) }
        }
        defer { cancel() }

        // 3 entries after subscribing → must arrive via the live path.
        for i in 0..<3 {
            store.append(level: "notice", label: label, message: "post-\(i)")
        }

        // Wait for the live batch to be delivered.
        try await waitUntil(timeout: 2.0) {
            await collector.count(withLabel: label) >= 3
        }

        let snapshotted = snapshot.filter { $0.label == label }
        #expect(snapshotted.count == 3, "snapshot should hold the 3 pre entries")
        #expect(snapshotted.map(\.message) == ["pre-0", "pre-1", "pre-2"])

        // Contract: snapshot seqs all < live seqs; live has no duplicates or gaps.
        let snapshotSeqs = Set(snapshotted.map(\.seq))
        let live = await collector.entries(withLabel: label)
        #expect(live.count == 3, "live batches should deliver exactly the 3 post entries, got \(live.count)")
        let liveSeqs = live.map(\.seq)
        #expect(Set(liveSeqs).count == liveSeqs.count, "live delivery contained duplicates")
        for seq in liveSeqs {
            #expect(!snapshotSeqs.contains(seq), "entry \(seq) appeared in snapshot AND live delivery")
        }
        let sorted = liveSeqs.sorted()
        if sorted.count == 3 {
            #expect(sorted[2] - sorted[0] == 2, "live seqs should be contiguous, got \(sorted)")
        }
    }

    // MARK: - Eviction and truncation

    @Test("Messages over 4 KB are truncated with a marker")
    func truncation() {
        let store = LogStore.shared
        let label = "au.gare.callum.second-chance.Test.Truncate"
        let long = String(repeating: "x", count: 8_192)
        store.append(level: "notice", label: label, message: long)

        let (entries, _) = store.snapshot()
        let entry = entries.last { $0.label == label && $0.message.contains("x") }
        #expect(entry != nil)
        #expect(entry!.message.utf8.count <= 4_100, "truncated message should be ≤ ~4 KB")
        #expect(entry!.message.contains("[truncated"), "truncation marker missing")
    }

    @Test("Empty messages with no error are not stored")
    func emptyAppendSkipped() {
        let store = LogStore.shared
        let label = "au.gare.callum.second-chance.Test.Empty"
        let (before, _) = store.snapshot()
        store.append(level: "notice", label: label, message: "")
        let (after, _) = store.snapshot()
        #expect(after.count == before.count)
    }

    // MARK: - Formatter

    @Test("Compact format: time, level, category, message")
    func compactFormat() {
        let entry = Entry(
            seq: 1,
            timestamp: Date(timeIntervalSince1970: 1_771_200_000),
            level: "notice",
            label: "au.gare.callum.second-chance.SecondChance.GameDetector",
            message: "hello",
            error: nil
        )
        let line = LogFormatter.compact(entry: entry)
        #expect(line.contains("notice"))
        #expect(line.contains("GameDetector"))
        #expect(line.hasSuffix("hello"))
        #expect(!line.contains("au.gare.callum"), "compact format should not carry the full label")
    }

    @Test("Full format: one line per entry with full label, level, message and error")
    func fullFormat() {
        let entry = Entry(
            seq: 1,
            timestamp: Date(timeIntervalSince1970: 1_771_200_000),
            level: "error",
            label: "au.gare.callum.second-chance.SecondChance.GameInstallerRunner",
            message: "install failed",
            error: "disk full"
        )
        let text = LogFormatter.full(entry: entry)
        #expect(!text.contains("\n"), "single-line message should render as a single line")
        #expect(text.hasPrefix("2026-02-16T00:00:00.000Z"), "expected ISO8601 timestamp prefix, got: \(text)")
        #expect(text.contains("  error  au.gare.callum.second-chance.SecondChance.GameInstallerRunner  install failed"),
                "expected `ts  level  label  message` layout, got: \(text)")
        #expect(text.hasSuffix(" — Error: disk full"), "expected error appended in-band, got: \(text)")
        // The level is rendered verbatim in full format (no compact-style coalescing).
        #expect(text.contains("  error  "), "full format must not coalesce levels")
    }

    // MARK: - Disk mirror

    @Test("Disk mirror writes the backfill and live entries")
    func diskMirror() async throws {
        let store = LogStore.shared
        let label = "au.gare.callum.second-chance.Test.Mirror"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sc-mirror-test-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }

        for i in 0..<3 {
            store.append(level: "notice", label: label, message: "backfill-\(i)")
        }

        store.setDiskMirror(enabled: true, path: url)

        // Live entry after enabling → arrives via drain.
        store.append(level: "notice", label: label, message: "live-after-mirror")
        store.flush(timeout: 2.0)

        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        #expect(text.contains("backfill-0"), "backfill entry 0 missing from mirror")
        #expect(text.contains("backfill-2"), "backfill entry 2 missing from mirror")
        #expect(text.contains("live-after-mirror"), "live entry missing from mirror")

        store.setDiskMirror(enabled: false)
    }

    // MARK: - Helpers

    actor Counter {
        private var value = 0
        func increment() { value += 1 }
    }

    actor EntryCollector {
        private var batches: [[Entry]] = []
        func add(_ batch: [Entry]) { batches.append(batch) }
        func entries(withLabel label: String) -> [Entry] {
            batches.flatMap { $0 }.filter { $0.label == label }
        }
        func count(withLabel label: String) -> Int {
            entries(withLabel: label).count
        }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
