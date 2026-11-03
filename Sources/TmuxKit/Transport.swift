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
    /// Terminate once everything already written has been flushed, giving the process `grace`
    /// seconds to exit by itself first (e.g. after `detach-client` / `kill-session`).
    func terminate(after grace: TimeInterval)
}

public extension TmuxTransport {
    func terminate(after grace: TimeInterval) { terminate() }
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
    /// The child's pid until it has been reaped; -1 afterwards, so a late `terminate()` (deinit)
    /// can never signal a recycled pid. Guarded by `pidLock` (read from any thread, cleared by the
    /// exit source on `ioQueue`).
    private var pid: pid_t = -1
    private let pidLock = NSLock()
    private var exitSource: DispatchSourceProcess?
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
        // New session so the PTY becomes the child's controlling terminal. CLOEXEC_DEFAULT: the
        // child keeps ONLY the fds set up above (0/1/2). Without it every child inherited the other
        // connections' pty masters, so after TFA exited no child ever saw a hangup and they all
        // lived on as orphans, each pinning ptys.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
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
        pidLock.lock(); pid = childPid; pidLock.unlock()
        pty.closeSlave() // parent only needs the master side

        // Reap the child whenever it exits (no zombie left behind), then forget its pid.
        let exit = DispatchSource.makeProcessSource(identifier: childPid, eventMask: .exit, queue: ioQueue)
        exit.setEventHandler { [weak self] in self?.reap(blocking: true) }
        exitSource = exit
        exit.resume()
        ioQueue.async { [weak self] in self?.reap(blocking: false) } // exited before the source armed

        let src = DispatchSource.makeReadSource(fileDescriptor: pty.master, queue: ioQueue)
        src.setEventHandler { [weak self] in self?.readAvailable() }
        src.setCancelHandler { [weak self] in self?.finishClose() }
        readSource = src
        src.resume()
    }

    /// Read buffer reused across reads (only touched on `ioQueue`): allocating and zero-filling
    /// 64 KB per read was pure overhead on the output hot path.
    private let readBuffer = UnsafeMutableRawPointer.allocate(byteCount: 1 << 16, alignment: 16)

    private func readAvailable() {
        guard let pty = pty else { return }
        let n = read(pty.master, readBuffer, 1 << 16)
        if n > 0 {
            onData?(Data(bytes: readBuffer, count: n))
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
        pidLock.lock()
        let target = pid
        pidLock.unlock()
        if target > 0 { kill(target, SIGTERM) }
        readSource?.cancel()
    }

    public func terminate(after grace: TimeInterval) {
        // Queue behind pending writes (same serial queue), so the final commands reach tmux before
        // any signal; then only signal if the child hasn't exited on its own within `grace`.
        writeQueue.async { [weak self] in
            self?.ioQueue.asyncAfter(deadline: .now() + grace) { [weak self] in self?.terminate() }
        }
    }

    /// Collect the child's exit status (blocking only when the exit event already fired) and clear
    /// the pid. Runs on `ioQueue`.
    private func reap(blocking: Bool) {
        pidLock.lock()
        defer { pidLock.unlock() }
        guard pid > 0 else { return }
        var status: Int32 = 0
        let r = waitpid(pid, &status, blocking ? 0 : WNOHANG)
        if r == pid || (r == -1 && errno == ECHILD) {
            pid = -1
            exitSource?.cancel()
        }
    }

    deinit {
        terminate()
        readBuffer.deallocate()
    }

    private func finishClose() {
        guard !didClose else { return }
        didClose = true
        if let pty = pty { close(pty.master) }
        onClose?()
    }
}
