import SwiftUI
import SuperagentCore

// 清单的设置子页（设计评审 2026-11-08，2A）：和任务卡同级、带返回的一页；顶部一行分段目录（主管 · 组织 · 工作流 ·
// 角色 · 规则 · 定时 · 其它 · 记录），一次只显示一组。各张卡还是 `SuperagentPanel.swift` 里的那几张，样式和行为不变；
// 页头的副标题是这一段的状态，不是宣言。

/// `appModel.worklistSelected && worklistShowsSettings` 时 RootView 显示它而不是清单。
/// 工具栏「主管」从「主管」段进来，清单页头的齿轮回到上次看的那段；「‹ 我的清单」、Esc、⌘[ 都返回清单。
struct WorklistSettingsPage: View {
    @Environment(AppModel.self) private var appModel
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = appModel
        let sa = appModel.superagent
        let segment = appModel.worklistSettingsSegment
        VStack(spacing: 0) {
            ToolHeaderBar(icon: "gearshape", title: "设置",
                          subtitle: WorklistSettingsText.subtitle(segment, WorklistSettingsText.Facts(sa)), leading: {
                Button {
                    back()
                } label: {
                    Label("我的清单", systemImage: "chevron.left")
                        .font(Theme.Font.headerTitle)
                        .foregroundStyle(Theme.textSecondary)
                }
                .help("回到我的清单")
                .accessibilityLabel("返回我的清单")
                .keyboardShortcut("[", modifiers: .command)
            })
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    if let e = sa.setupError { Banner(text: e) }
                    if let e = sa.actionError { Banner(text: e) { sa.actionError = nil } }
                    SegmentedChoice(selection: $model.worklistSettingsSegment,
                                    options: WorklistSettingsSegment.allCases.map { (value: $0, label: $0.rawValue) })
                        .help("← → 切换")
                        .accessibilityLabel("设置的分段")
                    content(segment)
                }
                .padding(Theme.Space.xxl)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.canvas)
        // 整页可聚焦，← → 和 Esc 才有地方落。`openWorklist` 会在下一轮把第一响应者清空（`leaveTerminals`），
        // 所以晚一拍再要焦点。
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onMoveCommand { direction in
            switch direction {
            case .left: appModel.worklistSettingsSegment = segment.stepped(by: -1)
            case .right: appModel.worklistSettingsSegment = segment.stepped(by: 1)
            default: break
            }
        }
        .onExitCommand { back() }
    }

    @ViewBuilder private func content(_ segment: WorklistSettingsSegment) -> some View {
        switch segment {
        case .router:
            RouterCard()
            DirectTicketsSection()
        case .org:
            OrgCard()
        case .workflow:
            WorkflowsCard()
        case .roles:
            RolesCard()
        case .rules:
            RulesCard()
        case .schedules:
            SchedulesCard()
        case .other:
            SettingsCard()
        case .records:
            DecisionLog()
        }
    }

    private func back() {
        appModel.worklistShowsSettings = false
    }
}

extension WorklistSettingsSegment {
    /// ← → 切段：到头停住，不绕回（同系统分段控件）。
    func stepped(by delta: Int) -> WorklistSettingsSegment {
        let all = Self.allCases
        guard let i = all.firstIndex(of: self) else { return self }
        return all[min(max(i + delta, 0), all.count - 1)]
    }
}

/// 设置页页头的一行：当前段的状态（纯函数，可测）。
enum WorklistSettingsText {
    struct Facts {
        var routerRunning = false
        /// 不属于任务的需要你工单（任务里的在清单页计）。
        var ticketsNeedingYou = 0
        var rules = 0
        var rulesEnabled = 0
        var mode: AcceptMode = .observe
        var schedules = 0
        var schedulesEnabled = 0
        var workflows = 0
        var builtinWorkflows = 0
        var roles = 0
        var standingRoles = 0
        var orgStatus = "未注册"
        var orgPending = 0
        var settings = Settings()
        var decisions = 0

        init() {}

        @MainActor init(_ sa: SuperagentRuntime) {
            routerRunning = sa.routerSession != nil
            ticketsNeedingYou = sa.needsYouOutsideTasks.count
            rules = sa.rules.count
            rulesEnabled = sa.rules.filter(\.enabled).count
            mode = sa.mode
            schedules = sa.schedules.count
            schedulesEnabled = sa.schedules.filter(\.enabled).count
            workflows = sa.workflows.count
            builtinWorkflows = sa.workflows.filter(\.isBuiltin).count
            roles = sa.roles.count
            standingRoles = sa.roles.filter(\.standing).count
            orgStatus = sa.org.statusText
            orgPending = sa.org.pendingTotal
            settings = sa.settings
            decisions = sa.decisions.count
        }
    }

    static func subtitle(_ segment: WorklistSettingsSegment, _ f: Facts) -> String {
        switch segment {
        case .router:
            var parts = [f.routerRunning ? "主管 运行中" : "主管 未启动"]
            if f.ticketsNeedingYou > 0 { parts.append("\(f.ticketsNeedingYou) 个工单需要你") }
            parts.append(f.rules == 0 ? "没有规则" : "\(f.rules) 条规则")
            parts.append(f.schedules == 0 ? "没有定时" : "\(f.schedules) 个定时")
            return parts.joined(separator: " · ")
        case .org:
            return "组织 \(f.orgStatus)" + (f.orgPending > 0 ? " · 待上传 \(f.orgPending) 条" : "")
        case .workflow:
            return "\(f.workflows) 个模板 · 内置 \(f.builtinWorkflows) 个"
        case .roles:
            return "\(f.roles) 个角色 · 常驻 \(f.standingRoles) 个"
        case .rules:
            let head = "接单模式 \(f.mode.label)"
            return f.rules == 0 ? head + " · 没有规则" : head + " · \(f.rules) 条规则 · 启用 \(f.rulesEnabled) 条"
        case .schedules:
            return f.schedules == 0 ? "没有定时任务" : "\(f.schedules) 个定时任务 · 启用 \(f.schedulesEnabled) 个"
        case .other:
            let s = f.settings
            let agentSuffix = s.codingAgent == .claude ? "" : " · \(s.codingAgent.label)"
            return "并发 \(s.slots) · worktree \(s.worktree ? "开" : "关") · 看门狗 \(s.watchdogEnabled ? "开" : "关")"
                + " · \(s.modelBackend.label) · \(s.modelName)" + agentSuffix
        case .records:
            return f.decisions == 0 ? "还没有决定记录" : "\(f.decisions) 条决定记录"
        }
    }
}
