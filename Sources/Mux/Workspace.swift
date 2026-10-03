import SwiftUI
import AppKit
import Observation

struct ProjectWorkspace: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var path: String
    var terminalIDs: Set<String> = []
}

@MainActor @Observable
final class WorkspaceStore {
    static let shared = WorkspaceStore()
    var projects: [ProjectWorkspace] = []
    var selectedID: UUID? { didSet { UserDefaults.standard.set(selectedID?.uuidString, forKey: "workspace.selected") } }
    var selected: ProjectWorkspace? { projects.first { $0.id == selectedID } }
    var taskProjects: [String: String] = UserDefaults.standard.dictionary(forKey: "workspace.tasks") as? [String: String] ?? [:]
    func associateTask(_ id: UUID) {
        guard let selectedID else { return }
        taskProjects[id.uuidString] = selectedID.uuidString
        UserDefaults.standard.set(taskProjects, forKey: "workspace.tasks")
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: "workspace.projects"),
           let saved = try? JSONDecoder().decode([ProjectWorkspace].self, from: data) { projects = saved }
        selectedID = UserDefaults.standard.string(forKey: "workspace.selected").flatMap(UUID.init(uuidString:))
    }
    func persist() {
        do { UserDefaults.standard.set(try JSONEncoder().encode(projects), forKey: "workspace.projects") }
        catch { EditorSafety.report(error) }
    }
    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "添加项目"
        guard panel.runModal() == .OK, let url = panel.url?.resolvingSymlinksInPath() else { return }
        if let existing = projects.first(where: { $0.path == url.path }) { selectedID = existing.id; return }
        let project = ProjectWorkspace(name: url.lastPathComponent, path: url.path)
        projects.append(project); selectedID = project.id; persist()
    }
    func associate(_ stableID: String) {
        guard let index = projects.firstIndex(where: { $0.id == selectedID }) else { return }
        projects[index].terminalIDs.insert(stableID); persist()
    }
    func includes(_ connection: ConnectionSession) -> Bool {
        guard let project = selected else { return true }
        if project.terminalIDs.contains(connection.stableID) { return true }
        guard connection.host == nil, let path = connection.currentPath else { return false }
        return path == project.path || path.hasPrefix(project.path + "/")
    }
}

struct WorkspaceControls: View {
    @Environment(AppModel.self) private var model
    @State private var store = WorkspaceStore.shared
    @State private var showProjects = false
    @State private var showAttention = false
    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Picker("项目", selection: $store.selectedID) {
                    Text("全部项目").tag(nil as UUID?)
                    ForEach(store.projects) { Text($0.name).tag(Optional($0.id)) }
                }.labelsHidden()
                Button { showProjects = true } label: { Image(systemName: "folder.badge.gearshape") }
                    .buttonStyle(.borderless).help("管理项目工作区")
            }
            TimelineView(.periodic(from: .now, by: 2)) { _ in
            Button { showAttention = true } label: {
                Label("待处理 \(model.connections.filter { $0.needsAttention || $0.connectError != nil }.count + model.taskBoard.board.tasks.filter { $0.status != .done && ($0.status == .blocked || $0.comments.last?.kind == "question" || model.dispatch.pendingDispatch[$0.id] != nil) }.count)", systemImage: "tray")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.borderless).help("查看需要回复、连接失败和等待派发的任务")
            }
        }.padding(8)
        .onChange(of: store.selectedID) {
            guard !model.tasksSelected && !model.skillsSelected && !model.claudeMdSelected else { return }
            if let connection = model.connections.first(where: { store.includes($0) }) {
                model.goToTerminal(connection.id)
            } else { model.selectedConnectionID = nil }
        }
        .sheet(isPresented: $showProjects) { WorkspaceManager().environment(model) }
        .sheet(isPresented: $showAttention) { AttentionCenter().environment(model) }
    }
}

struct WorkspaceManager: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var store = WorkspaceStore.shared
    @State private var rules: ProjectWorkspace?
    @State private var recovery: ConnectionSession?
    @State private var sessionID = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("项目工作区").font(.headline)
                Spacer()
                Button("添加文件夹") { store.addFolder() }
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("选择项目后，侧栏与任务看板按项目过滤；新会话默认使用项目目录。")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(store.projects) { project in
                    HStack {
                        VStack(alignment: .leading) { Text(project.name); Text(project.path).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("切换") { store.selectedID = project.id }
                        Button("项目规则") { rules = project }
                        Button("移除") { store.projects.removeAll { $0.id == project.id }; if store.selectedID == project.id { store.selectedID = nil }; store.persist() }
                            .help("只移除项目入口，保留文件与终端")
                    }
                }
                Section("终端关联与恢复") {
                    ForEach(model.connections) { connection in
                        HStack {
                            Text(connection.title)
                            Spacer()
                            Button("关联当前项目") { store.associate(connection.stableID) }.disabled(store.selected == nil)
                            Button("Codex 会话 ID") {
                                sessionID = UserDefaults.standard.string(forKey: "codexSession." + connection.stableID) ?? ""
                                recovery = connection
                            }
                        }
                    }
                }
            }
            Text("恢复时优先使用绑定的 Codex 会话 UUID；未绑定时打开 Codex 会话选择器。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 720, height: 500)
        .sheet(item: $rules) { project in
            VStack {
                Text(project.name + " · 项目规则").font(.headline).padding()
                ClaudeMdView(projectDirectory: URL(fileURLWithPath: project.path))
                Button("完成") { rules = nil }.padding()
            }.frame(width: 780, height: 560)
        }
        .alert("绑定 Codex 会话", isPresented: Binding(get: { recovery != nil }, set: { if !$0 { recovery = nil } })) {
            TextField("会话 UUID（留空取消绑定）", text: $sessionID)
            Button("保存") {
                if let connection = recovery {
                    UserDefaults.standard.set(sessionID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "codexSession." + connection.stableID)
                }
                recovery = nil
            }.disabled(!sessionID.isEmpty && UUID(uuidString: sessionID.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)
            Button("取消", role: .cancel) { recovery = nil }
        } message: { Text("填入要恢复的准确会话 UUID，不会自动使用同目录最近的一段对话。") }
    }
}

struct AttentionCenter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var reply = ""
    @State private var replying: BoardTask?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("待处理中心 · 全部项目").font(.headline); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
                List {
                    Section("需要关注的终端") {
                        let terminals = model.connections.filter { $0.needsAttention || $0.connectError != nil }
                        if terminals.isEmpty { Text("暂无终端需要处理").foregroundStyle(.secondary) }
                        ForEach(terminals) { connection in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(connection.title)
                                    Text(connection.connectError ?? connection.attentionMessage ?? "Agent 请求关注").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("前往终端") { model.goToTerminal(connection.id); dismiss() }
                            }
                        }
                    }
                    Section("待回复 / 受阻 / 等待派发") {
                        let tasks = model.taskBoard.board.tasks.filter {
                            $0.status != .done && ($0.status == .blocked || $0.comments.last?.kind == "question" || model.dispatch.pendingDispatch[$0.id] != nil)
                        }
                        if tasks.isEmpty { Text("暂无待处理任务").foregroundStyle(.secondary) }
                        ForEach(tasks) { task in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(task.title)
                                    Text(model.dispatch.pendingDispatch[task.id] != nil ? "等待终端连接、空闲或启动 Agent" : task.comments.last?.text ?? "任务受阻")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                }
                                Spacer()
                                Button("回复") { reply = ""; replying = task }
                            }
                        }
                    }
                }
            }.padding(20)
        }.frame(width: 720, height: 500)
        .alert("回复任务", isPresented: Binding(get: { replying != nil }, set: { if !$0 { replying = nil } })) {
            TextField("回复内容", text: $reply)
            Button("发送") { if let task = replying { model.pushReply(task.id, text: reply) }; replying = nil }
                .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("取消", role: .cancel) { replying = nil }
        } message: { Text("回复将记入任务记录，并按现有派发队列发送到关联终端。") }
    }
}
