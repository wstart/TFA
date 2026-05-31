import Foundation
import Darwin

/// Abstracts the byte pipe to a tmux control-mode process (local PTY or ssh-over-PTY).
public protocol TmuxTransport: AnyObject {
    /// Bytes received from tmux. Invoked on a background queue.
    var onData: ((Data) -> Void)? { get set }
    /// Invoked once when the pipe closes / the process exits. On a background queue.
    var onClose: (() -> Void)? { get set }

    func start() throws
    func write(_ data: Data)
    func resize(cols: Int, rows: Int)
    func terminate()
}

/// Runs an arbitrary argv (tmux, or ssh whose remote runs tmux) on a raw PTY and streams
/// its master fd. This is the single transport used for both local and remote connections —
/// only the argv differs (see `TmuxConnection`).
public final class PtyProcessTransport: TmuxTransport {
    public var onData: ((Data) -> Void)?
    public var onClose: (() -> Void)?
    /// Extra environment entries merged over the base env at spawn (e.g. SSH_ASKPASS for ssh
    /// password auth, which doesn't depend on a controlling terminal).
    public var extraEnv: [String: String] = [:]

    private let execPath: String
    private let argv: [String]
    private var cols: Int
    private var rows: Int

    private var pty: PTY?
    private var pid: pid_t = -1
    private var readSource: DispatchSourceRead?
    private let ioQueue = DispatchQueue(label: "tmux.pty.read")
    private let writeQueue = DispatchQueue(label: "tmux.pty.write")
    private var didClose = false

    public init(execPath: String, argv: [String], cols: Int, rows: Int) {
        self.execPath = execPath
        self.argv = argv
        self.cols = cols
        self.rows = rows
    }

    public func start() throws {
        let pty = try PTY(cols: cols, rows: rows)
        self.pty = pty

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        // Open the slave by PATH in the child so that — as a fresh session leader
        // (POSIX_SPAWN_SETSID) — it acquires the pty as its CONTROLLING TERMINAL. Without this, ssh
        // cannot open /dev/tty to prompt for a password and auth fails instantly. (dup2'ing an
        // already-open, inherited slave fd does NOT establish a controlling terminal.)
        if let name = pty.slaveName {
            name.withCString { cpath in
                _ = posix_spawn_file_actions_addopen(&fileActions, 0, cpath, O_RDWR, 0)
            }
        } else {
            posix_spawn_file_actions_adddup2(&fileActions, pty.slave, 0)
        }
        posix_spawn_file_actions_adddup2(&fileActions, 0, 1)
        posix_spawn_file_actions_adddup2(&fileActions, 0, 2)
        posix_spawn_file_actions_addclose(&fileActions, pty.master)
        posix_spawn_file_actions_addclose(&fileActions, pty.slave)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        // New session so the PTY becomes the child's controlling terminal.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        defer { posix_spawnattr_destroy(&attr) }

        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cargs.append(nil)
        defer { for p in cargs where p != nil { free(p) } }

        // Force a UTF-8 ctype so tmux + the pane's shell handle multibyte (e.g. CJK) names/paths
        // even when the app was launched from Finder with a minimal/C-locale environment.
        var envMap = TmuxServer.utf8Environment()
        for (k, v) in extraEnv { envMap[k] = v }
        var cenv: [UnsafeMutablePointer<CChar>?] = envMap.map { strdup("\($0)=\($1)") }
        cenv.append(nil)
        defer { for p in cenv where p != nil { free(p) } }

        var childPid: pid_t = 0
        let rc = posix_spawn(&childPid, execPath, &fileActions, &attr, cargs, cenv)
        guard rc == 0 else { throw TmuxError.spawnFailed(rc) }
        pid = childPid
        pty.closeSlave() // parent only needs the master side

        let src = DispatchSource.makeReadSource(fileDescriptor: pty.master, queue: ioQueue)
        src.setEventHandler { [weak self] in self?.readAvailable() }
        src.setCancelHandler { [weak self] in self?.finishClose() }
        readSource = src
        src.resume()
    }

    private func readAvailable() {
        guard let pty = pty else { return }
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        let n = buf.withUnsafeMutableBytes { read(pty.master, $0.baseAddress, $0.count) }
        if n > 0 {
            onData?(Data(buf[0..<n]))
        } else if n == 0 {
            readSource?.cancel()
        } else {
            if errno == EAGAIN || errno == EINTR { return }
            readSource?.cancel()
        }
    }

    public func write(_ data: Data) {
        writeQueue.async { [weak self] in
            guard let self = self, let pty = self.pty else { return }
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                var off = 0
                let total = raw.count
                while off < total {
                    let w = Darwin.write(pty.master, base + off, total - off)
                    if w > 0 {
                        off += w
                    } else if w < 0 && (errno == EAGAIN || errno == EINTR) {
                        continue
                    } else {
                        break
                    }
                }
            }
        }
    }

    public func resize(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        pty?.setWindowSize(cols: cols, rows: rows)
    }

    public func terminate() {
        if pid > 0 { kill(pid, SIGTERM) }
        readSource?.cancel()
    }

    deinit { terminate() }

    private func finishClose() {
        guard !didClose else { return }
        didClose = true
        if let pty = pty { close(pty.master) }
        if pid > 0 {
            var status: Int32 = 0
            waitpid(pid, &status, WNOHANG)
        }
        onClose?()
    }
}
