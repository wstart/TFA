import Foundation
import Darwin

/// A pseudo-terminal pair configured in raw mode (no echo / no canonical processing),
/// suitable for hosting `tmux -CC` (which requires a real tty — a plain pipe fails with
/// "tcgetattr failed: Inappropriate ioctl for device").
final class PTY {
    let master: Int32
    let slave: Int32

    init(cols: Int, rows: Int) throws {
        var m: Int32 = 0
        var s: Int32 = 0
        var term = termios()
        cfmakeraw(&term) // 8-bit clean, no echo, no canonical — so written commands aren't echoed back
        var ws = winsize(ws_row: UInt16(max(1, rows)), ws_col: UInt16(max(1, cols)),
                         ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&m, &s, nil, &term, &ws) == 0 else {
            throw TmuxError.pty(errno)
        }
        master = m
        slave = s
        // Close-on-exec for both ends, so no OTHER child spawned by this process (Process(), the
        // ssh askpass helper, …) inherits this pty and keeps it alive after we exit.
        _ = fcntl(m, F_SETFD, FD_CLOEXEC)
        _ = fcntl(s, F_SETFD, FD_CLOEXEC)
    }

    /// The slave device path (e.g. `/dev/ttys003`). Opening THIS in a session-leader child (after
    /// setsid) makes the pty its controlling terminal — required for ssh to read a password.
    var slaveName: String? {
        lock.lock(); defer { lock.unlock() }
        guard masterOpen, let p = ptsname(master) else { return nil }
        return String(cString: p)
    }

    func setWindowSize(cols: Int, rows: Int) {
        lock.lock(); defer { lock.unlock() }
        guard masterOpen else { return }
        var ws = winsize(ws_row: UInt16(max(1, rows)), ws_col: UInt16(max(1, cols)),
                         ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, UInt(TIOCSWINSZ), &ws)
    }

    /// Close each end exactly once. The master is closed by the transport's read-source cancel
    /// handler (dispatch requires the fd to stay open until then); `deinit` is the backstop for
    /// paths that never got that far (spawn failure, never started), so no pty is ever leaked.
    private let lock = NSLock()
    private var masterOpen = true
    private var slaveOpen = true

    func closeSlave() {
        lock.lock(); defer { lock.unlock() }
        guard slaveOpen else { return }
        slaveOpen = false
        close(slave)
    }

    func closeMaster() {
        lock.lock(); defer { lock.unlock() }
        guard masterOpen else { return }
        masterOpen = false
        close(master)
    }

    /// False once the master is closed: writers check it so they never write into a closed (or
    /// already recycled) fd number.
    var isMasterOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return masterOpen
    }

    deinit {
        closeSlave()
        closeMaster()
    }
}
