import Foundation
import Noora

/// Several Noora components on screen at once.
///
/// Noora's own `Renderer` assumes it is the only thing drawing: each component
/// erases the lines *it* drew last time and redraws, so two live components
/// overwrite each other. Every component takes a `renderer:` though, and
/// `Rendering` is a one-method protocol — so the region hands each component
/// its own `Slot`. A slot only stores its component's latest frame; the region
/// erases everything it drew and redraws all the slots, in order, as one block.
///
/// Lines that should stay (a finished step, a failed test) are printed
/// *above* the region with `printAbove` or `commit`, and scroll away like
/// ordinary output. The region is the only writer to stderr while it has
/// slots, so nothing else tears it.
final class LiveRegion: @unchecked Sendable {
    final class Slot: Rendering, @unchecked Sendable {
        fileprivate weak var region: LiveRegion?
        fileprivate var frame: [String] = []
        /// May be cut short when the region is taller than the terminal
        /// (tables), rather than the steps above it.
        fileprivate let trimmable: Bool
        /// Drawn after every other slot whenever it was added (footers).
        fileprivate let pinnedToBottom: Bool

        fileprivate init(region: LiveRegion, trimmable: Bool, pinnedToBottom: Bool) {
            self.region = region
            self.trimmable = trimmable
            self.pinnedToBottom = pinnedToBottom
        }

        func render(_ input: String, standardPipeline _: StandardPipelining) {
            region?.update(self, frame: input.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        }

        /// Print this slot's current frame permanently and drop it from the region.
        func commit() { region?.commit(self) }

        /// Drop this slot without printing anything.
        func remove() { region?.remove(self) }
    }

    private let lock = NSLock()
    private var slots: [Slot] = []
    private var drawnLines = 0
    private var lastDraw = DispatchTime(uptimeNanoseconds: 0)
    private var redrawScheduled = false
    private let write: @Sendable (String) -> Void
    private let size: @Sendable () -> (columns: Int, rows: Int)?
    /// Redraws closer together than this are coalesced (~15 fps).
    private let minimumInterval: UInt64 = 66_000_000

    init(
        write: @escaping @Sendable (String) -> Void = { TTY.write($0) },
        size: @escaping @Sendable () -> (columns: Int, rows: Int)? = { TerminalEnvironment.size() }
    ) {
        self.write = write
        self.size = size
    }

    func addSlot(trimmable: Bool = false, pinnedToBottom: Bool = false) -> Slot {
        lock.withLock {
            let slot = Slot(region: self, trimmable: trimmable, pinnedToBottom: pinnedToBottom)
            slots.append(slot)
            return slot
        }
    }

    var isActive: Bool { lock.withLock { !slots.isEmpty } }

    func printAbove(_ text: String) {
        lock.withLock {
            var out = eraseLocked()
            out += text.hasSuffix("\n") ? text : text + "\n"
            out += drawLocked()
            write(out)
        }
    }

    fileprivate func update(_ slot: Slot, frame: [String]) {
        lock.lock()
        defer { lock.unlock() }
        guard slots.contains(where: { $0 === slot }) else { return }
        slot.frame = frame
        let now = DispatchTime.now()
        if now.uptimeNanoseconds - lastDraw.uptimeNanoseconds >= minimumInterval {
            write(eraseLocked() + drawLocked())
        } else if !redrawScheduled {
            redrawScheduled = true
            let delay = minimumInterval - (now.uptimeNanoseconds - lastDraw.uptimeNanoseconds)
            DispatchQueue.global().asyncAfter(deadline: now + .nanoseconds(Int(delay))) { [weak self] in
                guard let self else { return }
                self.lock.withLock {
                    self.redrawScheduled = false
                    self.write(self.eraseLocked() + self.drawLocked())
                }
            }
        }
    }

    fileprivate func commit(_ slot: Slot) {
        lock.withLock {
            guard let index = slots.firstIndex(where: { $0 === slot }) else { return }
            var out = eraseLocked()
            let columns = size()?.columns
            for line in slot.frame where !line.isEmpty || slot.frame.count == 1 {
                out += (columns.map { ANSI.truncate(line, toWidth: $0) } ?? line) + "\n"
            }
            slots.remove(at: index)
            out += drawLocked()
            write(out)
        }
    }

    fileprivate func remove(_ slot: Slot) {
        lock.withLock {
            guard let index = slots.firstIndex(where: { $0 === slot }) else { return }
            let out = eraseLocked()
            slots.remove(at: index)
            write(out + drawLocked())
        }
    }

    // MARK: - Drawing (lock held)

    /// Move back to the top of what was drawn and clear to the end of the screen.
    private func eraseLocked() -> String {
        guard drawnLines > 0 else { return "" }
        let out = "\r\u{1B}[\(drawnLines)A\u{1B}[J"
        drawnLines = 0
        return out
    }

    private func drawLocked() -> String {
        lastDraw = .now()
        guard !slots.isEmpty else {
            TTY.showCursor()
            return ""
        }
        TTY.hideCursor()
        let terminal = size()
        let ordered = slots.filter { !$0.pinnedToBottom } + slots.filter(\.pinnedToBottom)
        let lines = Self.layout(ordered.map { ($0.frame, $0.trimmable) }, maxLines: terminal.map { max($0.rows - 1, 1) })
        drawnLines = lines.count
        let columns = terminal?.columns
        // Lines wider than the terminal would wrap and throw off the count
        // of lines to erase next time, so they are cut to fit.
        return lines.map { line in (columns.map { ANSI.truncate(line, toWidth: $0) } ?? line) + "\n" }.joined()
    }

    /// The lines to draw: every slot's frame in order, cut down to fit
    /// `maxLines` by shortening trimmable slots first (keeping their first
    /// lines, so tables keep their header and the rows sorted to the top),
    /// then the rest from the top.
    static func layout(_ frames: [(lines: [String], trimmable: Bool)], maxLines: Int?) -> [String] {
        var frames = frames
        guard let maxLines else { return frames.flatMap(\.lines) }
        var total = frames.reduce(0) { $0 + $1.lines.count }
        if total > maxLines {
            for i in frames.indices.reversed() where frames[i].trimmable && total > maxLines {
                let excess = total - maxLines
                let keep = max(frames[i].lines.count - excess - 1, 1)
                let dropped = frames[i].lines.count - keep
                guard dropped > 1 else { continue }
                frames[i].lines = Array(frames[i].lines.prefix(keep)) + ["  … \(dropped) more"]
                total = frames.reduce(0) { $0 + $1.lines.count }
            }
        }
        let lines = frames.flatMap(\.lines)
        return lines.count > maxLines ? Array(lines.suffix(maxLines)) : lines
    }
}

/// A renderer for when nothing is live: each frame is printed as-is, with no
/// cursor movement. Used for non-interactive output, where Noora components
/// render once.
final class AppendingRenderer: Rendering {
    func render(_ input: String, standardPipeline: StandardPipelining) {
        standardPipeline.write(content: input.hasSuffix("\n") ? input : input + "\n")
    }
}

enum ANSI {
    /// Cut `line` to `width` visible columns, leaving escape sequences intact
    /// (so colours aren't left half-open) and resetting styles if anything was cut.
    static func truncate(_ line: String, toWidth width: Int) -> String {
        var visible = 0
        var out = ""
        var cut = false
        var iterator = line.makeIterator()
        while let ch = iterator.next() {
            if ch == "\u{1B}" {
                out.append(ch)
                // Copy the whole escape sequence: ESC [ ... final-byte
                while let next = iterator.next() {
                    out.append(next)
                    if next.isLetter { break }
                }
                continue
            }
            if visible >= width - 1 && width > 1 {
                cut = true
                break
            }
            out.append(ch)
            visible += 1
        }
        return cut ? out + "…\u{1B}[0m" : out
    }

    static func strip(_ line: String) -> String {
        var out = ""
        var iterator = line.makeIterator()
        while let ch = iterator.next() {
            if ch == "\u{1B}" {
                while let next = iterator.next(), !next.isLetter {}
                continue
            }
            out.append(ch)
        }
        return out
    }
}
