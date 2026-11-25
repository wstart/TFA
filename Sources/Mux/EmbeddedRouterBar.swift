import SwiftUI
import SuperagentCore

/// 「我的工作」顶部内嵌主管栏：
/// 1. 直接对主管说一句话自动拆解任务进清单，或粘贴线上组织接入口令秒级接入；
/// 2. 实时展示主管终端状态与最新进展动态，不离开清单即可掌握进展；
/// 3. 常驻「打开主管终端 / 启动主管终端」与「重启主管」入口，随时一键切到终端接手。
struct EmbeddedRouterBar: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onManualNewTask: (() -> Void)? = nil

    @State private var prompt: String = ""
    @State private var feedback: Feedback?
    @State private var clearFeedbackTask: Task<Void, Never>?
    @FocusState private var inputFocused: Bool

    init(onManualNewTask: (() -> Void)? = nil) {
        self.onManualNewTask = onManualNewTask
    }

    private struct Feedback: Equatable {
        let id = UUID()
        let ok: Bool
        let message: String
    }

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        let sa = appModel.superagent
        VStack(alignment: .leading, spacing: 10) {
            inputRow(sa)
            Hairline()
            statusRow(sa)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .stroke(inputFocused ? Theme.brand : Theme.border, lineWidth: 1)
                .animation(Theme.Motion.value(Theme.Motion.micro, reduceMotion: reduceMotion), value: inputFocused)
        )
        .onDisappear {
            clearFeedbackTask?.cancel()
            clearFeedbackTask = nil
        }
        .onChange(of: appModel.routerInputFocusPulse) { _, _ in
            inputFocused = true
        }
    }

    // MARK: - 第 1 行：一句话指令输入行

    private func inputRow(_ sa: SuperagentRuntime) -> some View {
        let showSubmit = !trimmedPrompt.isEmpty || sa.sendingToRouter
        let isOrgJoin = OrgJoinSpec.parse(trimmedPrompt) != nil
        let submitTitle = sa.sendingToRouter
            ? (isOrgJoin ? "接入中…" : "发送中…")
            : (isOrgJoin ? "立即接入组织" : "交给主管")
        return HStack(spacing: Theme.Space.md) {
            Group {
                if sa.sendingToRouter || sa.routerBusy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.75)
                } else {
                    Image(systemName: isOrgJoin ? "globe" : "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.brand)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 16, height: 16)
            .animation(Theme.Motion.value(Theme.Motion.snap, reduceMotion: reduceMotion), value: isOrgJoin)
            .accessibilityHidden(true)

            TextField("对主管说一句（自动拆解任务进清单，或直接粘贴线上组织接入口令）…", text: $prompt)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.textPrimary)
                .focused($inputFocused)
                .disabled(sa.sendingToRouter)
                .onSubmit { submit() }
                .accessibilityLabel("对主管发话或粘贴线上组织接入口令")

            if showSubmit {
                Button {
                    submit()
                } label: {
                    Text(submitTitle)
                        .contentTransition(.opacity)
                        .frame(minWidth: isOrgJoin ? 78 : 56)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .frame(minWidth: isOrgJoin ? 96 : 74)
                .disabled(sa.sendingToRouter || trimmedPrompt.isEmpty)
                .transition(Theme.Motion.reveal(edge: .trailing, reduceMotion: reduceMotion))
            }
        }
        .frame(minHeight: 24)
        .animation(Theme.Motion.value(Theme.Motion.snap, reduceMotion: reduceMotion), value: showSubmit)
        .animation(Theme.Motion.value(Theme.Motion.snap, reduceMotion: reduceMotion), value: isOrgJoin)
    }

    // MARK: - 第 2 行：主管实时动态条 + 快捷切终端入口

    private func statusRow(_ sa: SuperagentRuntime) -> some View {
        let dotColor = statusDotColor(sa)
        let dotState = statusDotKey(sa)
        let messageKey = feedback.map { "fb:\($0.id.uuidString)" } ?? "act:\(sa.routerActivityLine)"
        return HStack(spacing: Theme.Space.sm) {
            Circle()
                .fill(dotColor)
                .frame(width: 6.5, height: 6.5)
                .animation(Theme.Motion.value(Theme.Motion.snap, reduceMotion: reduceMotion), value: dotState)
                .accessibilityHidden(true)

            Group {
                if let fb = feedback {
                    HStack(spacing: 4) {
                        Text(fb.message)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(fb.ok ? Theme.Status.positive : Theme.Status.error)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(fb.message)

                        Button {
                            dismissFeedback()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PaperPressButtonStyle(hoverWash: true, cornerRadius: 4))
                        .help("关闭提示")
                        .accessibilityLabel("关闭提示")
                    }
                } else {
                    Text(sa.routerActivityLine)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(sa.routerActivityLine)
                }
            }
            .id(messageKey)
            .transition(.opacity)
            .animation(Theme.Motion.value(Theme.Motion.echo, reduceMotion: reduceMotion), value: messageKey)

            Spacer(minLength: 8)

            HStack(spacing: Theme.Space.sm) {
                if let onManualNewTask {
                    Button {
                        onManualNewTask()
                    } label: {
                        Text("手动建单")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 6)
                            .frame(height: 24)
                            .contentShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(PaperPressButtonStyle(hoverWash: true, cornerRadius: 5))
                    .help("手动填写标题与清单项新建任务")
                }

                if sa.routerSession != nil {
                    Button {
                        appModel.restartRouter()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .medium))
                            Text("重启主管")
                                .font(.system(size: 11.5))
                        }
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6)
                        .frame(height: 24)
                        .contentShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(PaperPressButtonStyle(hoverWash: true, cornerRadius: 5))
                    .disabled(sa.sendingToRouter)
                    .help("重启主管终端会话")
                }

                Button {
                    appModel.openRouter()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "terminal")
                            .font(.system(size: 10, weight: .semibold))
                        Text(sa.routerSession != nil ? "打开主管终端" : "启动主管终端")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(PaperPressButtonStyle(hoverWash: true, cornerRadius: 6))
                .help(sa.routerSession != nil ? "切换到顶部「主管」实时终端查看完整上下文或直接接手对话" : "启动并切换到顶部「主管」实时终端")
            }
            .fixedSize()
        }
        .frame(minHeight: 24)
    }

    private func statusDotKey(_ sa: SuperagentRuntime) -> Int {
        if let fb = feedback { return fb.ok ? 10 : 11 }
        if sa.routerBusy || sa.sendingToRouter { return 2 }
        if sa.routerSession != nil { return 1 }
        return 0
    }

    private func statusDotColor(_ sa: SuperagentRuntime) -> Color {
        if let fb = feedback {
            return fb.ok ? Theme.Status.positive : Theme.Status.error
        }
        if sa.routerBusy || sa.sendingToRouter {
            return Theme.Status.attention
        }
        if sa.routerSession != nil {
            return Theme.Status.positive
        }
        return Theme.Colors.pewter
    }

    // MARK: - 交互逻辑

    private func submit() {
        let sa = appModel.superagent
        let text = trimmedPrompt
        guard !text.isEmpty, !sa.sendingToRouter else { return }

        dismissFeedback()
        let dir = appModel.routerDirectory
        Task { @MainActor in
            let result = await sa.sendToEmbeddedRouter(text, routerDir: dir)
            if result.ok {
                prompt = ""
            }
            showFeedback(ok: result.ok, message: result.message)
        }
    }

    private func showFeedback(ok: Bool, message: String) {
        clearFeedbackTask?.cancel()
        let entry = Feedback(ok: ok, message: message)
        feedback = entry
        clearFeedbackTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, feedback?.id == entry.id else { return }
            feedback = nil
            clearFeedbackTask = nil
        }
    }

    private func dismissFeedback() {
        clearFeedbackTask?.cancel()
        clearFeedbackTask = nil
        feedback = nil
    }
}

/// 「我的工作 · 主管」标签内嵌的真实可交互 SwiftTerm 主管实时终端视图。
struct EmbeddedRouterTerminalView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init() {}

    var body: some View {
        let sa = appModel.superagent
        let conn = appModel.routerConnection
        let healthyConn: ConnectionSession? = {
            guard let conn, !conn.isEnded, conn.connectError == nil else { return nil }
            return conn
        }()
        let disconnected = conn?.isEnded == true || conn?.connectError != nil
        VStack(spacing: 0) {
            controlBar(sa: sa, conn: healthyConn)
            Hairline()
            Group {
                if let healthyConn {
                    TerminalContent(conn: healthyConn)
                } else {
                    connectingPlaceholder(sa: sa, disconnected: disconnected)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if sa.setupError == nil {
                appModel.ensureRouterReady()
            } else {
                appModel.syncEmbeddedRouterViewing()
            }
        }
        .onChange(of: appModel.routerConnection?.id) { _, _ in
            appModel.syncEmbeddedRouterViewing()
        }
        .onChange(of: sa.routerSession) { _, session in
            if session == nil, sa.setupError == nil {
                appModel.scheduleRouterAutoHeal()
            }
        }
        .onChange(of: conn?.isEnded) { _, ended in
            if ended == true, sa.setupError == nil {
                appModel.scheduleRouterAutoHeal()
            }
        }
        .onChange(of: conn?.connectError) { _, err in
            if err != nil, sa.setupError == nil {
                appModel.scheduleRouterAutoHeal()
            }
        }
    }

    private func controlBar(sa: SuperagentRuntime, conn: ConnectionSession?) -> some View {
        let isBusy = sa.routerBusy || sa.sendingToRouter
        let dotColor: Color = isBusy
            ? Theme.Status.attention
            : (conn != nil ? Theme.Status.positive : Theme.Colors.pewter)
        let dir = appModel.routerDirectory
        let subtitle = isBusy ? sa.routerActivityLine : Self.abbreviatedPath(dir)
        let subtitleHelp = isBusy ? sa.routerActivityLine : dir

        return HStack(spacing: Theme.Space.md) {
            HStack(spacing: Theme.Space.sm) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                    .animation(Theme.Motion.value(Theme.Motion.snap, reduceMotion: reduceMotion), value: isBusy ? 2 : (conn != nil ? 1 : 0))
                    .accessibilityHidden(true)

                Text("主管 · \(sa.settings.codingAgent.label)")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize()

                Text("·")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)

                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(isBusy ? Theme.textSecondary : Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(isBusy ? .tail : .middle)
                    .help(subtitleHelp)
            }
            .frame(minWidth: 0)

            Spacer(minLength: 12)

            HStack(spacing: Theme.Space.sm) {
                Button {
                    appModel.showHistoryViewer()
                } label: {
                    Label("查看历史", systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 11.5))
                        .padding(.horizontal, 6)
                        .frame(height: 24)
                        .contentShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(PaperPressButtonStyle(hoverWash: conn?.primaryPane != nil, cornerRadius: 5))
                .foregroundStyle(conn?.primaryPane != nil ? Theme.textSecondary : Theme.textTertiary)
                .disabled(conn?.primaryPane == nil)
                .help("查看主管终端完整滚屏历史（⌘⇧H）")

                Button {
                    appModel.restartRouter()
                } label: {
                    Label("重启主管", systemImage: "arrow.clockwise")
                        .font(.system(size: 11.5))
                        .padding(.horizontal, 6)
                        .frame(height: 24)
                        .contentShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(PaperPressButtonStyle(hoverWash: !sa.sendingToRouter, cornerRadius: 5))
                .foregroundStyle(Theme.textSecondary)
                .disabled(sa.sendingToRouter)
                .help("重启主管实时终端会话")

                Button {
                    appModel.openWorklistSettings(.router)
                } label: {
                    Label("主管设置", systemImage: "slider.horizontal.3")
                        .font(.system(size: 11.5))
                        .padding(.horizontal, 6)
                        .frame(height: 24)
                        .contentShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(PaperPressButtonStyle(hoverWash: true, cornerRadius: 5))
                .foregroundStyle(Theme.textSecondary)
                .help("打开主管与 Agent 设置")
            }
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: 37)
        .background(Theme.surface)
    }

    private func connectingPlaceholder(sa: SuperagentRuntime, disconnected: Bool) -> some View {
        VStack(spacing: Theme.Space.lg) {
            ProgressView()
                .controlSize(.regular)
            Text(disconnected ? "检测到主管连接中断，正在自动恢复…" : "正在连接主管实时终端…")
                .font(Theme.Font.headerTitle)
                .foregroundStyle(Theme.textPrimary)
            Text(sa.routerActivityLine)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button {
                appModel.ensureRouterReady()
            } label: {
                Label("立即重连主管", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }

    private static func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
