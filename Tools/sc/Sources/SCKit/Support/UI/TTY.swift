import Foundation

/// Low-level terminal state sc changes and must always put back: the cursor
/// (hidden while a live region is drawn) and stdin's line discipline (changed
/// while listening for keys). Everything is restored on every way out —
/// normal exit, error, Ctrl-C, and `exec`.
enum TTY {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cursorHidden = false
    nonisolated(unsafe) private static var savedTermios: termios?

    static func write(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    static func hideCursor() {
        lock.withLock {
            guard !cursorHidden else { return }
            cursorHidden = true
            write("\u{1B}[?25l")
        }
    }

    static func showCursor() {
        lock.withLock {
            guard cursorHidden else { return }
            cursorHidden = false
            write("\u{1B}[?25h")
        }
    }

    /// Stop stdin echoing and line-buffering so single keys can be read, but
    /// keep ISIG on: Ctrl-C must still raise SIGINT and go through sc's
    /// cleanup, not arrive as a character.
    static func enterKeyMode() -> Bool {
        lock.withLock {
            guard savedTermios == nil else { return true }
            var original = termios()
            guard tcgetattr(STDIN_FILENO, &original) == 0 else { return false }
            var raw = original
            raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
            // Return from read() after 0.1 s with or without input, so the
            // reader can notice it has been asked to stop.
            withUnsafeMutableBytes(of: &raw.c_cc) { cc in
                cc[Int(VMIN)] = 0
                cc[Int(VTIME)] = 1
            }
            guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else { return false }
            savedTermios = original
            return true
        }
    }

    static func leaveKeyMode() {
        lock.withLock {
            guard var original = savedTermios else { return }
            tcsetattr(STDIN_FILENO, TCSANOW, &original)
            savedTermios = nil
        }
    }

    /// Put the terminal back as sc found it.
    static func restoreForExit() {
        leaveKeyMode()
        showCursor()
    }
}
