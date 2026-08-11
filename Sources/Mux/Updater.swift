import AppKit
import SwiftUI

/// Manual "check for updates" against GitHub Releases: one click compares the latest release tag with
/// the running bundle's version; a second click downloads the notarized `TFA.app.zip` asset, verifies
/// its code signature + bundle id, swaps the app bundle in place, and relaunches. No background
/// polling — the network is touched only when the user asks (设置 → 更新).
///
/// Relaunching is cheap by design: every terminal lives in the tmux server, so quitting for the
/// update loses nothing — the new version re-attaches to the same sessions.
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case downloading
        case installing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// The notarized zip asset of the `.available` release.
    @ObservationIgnored private var assetURL: URL?

    static let repo = "wstart/TFA"
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // MARK: - Check

    func check() {
        switch phase {
        case .checking, .downloading, .installing: return // already busy
        default: break
        }
        phase = .checking
        Task { await doCheck() }
    }

    private struct Release: Decodable {
        var tag_name: String
        var assets: [Asset]
        struct Asset: Decodable { var name: String; var browser_download_url: String }
    }

    private func doCheck() async {
        do {
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("TFA", forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw Err("GitHub 返回 \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            let rel = try JSONDecoder().decode(Release.self, from: data)
            let latest = rel.tag_name.hasPrefix("v") ? String(rel.tag_name.dropFirst()) : rel.tag_name
            guard Self.isNewer(latest, than: Self.currentVersion) else { phase = .upToDate; return }
            // The release asset name is fixed by the发布流程 (CLAUDE.md): always TFA.app.zip.
            guard let zip = rel.assets.first(where: { $0.name == "TFA.app.zip" }),
                  let url = URL(string: zip.browser_download_url) else {
                throw Err("最新 release(v\(latest))没有 TFA.app.zip 资产")
            }
            assetURL = url
            phase = .available(version: latest)
        } catch {
            phase = .failed("检查失败:\((error as? Err)?.message ?? error.localizedDescription)")
        }
    }

    /// Numeric component-wise semver-ish compare ("0.16.2" vs "0.9.0" → true). Pure → testable.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Install

    func install() {
        guard case .available = phase, let assetURL else { return }
        let appURL = Bundle.main.bundleURL
        guard appURL.pathExtension == "app" else {
            phase = .failed("当前不是从 .app 运行(开发模式),请用发布包更新")
            return
        }
        phase = .downloading
        Task { await doInstall(zip: assetURL, appURL: appURL) }
    }

    private func doInstall(zip: URL, appURL: URL) async {
        do {
            let (tmpZip, _) = try await URLSession.shared.download(from: zip)
            phase = .installing
            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("tfa-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try await run("/usr/bin/ditto", ["-x", "-k", tmpZip.path, work.path])
            let newApp = work.appendingPathComponent("TFA.app")
            guard FileManager.default.fileExists(atPath: newApp.path) else { throw Err("解压后没有 TFA.app") }

            // Verify BEFORE touching the installed app: intact signature + the same bundle id, so a
            // corrupted download or a wrong asset can never replace a working install.
            try await run("/usr/bin/codesign", ["--verify", "--strict", newApp.path])
            guard Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
                throw Err("下载的 App bundle id 不匹配")
            }

            // Swap: renaming a RUNNING app is fine on APFS (the process keeps its file handles).
            // Old bundle is kept in the temp dir as an automatic rollback if the move-in fails.
            let backup = work.appendingPathComponent("TFA-old.app")
            try FileManager.default.moveItem(at: appURL, to: backup)
            do {
                try FileManager.default.moveItem(at: newApp, to: appURL)
            } catch {
                try? FileManager.default.moveItem(at: backup, to: appURL) // roll back
                throw error
            }

            // Relaunch: a detached child outlives us and reopens the (now new) bundle. terminate(nil)
            // is the graceful path — session snapshot runs and tmux children are recycled as on ⌘Q.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 1; /usr/bin/open '\(appURL.path.replacingOccurrences(of: "'", with: "'\\''"))'"]
            try p.run()
            NSApp.terminate(nil)
        } catch {
            phase = .failed("更新失败:\((error as? Err)?.message ?? error.localizedDescription)")
        }
    }

    /// Run a tool to completion, throwing on a non-zero exit.
    private func run(_ tool: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.terminationHandler = { proc in
                if proc.terminationStatus == 0 { cont.resume() }
                else { cont.resume(throwing: Err("\((tool as NSString).lastPathComponent) 失败(退出码 \(proc.terminationStatus))")) }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    private struct Err: Error { let message: String; init(_ m: String) { message = m } }
}
