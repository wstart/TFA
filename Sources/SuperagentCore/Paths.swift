import Foundation

/// Superagent 的磁盘位置。`TFA_HOME` 可整体重定向（测试 / 私有实例），默认 `~/.tfa`。
public enum SuperagentPaths {
    public static var home: URL { home(environment: ProcessInfo.processInfo.environment) }
    /// 同 `home`，但读给定的环境（`tfa` 命令行把环境显式传进来，测试可以换自己的 TFA_HOME）。
    public static func home(environment: [String: String]) -> URL {
        if let h = environment["TFA_HOME"], !h.isEmpty { return URL(fileURLWithPath: h, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tfa", isDirectory: true)
    }
    public static var database: URL { home.appendingPathComponent("superagent.db") }
    /// 主管 / 执行者的 system prompt 文件（App 启动时写入）。
    public static var promptsDir: URL { home.appendingPathComponent("superagent", isDirectory: true) }
    public static var routerPrompt: URL { promptsDir.appendingPathComponent("router.md") }
    public static var workerPrompt: URL { promptsDir.appendingPathComponent("worker.md") }
    /// `tfa` 命令行的符号链接所在目录（执行终端和主管的 PATH 前缀）。
    public static var binDir: URL { home.appendingPathComponent("bin", isDirectory: true) }
    /// 每个工单的 git worktree 放在这里：`<repo名>-<工单号>`。
    public static var worktreesDir: URL { home.appendingPathComponent("worktrees", isDirectory: true) }

    /// CLI 提交后发出的 Darwin 通知名，App 收到后立刻跑一轮 Pass（否则等 2 秒心跳）。
    /// 名字带上 home 路径的稳定哈希（`hashValue` 每个进程不同，不能用），私有实例互不干扰。
    public static var changedNotification: String {
        var h: UInt32 = 2166136261
        for b in home.path.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return "com.tfa.superagent.changed." + String(h, radix: 16)
    }
}
