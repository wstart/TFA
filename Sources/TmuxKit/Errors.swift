import Foundation

public enum TmuxError: Error, Sendable, CustomStringConvertible {
    case pty(Int32)
    case spawnFailed(Int32)
    case tmuxNotFound
    case connectionClosed
    case commandFailed(String)

    public var description: String {
        switch self {
        case .pty(let e): return "openpty failed (errno \(e))"
        case .spawnFailed(let e): return "posix_spawn failed (code \(e))"
        case .tmuxNotFound: return "tmux executable not found"
        case .connectionClosed: return "tmux connection closed"
        case .commandFailed(let m): return "tmux command failed: \(m)"
        }
    }
}
