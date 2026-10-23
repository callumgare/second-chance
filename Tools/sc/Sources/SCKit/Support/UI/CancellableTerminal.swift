import Foundation
import Noora

/// Noora's terminal, with key reads that give up when the task is cancelled.
///
/// Noora's prompts block in `read(2)` until a key arrives, and a cancelled
/// task can't unwind a thread stuck there: Ctrl-C at a prompt said it was
/// stopping and then hung until a second Ctrl-C quit outright, skipping the
/// cleanup — `sc release` left its version bump behind. Here each read first
/// waits for input in short polls, checking for cancellation between them,
/// and returns nil once cancelled, which ends the prompt's key loop. The
/// prompt wrappers in `UI` then throw rather than act on its answer.
struct CancellableTerminal: Terminaling {
    let inner: Terminal

    /// Noora reads keys with `getchar()`, and a buffered stdin pulls a whole
    /// escape sequence into stdio's buffer on the first read, where `poll`
    /// can't see the rest: an arrow key was then handled a keypress late, so
    /// ←/→ then Enter at a yes/no prompt toggled back and answered the
    /// default. Unbuffered, every byte waits on the descriptor.
    init(inner: Terminal) {
        self.inner = inner
        setvbuf(stdin, nil, _IONBF, 0)
    }

    var isInteractive: Bool { inner.isInteractive }
    var isColored: Bool { inner.isColored }
    var signalBehavior: SignalBehavior { inner.signalBehavior }

    func withoutCursor(_ body: () throws -> Void) rethrows { try inner.withoutCursor(body) }
    func inRawMode(_ body: @escaping () throws -> Void) rethrows { try inner.inRawMode(body) }
    func size() -> TerminalSize? { inner.size() }

    func readRawCharacter() -> Int32? {
        waitForInput() ? inner.readRawCharacter() : nil
    }

    func readCharacter() -> Character? {
        waitForInput() ? inner.readCharacter() : nil
    }

    func readRawCharacterNonBlocking() -> Int32? { inner.readRawCharacterNonBlocking() }
    func readCharacterNonBlocking() -> Character? { inner.readCharacterNonBlocking() }

    /// True once stdin has something to read (or has closed, which the read
    /// then reports), false once the task is cancelled.
    private func waitForInput() -> Bool {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        while !Task.isCancelled {
            if poll(&descriptor, 1, 100) > 0 { return true }
        }
        return false
    }
}
