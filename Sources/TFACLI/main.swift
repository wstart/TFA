import Foundation
import notify
import SuperagentCore
import TFACLIKit

/// 管道 / heredoc 传入的长文本。stdin 是终端，或 1 秒内既没数据也没 EOF（agent 的工具可能给一个
/// 永不关闭的管道）→ nil，避免卡死。分块读：读到 EOF，或连续 1 秒没有新数据就停（有数据却不关的管道也不卡）。
func pipedStdin() -> String? {
    guard isatty(0) == 0 else { return nil }
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        var p = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, 1000) > 0, p.revents & Int16(POLLIN | POLLHUP) != 0 else { break }
        let n = read(0, &buf, buf.count)
        if n <= 0 { break }
        data.append(buf, count: n)
    }
    return data.isEmpty ? nil : String(decoding: data, as: UTF8.self)
}

let outcome = TFACommand.run(Array(CommandLine.arguments.dropFirst()), env: ProcessInfo.processInfo.environment,
                             cwd: FileManager.default.currentDirectoryPath, stdin: pipedStdin)
if !outcome.out.isEmpty { FileHandle.standardOutput.write(Data(outcome.out.utf8)) }
if !outcome.err.isEmpty { FileHandle.standardError.write(Data(outcome.err.utf8)) }
// 写入成功：叫醒 App 立刻跑一轮（否则等 2 秒心跳）。通知名带 home 哈希，与本进程的 TFA_HOME 一致。
if outcome.changed { notify_post(SuperagentPaths.changedNotification) }
exit(outcome.code)
