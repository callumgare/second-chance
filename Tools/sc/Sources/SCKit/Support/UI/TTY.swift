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
        write(Data(text.utf8), to: STDERR_FILENO)
    }

    /// Write to a standard stream with write(2). When the reader has gone (an
    /// ssh session dropped, a pipe closed) the bytes are dropped and sc carries
    /// on with its cleanup: `FileHandle.write` raises an Objective-C exception
    /// there instead, which aborted sc and left the processes it was running
    /// behind.
    static func write(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    return  // EPIPE, EIO, EBADF: nobody is reading any more.
                }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
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
