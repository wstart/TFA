import Foundation
import Observation

// MARK: - ID types
//
// tmux 的对象都有稳定的数字 id，前缀区分类型：
//   session: "$0"   window: "@1"   pane: "%3"
// 我们始终用这些 id 作为唯一键（名字可变，id 不变）。

public typealias TmuxSessionID = String
public typealias TmuxWindowID = String
public typealias TmuxPaneID = String

// MARK: - Pane

/// 一个 tmux 窗格。几何信息是窗格在其所属窗口内的格子坐标（cells）。
@Observable
public final class TmuxPane: Identifiable {
    public let id: TmuxPaneID
    public var title: String
    public var currentCommand: String
    /// The pane's current working directory (`#{pane_current_path}`), empty until known.
    public var currentPath: String
    /// The pane's process id (`#{pane_pid}` — the shell), 0 until known. Used to find which listening
    /// ports belong to this terminal (the shell's descendant processes).
    public var pid: Int
    public var active: Bool

    // 在窗口内的几何（单位：字符格）。来自 layout 解析或 list-panes。
    public var width: Int
    public var height: Int
    public var left: Int
    public var top: Int

    public init(
        id: TmuxPaneID,
        title: String = "",
        currentCommand: String = "",
        currentPath: String = "",
        pid: Int = 0,
        active: Bool = false,
        width: Int = 0,
        height: Int = 0,
        left: Int = 0,
        top: Int = 0
    ) {
        self.id = id
        self.title = title
        self.currentCommand = currentCommand
        self.currentPath = currentPath
        self.pid = pid
        self.active = active
        self.width = width
        self.height = height
        self.left = left
        self.top = top
    }
}

// MARK: - Window

/// 一个 tmux 窗口，包含若干窗格，并带有 tmux 的原始 layout 串。
@Observable
public final class TmuxWindow: Identifiable {
    public let id: TmuxWindowID
    public var name: String
    public var active: Bool
    /// tmux 的 window_layout 字符串，例如 "bf3c,80x24,0,0,1"。
    public var layout: String
    public var panes: [TmuxPane]
    public var activePaneID: TmuxPaneID?

    public init(
        id: TmuxWindowID,
        name: String = "",
        active: Bool = false,
        layout: String = "",
        panes: [TmuxPane] = [],
        activePaneID: TmuxPaneID? = nil
    ) {
        self.id = id
        self.name = name
        self.active = active
        self.layout = layout
        self.panes = panes
        self.activePaneID = activePaneID
    }

    public func pane(_ id: TmuxPaneID) -> TmuxPane? {
        panes.first { $0.id == id }
    }
}

// MARK: - Session

/// 一个 tmux 会话，包含若干窗口。
@Observable
public final class TmuxSession: Identifiable {
    public let id: TmuxSessionID
    public var name: String
    public var attached: Bool
    public var windows: [TmuxWindow]
    public var activeWindowID: TmuxWindowID?

    public init(
        id: TmuxSessionID,
        name: String = "",
        attached: Bool = false,
        windows: [TmuxWindow] = [],
        activeWindowID: TmuxWindowID? = nil
    ) {
        self.id = id
        self.name = name
        self.attached = attached
        self.windows = windows
        self.activeWindowID = activeWindowID
    }

    public func window(_ id: TmuxWindowID) -> TmuxWindow? {
        windows.first { $0.id == id }
    }
}

// MARK: - State root

/// 单个 tmux server 连接（本地或某个 ssh 远端）的全部可视化状态。
@Observable
public final class TmuxState {
    /// 连接的可读名字，例如 "local" 或 "ssh:web01"。
    public var connectionName: String
    public var sessions: [TmuxSession]
    /// 是否已与 tmux server 建立控制模式连接。
    public var connected: Bool
    /// 远程登录阶段（ssh 输密码 / 确认主机指纹 / 2FA），尚未进入 tmux 控制模式。
    public var authenticating: Bool

    public init(connectionName: String, sessions: [TmuxSession] = [], connected: Bool = false,
                authenticating: Bool = false) {
        self.connectionName = connectionName
        self.sessions = sessions
        self.connected = connected
        self.authenticating = authenticating
    }

    public func session(_ id: TmuxSessionID) -> TmuxSession? {
        sessions.first { $0.id == id }
    }

    /// 在整个连接范围内按 id 定位一个窗口。
    public func window(_ id: TmuxWindowID) -> TmuxWindow? {
        for s in sessions { if let w = s.window(id) { return w } }
        return nil
    }

    /// 在整个连接范围内按 id 定位一个窗格。
    public func pane(_ id: TmuxPaneID) -> TmuxPane? {
        for s in sessions { for w in s.windows { if let p = w.pane(id) { return p } } }
        return nil
    }
}
