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
    }

    /// The slave device path (e.g. `/dev/ttys003`). Opening THIS in a session-leader child (after
    /// setsid) makes the pty its controlling terminal — required for ssh to read a password.
    var slaveName: String? {
        guard let p = ptsname(master) else { return nil }
        return String(cString: p)
    }

    func setWindowSize(cols: Int, rows: Int) {
        var ws = winsize(ws_row: UInt16(max(1, rows)), ws_col: UInt16(max(1, cols)),
                         ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, UInt(TIOCSWINSZ), &ws)
    }

    func closeSlave() { close(slave) }
}
