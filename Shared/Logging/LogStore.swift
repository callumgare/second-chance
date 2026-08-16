//
//  LogStore.swift
//  Shared
//
//  Central in-memory log storage with fixed-capacity ring buffer and serial drain queue.
//  Subscribers receive batches of entries from a monotonic sequence, ensuring no gaps or duplicates.

import Foundation
import os
import Synchronization

/// File-scope entry to avoid nested type inference issues under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor.
nonisolated struct Entry: Sendable {
    let seq: UInt64
    let timestamp: Date
    let level: String
    let label: String
    let message: String
    let error: String?
}

/// Central log storage singleton. Thread-safe via Mutex.
nonisolated final class LogStore: @unchecked Sendable {
    
    // MARK: - Configuration
    
    private static let maxEntries = 50_000
    private static let maxMessageBytes = 32 * 1024 * 1024  // 32 MB
    private static let maxEntryBytes = 4_096  // 4 KB per message
    
    // MARK: - State (guarded by lock)
    
    private struct State {
        var ring: ContiguousArray<Entry>
        var head: Int  // Index of oldest entry
        var count: Int  // Number of valid entries
        var nextSeq: UInt64  // Next sequence number to assign
        var dropped: UInt64  // Number of entries dropped due to eviction
        
        var pending: ContiguousArray<Entry>  // Entries waiting for drain
        var subscribers: [Subscriber]  // Active subscriptions
        
        var drainScheduled: Bool  // Whether drain is queued
        
        var mirrorPath: URL?  // Disk mirror file path
        var mirrorHandle: FileHandle?  // Open file handle for mirror
        var mirrorEnabled: Bool = false
        var mirrorFailureCount: Int = 0  // Consecutive failures for latch-off
        
        var totalMessageBytes: Int  // Approximate total size of stored messages
    }
    
    private struct Subscriber: Sendable {
        let id: UUID
        var cursor: UInt64  // Next sequence number this subscriber needs
        let handler: @Sendable ([Entry]) -> Void
    }
    
    private let lock = Mutex(State(
        ring: ContiguousArray<Entry>(),
        head: 0,
        count: 0,
        nextSeq: 1,
        dropped: 0,
        pending: ContiguousArray<Entry>(),
        subscribers: [],
        drainScheduled: false,
        mirrorPath: nil,
        mirrorHandle: nil,
        mirrorEnabled: false,
        mirrorFailureCount: 0,
        totalMessageBytes: 0
    ))
    
    /// Dedicated serial drain queue. All subscriber delivery, mirror writes and
    /// stderr writes happen here, giving one global ordering shared by every sink.
    private nonisolated let drainQueue = DispatchQueue(label: "au.gare.callum.second-chance.logstore.drain", qos: .utility)
    
    /// Queue-specific marker for re-entrancy detection on the drain queue.
    private nonisolated static let drainQueueKey = DispatchSpecificKey<Bool>()
    
    // MARK: - Singleton
    
    nonisolated static let shared = LogStore()
    
    private init() {
        drainQueue.setSpecific(key: Self.drainQueueKey, value: true)
    }
    
    // MARK: - Public API
    
    /// Synchronously drain any pending entries. Call from exit paths
    /// (`exit()`, `applicationShouldTerminate`) so the disk mirror and
    /// stderr don't lose the last lines.
    nonisolated func flush(timeout: TimeInterval = 2.0) {
        drainQueue.sync {
            self.drain()
        }
    }
    
    // MARK: - Public API
    
    /// Append a log entry to the store.
    nonisolated func append(level: String, label: String, message: String, error: String? = nil) {
        // Check for re-entrancy: if called from drain queue, append but don't re-enqueue
        if isRunningInDrainQueue() {
            guard let entry = createEntry(level: level, label: label, message: message, error: error) else {
                return
            }
            _ = lock.withLock { state in
                appendInternal(state: &state, entry: entry)
            }
            return
        }
        
        guard let entry = createEntry(level: level, label: label, message: message, error: error) else {
            return
        }
        
        let shouldScheduleDrain = lock.withLock { state -> Bool in
            appendInternal(state: &state, entry: entry)
            return scheduleDrainIfNeeded(state: &state)
        }
        
        if shouldScheduleDrain {
            scheduleDrain()
        }
    }
    
    /// Subscribe to log entries. Returns a snapshot of entries before the cursor,
    /// then receives batches of new entries going forward via the handler.
    ///
    /// - Parameter handler: Closure called with batches of new entries. Must be @Sendable.
    /// - Returns: A tuple containing the snapshot and a cancellation function.
    nonisolated func subscribe(handler: @escaping @Sendable ([Entry]) -> Void) -> ([Entry], @Sendable () -> Void) {
        let subscriberId = UUID()
        let (snapshot, cursor) = lock.withLock { state -> ([Entry], UInt64) in
            let snapshot = getSnapshot(state: state)
            state.subscribers.append(Subscriber(
                id: subscriberId,
                cursor: state.nextSeq,
                handler: handler
            ))
            return (snapshot, state.nextSeq)
        }
        return (snapshot, { [weak self] in self?.unsubscribe(id: subscriberId) })
    }
    
    /// Enable or disable disk mirroring.
    nonisolated func setDiskMirror(enabled: Bool, path: URL? = nil) {
        let backfill: [Entry]? = lock.withLock { state -> [Entry]? in
            state.mirrorEnabled = enabled
            if enabled {
                if let path = path {
                    state.mirrorPath = path
                } else if state.mirrorPath == nil {
                    // Generate default path if none provided
                    state.mirrorPath = defaultMirrorPath()
                }
            }
            
            // Close existing handle if disabling
            if !enabled, let handle = state.mirrorHandle {
                try? handle.close()
                state.mirrorHandle = nil
            }
            
            state.mirrorFailureCount = 0
            
            // Backfill existing ring if enabling
            return enabled ? getSnapshot(state: state) : nil
        }
        
        guard let backfill, !backfill.isEmpty else { return }
        // Write the backfill on the drain queue so it serialises with live writes.
        drainQueue.async { [weak self] in
            self?.writeToMirror(entries: ContiguousArray(backfill))
        }
    }
    
    /// Get a snapshot of all current entries and drop count.
    nonisolated func snapshot() -> (entries: [Entry], dropped: UInt64) {
        lock.withLock { state in
            return (getSnapshot(state: state), state.dropped)
        }
    }
    
    // MARK: - Internal
    
    /// Create an entry, truncating if necessary. Returns nil if entry is empty.
    private func createEntry(level: String, label: String, message: String, error: String?) -> Entry? {
        var truncatedMessage = message
        if message.utf8.count > Self.maxEntryBytes {
            let truncatedBytes = message.prefix(Self.maxEntryBytes - 50)
            truncatedMessage = String(truncatedBytes) + "…[truncated \(message.utf8.count - Self.maxEntryBytes + 50) bytes]"
        }
        
        // Flatten to strings per plan: store descriptions, not objects
        let entry = Entry(
            seq: 0,  // Will be assigned in appendInternal
            timestamp: Date(),
            level: level,
            label: label,
            message: truncatedMessage,
            error: error
        )
        
        // Don't append empty entries
        if truncatedMessage.isEmpty && error == nil {
            return nil
        }
        
        return entry
    }
    
    /// Append an entry to the ring buffer under lock.
    private func appendInternal(state: inout State, entry: Entry) {
        var mutableEntry = entry
        mutableEntry = Entry(
            seq: state.nextSeq,
            timestamp: entry.timestamp,
            level: entry.level,
            label: entry.label,
            message: entry.message,
            error: entry.error
        )
        state.nextSeq &+= 1
        
        // Evict if at capacity
        if state.count >= Self.maxEntries || state.totalMessageBytes >= Self.maxMessageBytes {
            // Remove oldest entry
            if state.count > 0 {
                let oldEntry = state.ring[state.head]
                state.totalMessageBytes -= oldEntry.message.utf8.count
                state.head = (state.head + 1) % Self.maxEntries
                state.count -= 1
                state.dropped &+= 1
            }
        }
        
        // Add new entry
        if state.ring.count < Self.maxEntries {
            state.ring.append(mutableEntry)
        } else {
            state.ring[(state.head + state.count) % Self.maxEntries] = mutableEntry
        }
        state.count &+= 1
        state.totalMessageBytes += mutableEntry.message.utf8.count
        
        // Add to pending queue for delivery
        state.pending.append(mutableEntry)
    }
    
    /// Schedule drain if not already scheduled.
    private func scheduleDrainIfNeeded(state: inout State) -> Bool {
        if !state.drainScheduled && !state.pending.isEmpty {
            state.drainScheduled = true
            return true
        }
        return false
    }
    
    /// Schedule drain on the dedicated serial queue.
    private func scheduleDrain() {
        drainQueue.async { [weak self] in
            self?.drain()
        }
    }
    
    /// Drain pending entries to subscribers and mirrors.
    /// Always called on drainQueue (serial), except from flush().
    private func drain() {
        // Mark that we're in the drain queue for re-entrancy detection
        // (dispatchPrecondition would also work; the specific is cheaper to read from append)
        var subscribersToNotify: [(handler: @Sendable ([Entry]) -> Void, entries: [Entry])] = []
        var needsMirrorWrite = false
        
        // Capture pending entries and update cursors
        var entries = ContiguousArray<Entry>()
        lock.withLock { state in
            guard !state.pending.isEmpty else {
                state.drainScheduled = false
                return
            }
            
            entries = state.pending
            state.pending.removeAll()
            
            // Update subscriber cursors and collect batches
            for i in state.subscribers.indices {
                var batch: [Entry] = []
                for entry in entries {
                    if entry.seq >= state.subscribers[i].cursor {
                        batch.append(entry)
                    }
                }
                
                if !batch.isEmpty {
                    if let last = batch.last {
                        state.subscribers[i].cursor = last.seq + 1
                    }
                    subscribersToNotify.append((state.subscribers[i].handler, batch))
                }
            }
            
            state.drainScheduled = false
            needsMirrorWrite = state.mirrorEnabled && !entries.isEmpty
        }
        
        // Deliver to subscribers
        for (handler, batch) in subscribersToNotify {
            handler(batch)
        }
        
        // Write to disk mirror if enabled
        if needsMirrorWrite {
            writeToMirror(entries: entries)
        }
        
        // Write to stderr if isatty
        if isatty(STDERR_FILENO) != 0 {
            writeToStderr(entries: entries)
        }
    }
    
    /// Re-entrancy detection: true when running on the drain queue.
    /// Appends from the drain queue (e.g. a subscriber logging) record into
    /// the ring but don't re-enqueue, preventing unbounded recursion
    /// (mirror fails → logs error → drains → mirror retries → …).
    private func isRunningInDrainQueue() -> Bool {
        return DispatchQueue.getSpecific(key: Self.drainQueueKey) == true
    }
    
    /// Get snapshot of current ring entries.
    private func getSnapshot(state: State) -> [Entry] {
        if state.count == 0 {
            return []
        }
        
        var snapshot: [Entry] = []
        snapshot.reserveCapacity(state.count)
        
        for i in 0..<state.count {
            let idx = (state.head + i) % state.ring.count
            snapshot.append(state.ring[idx])
        }
        
        return snapshot
    }
    
    /// Unsubscribe a subscriber by ID.
    private func unsubscribe(id: UUID) {
        lock.withLock { state in
            state.subscribers.removeAll { $0.id == id }
        }
    }
    
    /// Write entries to the disk mirror using the persistent handle.
    /// Called only on drainQueue, so handle access is serialised.
    private func writeToMirror(entries: ContiguousArray<Entry>) {
        guard !entries.isEmpty else { return }
        
        let text = entries.map { LogFormatter.full(entry: $0) }.joined(separator: "\n") + "\n"
        guard let data = text.data(using: .utf8) else { return }
        
        // Open (or create) the persistent handle if needed
        let maybeHandle: FileHandle? = lock.withLock { state -> FileHandle? in
            guard state.mirrorEnabled, let path = state.mirrorPath else { return nil }
            if let handle = state.mirrorHandle {
                return handle
            }
            // Create if missing, then open for writing
            if !FileManager.default.fileExists(atPath: path.path) {
                FileManager.default.createFile(atPath: path.path, contents: nil)
            }
            do {
                let handle = try FileHandle(forWritingTo: path)
                // forWritingTo opens at position 0 — seek to end to append.
                try handle.seekToEnd()
                state.mirrorHandle = handle
                return handle
            } catch {
                return nil
            }
        }
        
        guard let handle = maybeHandle else {
            // Mirror was disabled between scheduling and now — not a failure.
            return
        }
        
        do {
            // Throwing variant: the non-throwing write(_:) raises an
            // uncatchable ObjC exception on EPIPE/ENOSPC.
            try handle.write(contentsOf: data)
            lock.withLock { state in
                state.mirrorFailureCount = 0
            }
        } catch {
            handleMirrorFailure()
        }
    }
    
    /// Handle mirror write failure with latch-off after consecutive failures.
    private func handleMirrorFailure() {
        let failureCount = lock.withLock { state -> Int in
            state.mirrorFailureCount &+= 1
            if state.mirrorFailureCount >= 3 {
                state.mirrorEnabled = false
                if let handle = state.mirrorHandle {
                    try? handle.close()
                    state.mirrorHandle = nil
                }
            }
            return state.mirrorFailureCount
        }
        
        if failureCount >= 3 {
            internalFault("Disk mirror disabled after \(failureCount) consecutive failures")
            // Append one synthetic entry so the gap is visible in the ring/export.
            append(level: "error",
                   label: "au.gare.callum.second-chance.LogStore",
                   message: "Disk mirror disabled after \(failureCount) consecutive write failures; logs continue in memory only.")
        } else {
            internalFault("Disk mirror write failed (attempt \(failureCount))")
        }
    }
    
    /// Write entries to stderr using raw write(2) with EINTR retry.
    private func writeToStderr(entries: ContiguousArray<Entry>) {
        for entry in entries {
            let line = LogFormatter.compact(entry: entry) + "\n"
            if let data = line.data(using: .utf8) {
                var bytesToWrite = data.count
                var ptr = data.withUnsafeBytes { $0.baseAddress }
                
                while bytesToWrite > 0 {
                    let written = write(STDERR_FILENO, ptr, bytesToWrite)
                    if written < 0 {
                        if errno == EINTR {
                            continue  // Retry on interrupt
                        }
                        break  // Give up on other errors
                    }
                    bytesToWrite -= written
                    ptr = ptr?.advanced(by: written)
                }
            }
        }
    }
    
    /// Generate default mirror path in Downloads directory.
    private func defaultMirrorPath() -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())
        let fileName = "second-chance-mirror-\(timestamp).log"
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            .appendingPathComponent(fileName)
    }
    
    /// Internal fault reporting - goes straight to os_log + fputs, bypassing LogStore.
    private func internalFault(_ message: String) {
        // Rate-limit to avoid spam
        // TODO: implement proper rate limiting
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let formatted = "[\(timestamp)] LogStore internal fault: \(message)\n"
        
        // Write to stderr directly
        formatted.withCString { ptr in
            _ = write(STDERR_FILENO, ptr, formatted.utf8.count)
        }
        
        // Also emit to os_log for Console.app visibility
        os_log("LogStore internal fault: %{public}@", log: .default, type: .fault, message)
    }
}