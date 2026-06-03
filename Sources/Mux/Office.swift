import SwiftUI
import AppKit
import TmuxKit

/// The「办公室」visualization (pixel art from github.com/pixel-agents-hq/pixel-agents, MIT — see
/// Resources/office/ATTRIBUTION.md). Each TFA group is ONE room: left = 办公区 (sessions producing
/// output sit at a desk facing a glowing PC, typing), right = 休息区 (idle sessions relax on the
/// sofa or wander around). Characters have real positions and a tiny game loop: when a session
/// stops/starts output the character WALKS between the two areas (no teleport); idle ones roam.
/// Activity is detected for EVERY session via tmux `#{window_activity}`. Working characters show
/// their latest output line + a work-duration bar. Drag a character onto another group to regroup.
/// Respects the system "Reduce Motion" setting (static placement, no walking/looping animation).

// MARK: - Assets

@MainActor
final class OfficeAssets {
    static let shared = OfficeAssets()
    static let scale: CGFloat = 3

    private(set) var charFrames: [[[NSImage]]] = []   // [char][row 0=down·1=up·2=right][frame 0…6]
    private(set) var furniture: [String: NSImage] = [:]
    private(set) var floorTile: NSImage?

    private init() {
        if let urls = Bundle.main.urls(forResourcesWithExtension: "png", subdirectory: "office/furniture") {
            for url in urls where NSImage(contentsOf: url) != nil {
                furniture[url.deletingPathExtension().lastPathComponent] = NSImage(contentsOf: url)
            }
        }
        if let floor = Self.load("floor_0", in: "floors") ?? Self.load("floor_3", in: "floors") {
            floorTile = Self.scaled(floor, by: Int(Self.scale))
        }
        for i in 0..<6 {
            guard let sheet = Self.load("char_\(i)", in: "characters"),
                  let cg = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            var rows: [[NSImage]] = []
            for row in 0..<3 where (row * 32 + 32) <= cg.height {
                var frames: [NSImage] = []
                for f in 0..<7 where (f * 16 + 16) <= cg.width {
                    if let frame = cg.cropping(to: CGRect(x: f * 16, y: row * 32, width: 16, height: 32)) {
                        frames.append(NSImage(cgImage: frame, size: NSSize(width: 16, height: 32)))
                    }
                }
                rows.append(frames)
            }
            if !rows.isEmpty { charFrames.append(rows) }
        }
    }

    private static func load(_ name: String, in sub: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "office/\(sub)")
        else { return nil }
        return NSImage(contentsOf: url)
    }

    private static func scaled(_ img: NSImage, by factor: Int) -> NSImage {
        let size = NSSize(width: img.size.width * CGFloat(factor), height: img.size.height * CGFloat(factor))
        let out = NSImage(size: size)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        img.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }

    func frame(char: Int, row: Int, index: Int) -> NSImage? {
        guard !charFrames.isEmpty else { return nil }
        let c = charFrames[char % charFrames.count]
        guard !c.isEmpty else { return nil }
        let r = c[min(row, c.count - 1)]
        return r.isEmpty ? nil : r[min(index, r.count - 1)]
    }
}

enum Facing: Equatable { case down, up, right, left
    var row: Int { self == .up ? 1 : (self == .down ? 0 : 2) }
    var flip: Bool { self == .left }
}

enum SeatStatus: Equatable { case working, resting, connecting, reconnecting, failed }

// MARK: - Activity monitor (covers ALL sessions, attached or not)

@MainActor
@Observable
final class OfficeActivityMonitor {
    private(set) var activity: [String: Int] = [:]
    private(set) var lastLine: [String: String] = [:]
    private(set) var workingSince: [String: Int] = [:]
    private(set) var nowEpoch: Int = 0
    static let activeWithin = 5

    @ObservationIgnored private var task: Task<Void, Never>?
    /// Cache of captured output lines keyed by the activity epoch — avoids re-running capture-pane
    /// for a session whose window_activity hasn't changed since the last poll.
    @ObservationIgnored private var lineCache: [String: (epoch: Int, line: String)] = [:]

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor in
            while !Task.isCancelled {
                let within = Self.activeWithin
                let cache = self.lineCache
                let snap = await Task.detached(priority: .utility) { () -> (act: [String: Int], lines: [String: String]) in
                    let act = TmuxServer.localWindowActivity()
                    let now = Int(Date().timeIntervalSince1970)
                    var lines: [String: String] = [:]
                    for (name, t) in act where now - t < within {
                        if let c = cache[name], c.epoch == t { lines[name] = c.line }        // reuse — no new output
                        else if let l = TmuxServer.lastOutputLine(session: name) { lines[name] = l }
                    }
                    return (act, lines)
                }.value
                let now = Int(Date().timeIntervalSince1970)
                let workingNames = Set(snap.act.filter { now - $0.value < within }.map { $0.key })
                var since = self.workingSince
                for n in workingNames where since[n] == nil { since[n] = now }
                for k in Array(since.keys) where !workingNames.contains(k) { since[k] = nil }
                var cacheNext: [String: (epoch: Int, line: String)] = [:]
                for (name, line) in snap.lines { if let t = snap.act[name] { cacheNext[name] = (t, line) } }
                self.lineCache = cacheNext
                self.activity = snap.act; self.lastLine = snap.lines; self.workingSince = since; self.nowEpoch = now
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }
    func stop() { task?.cancel(); task = nil }

    func isWorking(name: String) -> Bool { activity[name].map { nowEpoch - $0 < Self.activeWithin } ?? false }
    func line(_ name: String) -> String? { lastLine[name] }
    func workedSeconds(_ name: String) -> Int? { workingSince[name].map { max(0, nowEpoch - $0) } }
}

// MARK: - Stage (positions + walking game loop)

enum Placement: Equatable {
    case desk(CGPoint)      // working → sit at a desk, facing the screen (up), typing
    case sofa(CGPoint)      // resting → sit on the sofa, facing down
    case wander(CGRect)     // resting (overflow) → roam this rectangle freely
    case stand(CGPoint)     // connecting/failed → stand here (with a head badge)
    var isWander: Bool { if case .wander = self { return true }; return false }
}

@MainActor
@Observable
final class OfficeStage {
    /// Only the render-relevant fields are observed → views re-render ONLY when one of these changes.
    struct RenderMob: Equatable { var pos: CGPoint; var facing: Facing; var frame: Int; var moving: Bool }
    private(set) var render: [UUID: RenderMob] = [:]

    /// Full simulation state lives OUTSIDE Observation, so the 30fps loop's bookkeeping
    /// (clock/pause/target) never forces a view rebuild.
    private struct Sim {
        var pos: CGPoint; var target: CGPoint
        var facing: Facing = .down; var frame = 0; var moving = false
        var wander = false; var rect: CGRect = .zero; var zone = ""
        var clock = 0.0; var pause = 0.0
    }
    @ObservationIgnored private var sim: [UUID: Sim] = [:]
    @ObservationIgnored var reduceMotion = false
    @ObservationIgnored private var frozen: Set<UUID> = []
    @ObservationIgnored private var timer: Timer?

    func startLoop() {
        guard timer == nil, !reduceMotion else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(1.0 / 30.0) }
        }
    }
    func stopLoop() { timer?.invalidate(); timer = nil }
    func freeze(_ id: UUID, _ on: Bool) { if on { frozen.insert(id) } else { frozen.remove(id) } }

    func place(_ id: UUID, zone: String, _ p: Placement) {
        var m = sim[id] ?? Sim(pos: Self.anchor(p), target: Self.anchor(p), zone: zone)
        if m.zone != zone { m.pos = Self.anchor(p); m.zone = zone } // moved across groups → snap in
        switch p {
        case .desk(let pt), .sofa(let pt), .stand(let pt): m.target = pt; m.wander = false; m.rect = .zero
        case .wander(let r): m.wander = true; if m.rect != r { m.rect = r; if !r.contains(m.target) { m.target = m.pos } }
        }
        if reduceMotion { m.pos = p.isWander ? m.pos : m.target; m.moving = false }
        sim[id] = m
        publish(id, m)
    }

    /// Reapply 'static placement' on Reduce-Motion turning on, even mid-walk.
    func snapAll() {
        for (id, var m) in sim where !frozen.contains(id) {
            if !m.wander { m.pos = m.target }
            m.moving = false
            sim[id] = m; publish(id, m)
        }
    }

    /// Zone-scoped prune: a room only removes ITS OWN departed members — never another zone's.
    func prune(zone: String, active: Set<UUID>) {
        for (k, m) in sim where m.zone == zone && !active.contains(k) && !frozen.contains(k) {
            sim[k] = nil; render[k] = nil; frozen.remove(k)
        }
    }

    private func publish(_ id: UUID, _ m: Sim) {
        let r = RenderMob(pos: m.pos, facing: m.facing, frame: m.frame, moving: m.moving)
        if render[id] != r { render[id] = r } // only invalidate views on a real visual change
    }

    private func tick(_ dt: Double) {
        let speed: CGFloat = 75
        for (id, var m) in sim {
            if frozen.contains(id) { continue }
            if m.wander {
                let reached = hypot(m.target.x - m.pos.x, m.target.y - m.pos.y) < 4
                if reached {
                    m.pause -= dt
                    if m.pause <= 0, m.rect.width > 8 {
                        m.target = CGPoint(x: .random(in: m.rect.minX...m.rect.maxX),
                                           y: .random(in: m.rect.minY...m.rect.maxY))
                        m.pause = .random(in: 0.8...2.6)
                    }
                }
            }
            let dx = m.target.x - m.pos.x, dy = m.target.y - m.pos.y
            let dist = hypot(dx, dy)
            if dist > 2 {
                let stepLen = min(dist, speed * CGFloat(dt))
                m.pos.x += dx / dist * stepLen; m.pos.y += dy / dist * stepLen
                m.moving = true
                m.facing = abs(dx) > abs(dy) ? (dx >= 0 ? .right : .left) : (dy >= 0 ? .down : .up)
                m.clock += dt; m.frame = [0, 1, 2, 1][Int(m.clock * 6) % 4]
            } else {
                m.pos = m.target; m.moving = false
            }
            sim[id] = m
            publish(id, m) // no-op for a settled mob → no re-render when the office is idle
        }
    }

    static func anchor(_ p: Placement) -> CGPoint {
        switch p {
        case .desk(let pt), .sofa(let pt), .stand(let pt): return pt
        case .wander(let r): return CGPoint(x: r.midX, y: r.midY)
        }
    }
}

// MARK: - Zone drop-target frames (for drag-to-regroup)

private struct ZoneFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - View

struct OfficeView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedID: UUID?
    @State private var zoneFrames: [String: CGRect] = [:]
    @State private var draggingID: UUID?
    @State private var hoverZoneID: String?
    @State private var monitor = OfficeActivityMonitor()
    @State private var stage = OfficeStage()

    private static let space = "office"
    // Marvis palette: soft warm off-white page, white soft-shadow cards, muted text, one teal accent.
    static let pageBG = Color(red: 0.962, green: 0.958, blue: 0.95)
    private var seats: [ConnectionSession] { appModel.connections.filter { belongsToCurrentHost($0) } }

    var body: some View {
        VStack(spacing: 0) {
            if seats.isEmpty {
                ContentUnavailableView {
                    Label("办公室还没人", systemImage: "building.2")
                } description: {
                    Text("还没有会话。新建一个终端，就会有一个小人来上班。")
                } actions: {
                    Button { appModel.newTerminal() } label: { Label("新建终端", systemImage: "plus") }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let seatsNow = seats
                let grouped = bucketed(seatsNow)
                summaryStrip(seatsNow)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.lg) {
                        ForEach(appModel.currentGroups) { g in
                            zone(id: "group:\(g.id.uuidString)", title: g.name, members: grouped.byGroup[g.id] ?? [])
                        }
                        zone(id: "ungrouped", title: "未分组", members: grouped.ungrouped)
                    }
                    .padding(Theme.Space.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .coordinateSpace(name: Self.space)
                .onPreferenceChange(ZoneFramesKey.self) { zoneFrames = $0 }
            }
            Divider()
            bottomBar
        }
        .background(Self.pageBG) // Marvis-style: bright, airy, light
        .environment(\.colorScheme, .light) // keep the office light even when the app is in dark mode
        .onAppear { monitor.start(); stage.reduceMotion = reduceMotion; stage.startLoop() }
        .onDisappear { monitor.stop(); stage.stopLoop() }
        .onChange(of: reduceMotion) {
            stage.reduceMotion = reduceMotion
            if reduceMotion { stage.stopLoop(); stage.snapAll() } else { stage.startLoop() }
        }
    }

    /// Resolve group membership in a single pass (avoids O(groups² · sessions) per body).
    private func bucketed(_ seats: [ConnectionSession]) -> (byGroup: [UUID: [ConnectionSession]], ungrouped: [ConnectionSession]) {
        var byGroup: [UUID: [ConnectionSession]] = [:]
        var ungrouped: [ConnectionSession] = []
        for c in seats {
            if let gid = appModel.group(for: c)?.id { byGroup[gid, default: []].append(c) } else { ungrouped.append(c) }
        }
        return (byGroup, ungrouped)
    }

    // MARK: glance-level summary

    private func summaryStrip(_ seats: [ConnectionSession]) -> some View {
        let c = seats.reduce(into: (work: 0, rest: 0, issue: 0)) { acc, s in
            switch status(s) { case .working: acc.work += 1; case .resting: acc.rest += 1; default: acc.issue += 1 }
        }
        return HStack(spacing: Theme.Space.lg) {
            stat("在忙", c.work, Theme.brand, "desktopcomputer")
            stat("休息", c.rest, .secondary, "cup.and.saucer")
            if c.issue > 0 { stat("连接/异常", c.issue, .orange, "exclamationmark.triangle") }
            Spacer()
            Text("共 \(seats.count) 个会话").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
        }
        .padding(.horizontal, Theme.Space.lg).padding(.vertical, Theme.Space.sm)
    }

    private func stat(_ label: String, _ n: Int, _ tint: Color, _ symbol: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(tint)
            Text("\(label) ").font(.caption).foregroundStyle(.secondary) + Text("\(n)").font(.caption.bold()).foregroundStyle(tint)
        }.monospacedDigit()
    }

    // MARK: a group zone = one room

    @ViewBuilder private func zone(id: String, title: String, members: [ConnectionSession]) -> some View {
        let accent = Theme.brand
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "folder.fill").foregroundStyle(accent)
                Text(title).font(Theme.Font.headerTitle)
                Text("\(members.count)").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1).background(accent.opacity(0.15), in: Capsule())
                Spacer()
            }
            if members.isEmpty {
                Text("把小人拖到这里加入「\(title)」。").font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            } else {
                RoomView(zoneId: id, members: members, stage: stage, selectedID: $selectedID, draggingID: $draggingID,
                         status: status, colorIndex: colorIndex, number: seatNumber, lastLine: lastLine, worked: workedSeconds,
                         space: Self.space, onEnter: enter,
                         onClone: { appModel.cloneTerminal($0) },
                         onRestart: { appModel.restartSession($0) },
                         onClose: { appModel.detachTerminal($0); if selectedID == $0.id { selectedID = nil } },
                         onDragMove: { loc in hoverZoneID = zoneFrames.first(where: { $0.value.contains(loc) })?.key },
                         onDrop: { conn, loc in hoverZoneID = nil; handleDrop(conn, at: loc) })
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(floorBackground)
        .overlay {
            let targeted = draggingID != nil && hoverZoneID == id
            RoundedRectangle(cornerRadius: 18)
                .fill(targeted ? accent.opacity(0.08) : .clear)
                .overlay(RoundedRectangle(cornerRadius: 18)
                    .stroke(targeted ? accent.opacity(0.7) : (draggingID != nil ? accent.opacity(0.35) : Color.black.opacity(0.045)),
                            lineWidth: targeted ? 2.5 : (draggingID != nil ? 1.5 : 1)))
                .allowsHitTesting(false)
        }
        .background(GeometryReader { proxy in
            Color.clear.preference(key: ZoneFramesKey.self, value: [id: proxy.frame(in: .named(Self.space))])
        })
    }

    /// Marvis-style room card: white → faint-warm gradient, generous rounding, soft diffuse shadow.
    private var floorBackground: some View {
        RoundedRectangle(cornerRadius: 18)
            .fill(LinearGradient(colors: [Color.white, Color(red: 0.975, green: 0.972, blue: 0.965)],
                                 startPoint: .top, endPoint: .bottom))
            .shadow(color: .black.opacity(0.05), radius: 18, x: 0, y: 6)
    }

    // MARK: bottom control bar

    @ViewBuilder private var bottomBar: some View {
        HStack(spacing: Theme.Space.md) {
            if let conn = seats.first(where: { $0.id == selectedID }) {
                Circle().fill(statusColor(conn)).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(conn.title).font(Theme.Font.rowTitle).lineLimit(1)
                    Text(detail(conn)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if conn.connectError != nil { Button("重连") { conn.retry() } }
                Button("进入终端") { enter(conn) }
                Button("克隆") { appModel.cloneTerminal(conn) }
                Button("关闭") { appModel.detachTerminal(conn); selectedID = nil }
            } else {
                Text("单击选中 · 双击进入终端 · 拖到其它分组改归属").foregroundStyle(.secondary)
                Spacer()
            }
            Button { appModel.newTerminal() } label: { Label("新建", systemImage: "plus") }
        }
        .padding(Theme.Space.md).frame(maxWidth: .infinity)
        .background(Color.white)
    }

    // MARK: helpers

    private func status(_ conn: ConnectionSession) -> SeatStatus {
        if conn.connectError != nil { return .failed }
        if conn.isReconnecting { return .reconnecting }
        if conn.isAuthenticating { return .connecting }
        return working(conn) ? .working : .resting
    }
    private func working(_ conn: ConnectionSession) -> Bool {
        if conn.host == nil { return monitor.isWorking(name: conn.groupKey) || conn.outputPhase == .streaming }
        return conn.outputPhase == .streaming
    }
    private func lastLine(_ conn: ConnectionSession) -> String? { conn.host == nil ? monitor.line(conn.groupKey) : nil }
    private func workedSeconds(_ conn: ConnectionSession) -> Int? { conn.host == nil ? monitor.workedSeconds(conn.groupKey) : nil }

    private func handleDrop(_ conn: ConnectionSession, at loc: CGPoint) {
        guard let hit = zoneFrames.first(where: { $0.value.contains(loc) })?.key else { return }
        if hit == "ungrouped" { appModel.removeFromGroups(conn) }
        else if hit.hasPrefix("group:"), let uuid = UUID(uuidString: String(hit.dropFirst("group:".count))) {
            if appModel.group(for: conn)?.id != uuid { appModel.assign(conn, toGroup: uuid) }
        }
    }
    private func belongsToCurrentHost(_ conn: ConnectionSession) -> Bool {
        switch appModel.currentHost {
        case .local: return conn.host == nil
        case .ssh(let h, _): return conn.host == h
        }
    }
    private func colorIndex(_ conn: ConnectionSession) -> Int { abs(conn.groupKey.hashValue) % 6 }
    /// 1-based ordinal among the current host's sessions (matches sidebar order); nil beyond 9.
    private func seatNumber(_ conn: ConnectionSession) -> Int? {
        guard let i = seats.firstIndex(where: { $0.id == conn.id }), i < 9 else { return nil }
        return i + 1
    }
    private func detail(_ conn: ConnectionSession) -> String {
        var parts: [String] = []
        if let host = conn.host { parts.append(host) }
        if let path = conn.currentPath {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            parts.append(conn.host == nil ? path.replacingOccurrences(of: home, with: "~") : path)
        }
        if !conn.subtitle.isEmpty { parts.append(conn.subtitle) }
        return parts.isEmpty ? "—" : parts.joined(separator: "  ·  ")
    }
    private func statusColor(_ conn: ConnectionSession) -> Color {
        switch status(conn) {
        case .working: return Theme.brand
        case .failed: return .red
        case .reconnecting, .connecting: return .orange
        case .resting: return conn.hasUnseenOutput ? Theme.brand.opacity(0.6) : .secondary
        }
    }
    private func enter(_ conn: ConnectionSession) { appModel.selectedConnectionID = conn.id }
}

// MARK: - Room (one group: left office desks, right lounge, walking characters)

private struct RoomView: View {
    let zoneId: String
    let members: [ConnectionSession]
    let stage: OfficeStage
    @Binding var selectedID: UUID?
    @Binding var draggingID: UUID?
    let status: (ConnectionSession) -> SeatStatus
    let colorIndex: (ConnectionSession) -> Int
    let number: (ConnectionSession) -> Int?
    let lastLine: (ConnectionSession) -> String?
    let worked: (ConnectionSession) -> Int?
    let space: String
    let onEnter: (ConnectionSession) -> Void
    let onClone: (ConnectionSession) -> Void
    let onRestart: (ConnectionSession) -> Void
    let onClose: (ConnectionSession) -> Void
    let onDragMove: (CGPoint) -> Void
    let onDrop: (ConnectionSession, CGPoint) -> Void

    private var s: CGFloat { OfficeAssets.scale }
    private var deskW: CGFloat { 48 * s }
    private var deskH: CGFloat { 40 * s }

    private var workers: [ConnectionSession] { members.filter { status($0) == .working } }
    private var loungers: [ConnectionSession] { members.filter { status($0) != .working } }

    var body: some View {
        GeometryReader { geo in
            let L = layout(geo.size)
            ZStack(alignment: .topLeading) {
                areaLabel("办公区", "desktopcomputer", Theme.brand).position(x: L.officeW / 2, y: 16)
                areaLabel("休息区", "cup.and.saucer", .secondary).position(x: L.officeW + (geo.size.width - L.officeW) / 2, y: 16)
                Rectangle().fill(Color.black.opacity(0.07)).frame(width: 1).frame(maxHeight: .infinity).position(x: L.officeW, y: geo.size.height / 2)

                furniture("SOFA_FRONT", 32, 16).position(L.sofaCenter)
                furniture("COFFEE_TABLE", 32, 32).position(x: L.sofaCenter.x, y: L.sofaCenter.y - 30 * s)
                furniture("LARGE_PLANT", 16, 32).position(x: geo.size.width - 14 * s, y: 42)
                furniture("CACTUS", 16, 32).position(x: L.officeW + 18 * s, y: 42)

                // desks behind the seated worker
                ForEach(workers, id: \.id) { conn in
                    if let p = L.desk[conn.id] { DeskTile().position(x: p.x, y: p.y - 6 * s) }
                }

                ForEach(members, id: \.id) { conn in
                    let pos = stage.render[conn.id]?.pos ?? (L.officeW > 1 ? OfficeStage.anchor(placement(for: conn, in: L)) : nil)
                    if let pos {
                        CharNode(conn: conn, charIndex: colorIndex(conn), status: status(conn), number: number(conn),
                                 mob: stage.render[conn.id], lastLine: lastLine(conn), worked: worked(conn),
                                 selected: selectedID == conn.id, space: space,
                                 onSelect: { selectedID = conn.id }, onEnter: { onEnter(conn) },
                                 onClone: { onClone(conn) }, onRestart: { onRestart(conn) }, onClose: { onClose(conn) },
                                 onDragBegan: { draggingID = conn.id; stage.freeze(conn.id, true) },
                                 onDragMove: onDragMove,
                                 onDrop: { loc in draggingID = nil; stage.freeze(conn.id, false); onDrop(conn, loc) })
                            .position(pos)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onAppear { applyPlacements(L) }
            .onChange(of: placementToken(geo.size)) { applyPlacements(L) }
        }
        .frame(height: roomHeight)
    }

    // MARK: layout

    private struct Layout {
        var officeW: CGFloat
        var desk: [UUID: CGPoint]
        var sofaCenter: CGPoint
        var sofaSeats: [CGPoint]
        var loungeRect: CGRect
    }

    private var roomHeight: CGFloat {
        let deskRows = Int(ceil(Double(max(1, workers.count)) / 2))
        let loungeRows = Int(ceil(Double(max(1, loungers.count)) / 3))
        return max(250, CGFloat(max(deskRows, loungeRows)) * (deskH + 18) + 80)
    }

    private func layout(_ size: CGSize) -> Layout {
        let frac: CGFloat = 0.75 // 办公区 : 休息区 = 3 : 1
        let marginX = deskW / 2 + 12
        let pitchX = deskW + 18
        // Two desk columns only if the office side is wide enough to hold them without overlap/spill.
        var officeW = max(size.width * frac, marginX + deskW / 2 + 10)
        officeW = min(officeW, size.width - 110)
        let twoCols = officeW >= marginX + pitchX + deskW / 2 + 8
        let cols = twoCols ? 2 : 1

        var desks: [UUID: CGPoint] = [:]
        let topY = deskH / 2 + 14, pitchY = deskH + 18
        for (i, conn) in workers.enumerated() {
            let col = i % cols, row = i / cols
            let x = cols == 1 ? officeW / 2 : marginX + CGFloat(col) * pitchX
            desks[conn.id] = CGPoint(x: x, y: topY + CGFloat(row) * pitchY)
        }
        let loungeX = officeW, loungeW = size.width - officeW
        let sofaCenter = CGPoint(x: loungeX + loungeW / 2, y: size.height - 14 * s)
        let sofaSeats = [CGPoint(x: sofaCenter.x - 11 * s, y: sofaCenter.y - 12 * s),
                         CGPoint(x: sofaCenter.x + 11 * s, y: sofaCenter.y - 12 * s)]
        let loungeRect = CGRect(x: loungeX + 26 * s, y: 44, width: max(20, loungeW - 52 * s),
                                height: max(20, size.height - 44 - 30 * s))
        return Layout(officeW: officeW, desk: desks, sofaCenter: sofaCenter, sofaSeats: sofaSeats, loungeRect: loungeRect)
    }

    private func placement(for conn: ConnectionSession, in L: Layout) -> Placement {
        if status(conn) == .working { return .desk(L.desk[conn.id] ?? CGPoint(x: L.officeW / 2, y: deskH / 2 + 14)) }
        // Resting sessions all roam the lounge freely (walk → pause → walk) — nobody is pinned to a
        // seat, so no character ever just sits frozen.
        if status(conn) == .resting { return .wander(L.loungeRect) }
        let idx = loungers.firstIndex(where: { $0.id == conn.id }) ?? 0
        let x = L.loungeRect.midX + CGFloat((idx % 3) - 1) * 50 // connecting / reconnecting / failed
        return .stand(CGPoint(x: x, y: L.loungeRect.midY))
    }

    private func applyPlacements(_ L: Layout) {
        guard L.officeW > 1 else { return }
        for conn in members { stage.place(conn.id, zone: zoneId, placement(for: conn, in: L)) }
        stage.prune(zone: zoneId, active: Set(members.map { $0.id })) // zone-scoped: only this room's leavers
    }

    private func placementToken(_ size: CGSize) -> String {
        let m = members.map { "\($0.id)\(status($0))" }.joined(separator: ",")
        return "\(Int(size.width))x\(Int(size.height))|\(m)"
    }

    private func areaLabel(_ title: String, _ symbol: String, _ tint: Color) -> some View {
        Label(title, systemImage: symbol).font(.caption2).foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color(white: 0.93), in: Capsule())
    }

    private func furniture(_ n: String, _ w: CGFloat, _ h: CGFloat) -> some View {
        Group {
            if let img = OfficeAssets.shared.furniture[n] {
                Image(nsImage: img).interpolation(.none).resizable().frame(width: w * s, height: h * s)
            }
        }.allowsHitTesting(false)
    }
}

/// A desk with a glowing PC (no person — the character walks over and sits on top).
private struct DeskTile: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var s: CGFloat { OfficeAssets.scale }
    var body: some View {
        ZStack {
            furniture("DESK_FRONT", 48, 32)
            pc.offset(y: -13 * s)
        }
        .frame(width: 48 * s, height: 40 * s)
        .allowsHitTesting(false)
    }
    @ViewBuilder private var pc: some View {
        if reduceMotion {
            furniture("PC_FRONT_ON_1", 16, 32)
        } else {
            TimelineView(.periodic(from: .now, by: 1.0 / 3.0)) { ctx in
                furniture("PC_FRONT_ON_\(Int(ctx.date.timeIntervalSinceReferenceDate * 3) % 3 + 1)", 16, 32)
            }
        }
    }
    private func furniture(_ n: String, _ w: CGFloat, _ h: CGFloat) -> some View {
        Group {
            if let img = OfficeAssets.shared.furniture[n] {
                Image(nsImage: img).interpolation(.none).resizable().frame(width: w * s, height: h * s)
            } else {
                RoundedRectangle(cornerRadius: 3).fill(.brown.opacity(0.6)).frame(width: w * s, height: h * s)
            }
        }
    }
}

// MARK: - Character node (sprite-anchored; all labels are non-layout overlays)

private struct CharNode: View {
    let conn: ConnectionSession
    let charIndex: Int
    let status: SeatStatus
    let number: Int?
    let mob: OfficeStage.RenderMob?
    let lastLine: String?
    let worked: Int?
    let selected: Bool
    let space: String
    let onSelect: () -> Void
    let onEnter: () -> Void
    let onClone: () -> Void
    let onRestart: () -> Void
    let onClose: () -> Void
    let onDragBegan: () -> Void
    let onDragMove: (CGPoint) -> Void
    let onDrop: (CGPoint) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var s: CGFloat { OfficeAssets.scale }
    @State private var dragOffset: CGSize = .zero
    @State private var dragging = false
    @State private var hovering = false

    private var moving: Bool { mob?.moving ?? false }
    private var seatedWorking: Bool { status == .working && !moving }
    private var showName: Bool { status == .working || selected || hovering || dragging }

    var body: some View {
        // Footprint = ONLY the sprite box (16*s × 32*s). Shadow + character compose inside it.
        // Everything else (badges, name, output, work bar, arrow) is an OVERLAY → never resizes the
        // hit area and never shifts the sprite when it appears/disappears.
        ZStack(alignment: .bottom) {
            if !seatedWorking {
                Ellipse().fill(.black.opacity(0.18)).frame(width: 8 * s, height: 3 * s).offset(y: 2)
            }
            character
        }
        .frame(width: 16 * s, height: 32 * s)
        .overlay(alignment: .top) { StatusBadge(status: status, justFinished: conn.outputPhase == .justFinished).offset(y: -10) }
        .overlay(alignment: .topTrailing) { if let n = number { numberTag(n).offset(x: 7, y: -4) } }
        .overlay(alignment: .top) { aboveDecorations.offset(y: -16 * s) }
        .overlay(alignment: .bottom) { belowDecorations.offset(y: 18 * s) }
        .contentShape(Rectangle())
        .background(selected ? Theme.brand.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .scaleEffect(dragging ? 1.08 : 1)
        .offset(dragOffset)
        .zIndex(dragging ? 20 : (selected ? 5 : 0))
        .onHover { hovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 5, coordinateSpace: .named(space))
                .onChanged { v in if !dragging { dragging = true; onDragBegan() }; dragOffset = v.translation; onDragMove(v.location) }
                .onEnded { v in dragging = false; dragOffset = .zero; onDrop(v.location) }
        )
        .onTapGesture(count: 2) { onEnter() }
        .simultaneousGesture(TapGesture(count: 1).onEnded { onSelect() }) // immediate select (no double-tap wait)
        .contextMenu {
            Button("进入终端") { onEnter() }
            Button("克隆") { onClone() }
            Button("重启 session") { onRestart() }
            Divider()
            Button("关闭", role: .destructive) { onClose() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yLabel)
        .accessibilityHint("连按两下进入终端")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onSelect() }
        .accessibilityAction(named: "进入终端") { onEnter() }
        .accessibilityAction(named: "克隆") { onClone() }
        .accessibilityAction(named: "重启 session") { onRestart() }
        .accessibilityAction(named: "关闭") { onClose() }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: dragging)
    }

    private var aboveDecorations: some View {
        VStack(spacing: 2) {
            if selected {
                Image(systemName: "arrowtriangle.down.fill").font(.system(size: 11)).foregroundStyle(Theme.brand)
                    .shadow(color: Theme.brand.opacity(0.6), radius: 3)
            }
            if seatedWorking, let line = lastLine, !line.isEmpty {
                Text(line).font(.system(size: 9, design: .monospaced)).foregroundStyle(Color(white: 0.95))
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.horizontal, 5).padding(.vertical, 2).frame(maxWidth: 60 * s, alignment: .leading)
                    .background(Color(red: 0.24, green: 0.26, blue: 0.30).opacity(0.92), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .fixedSize()
    }

    private var belowDecorations: some View {
        VStack(spacing: 2) {
            nameTag.opacity(showName ? 1 : 0) // reserve height so the sprite never bobs on hover
            if seatedWorking, let sec = worked { workBar(sec) }
        }
        .fixedSize()
    }

    @ViewBuilder private var character: some View {
        if moving {
            CharSprite(charIndex: charIndex, scale: s, facing: mob?.facing ?? .down, frameIndex: mob?.frame ?? 0)
        } else if status == .working {
            if reduceMotion {
                CharSprite(charIndex: charIndex, scale: s, facing: .up, frameIndex: 3)
            } else {
                TimelineView(.periodic(from: .now, by: 1.0 / 6.0)) { ctx in
                    CharSprite(charIndex: charIndex, scale: s, facing: .up,
                               frameIndex: Int(ctx.date.timeIntervalSinceReferenceDate * 6) % 2 == 0 ? 3 : 4)
                }
            }
        } else {
            CharSprite(charIndex: charIndex, scale: s, facing: .down, frameIndex: 0)
        }
    }

    private func numberTag(_ n: Int) -> some View {
        Text("\(n)").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
            .frame(width: 13, height: 13).background(Circle().fill(Theme.brand))
            .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 0.5))
    }

    private var nameTag: some View {
        Text(conn.title).font(.system(size: 9, weight: .medium)).foregroundStyle(Color(white: 0.32))
            .lineLimit(1).truncationMode(.tail)
            .padding(.horizontal, 6).padding(.vertical, 1).frame(maxWidth: 60 * s)
            .background(Color.black.opacity(0.06), in: Capsule())
    }

    private func workBar(_ sec: Int) -> some View {
        let frac = min(1, Double(sec) / 300)
        return HStack(spacing: 4) {
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(width: 44, height: 5)
                Capsule().fill(Theme.brand).frame(width: 44 * frac, height: 5)
            }
            Text(String(format: "%d:%02d", sec / 60, sec % 60)).font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private var a11yLabel: String {
        var s = "\(conn.title)，\(statusText)"
        if seatedWorking, let sec = worked { s += "，已工作 \(sec / 60) 分 \(sec % 60) 秒" }
        if seatedWorking, let l = lastLine, !l.isEmpty { s += "，最新输出 \(l)" }
        return s
    }
    private var statusText: String {
        switch status {
        case .working: return "工作中"
        case .resting: return "休息中"
        case .connecting: return "连接中"
        case .reconnecting: return "重连中"
        case .failed: return "连接失败"
        }
    }
}

private struct CharSprite: View {
    let charIndex: Int, scale: CGFloat, facing: Facing, frameIndex: Int
    private let assets = OfficeAssets.shared
    var body: some View {
        Group {
            if let img = assets.frame(char: charIndex, row: facing.row, index: frameIndex) {
                Image(nsImage: img).interpolation(.none).resizable().frame(width: 16 * scale, height: 32 * scale)
                    .scaleEffect(x: facing.flip ? -1 : 1, y: 1)
            } else {
                Image(systemName: "person.fill").resizable().scaledToFit()
                    .frame(width: 14 * scale, height: 26 * scale).foregroundStyle(Theme.brand)
            }
        }
    }
}

private struct StatusBadge: View {
    let status: SeatStatus
    let justFinished: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false
    var body: some View {
        Group {
            switch status {
            case .failed: badge("exclamationmark.triangle.fill", .red)
            case .reconnecting:
                if reduceMotion {
                    badge("arrow.triangle.2.circlepath", .orange)
                } else {
                    badge("arrow.triangle.2.circlepath", .orange).rotationEffect(.degrees(spin ? 360 : 0))
                        .onAppear { withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spin = true } }
                }
            case .connecting: badge("ellipsis", .secondary)
            case .resting where justFinished: badge("checkmark.circle.fill", Theme.Status.connected)
            default: EmptyView()
            }
        }
    }
    private func badge(_ symbol: String, _ tint: Color) -> some View {
        Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(.white, tint)
            .padding(2).background(Circle().fill(Color.white))
    }
}
