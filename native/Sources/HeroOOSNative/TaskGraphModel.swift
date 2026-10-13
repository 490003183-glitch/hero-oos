import SwiftUI
import AppKit

struct GraphPoint: Codable, Equatable {
    var x: Double
    var y: Double
    init(_ point: CGPoint) { x = point.x; y = point.y }
    var point: CGPoint { CGPoint(x: x, y: y) }
}
struct GraphLayout: Codable, Equatable {
    var positions: [String: GraphPoint] = [:]
    var collapsed = Set<String>()
    var zoom = 1.0
    var offset = GraphPoint(CGPoint(x: 60, y: 60))
}
struct GraphEdge: Hashable {
    let from: String
    let to: String
    var hierarchy = false
}
enum GraphFilter: String, CaseIterable {
    case all = "全部任务", ready = "可开始", blocked = "被阻塞"
}
enum GraphPersonFilter: Hashable {
    case all, none, person(String)
}
enum GraphTimeFilter: String, CaseIterable {
    case all = "全部", hideUpcoming = "隐藏未到时间", upcomingOnly = "仅看未到时间"
}
enum GraphTrace: String, CaseIterable {
    case all = "全局", upstream = "前置链", downstream = "后续影响", related = "相关链"
}

struct TaskGraphNodePresentation {
    let conditions: [TaskCondition]
    let pending: [TaskCondition]
    let ready: Bool
    let signalsReady: Bool
    let conditionCounts: String
    let timePhase: TaskTimePhase
}

/// Kept separate from the long-lived layout format so existing saved cameras
/// and positions remain compatible. Missing / unknown preferences use defaults.
struct TaskGraphViewState: Codable, Equatable {
    var filter = GraphFilter.all.rawValue
    var trace = GraphTrace.all.rawValue
    var personMode = "all"
    var person = ""
    var time = GraphTimeFilter.all.rawValue
    var showClosed = false, showCancelled = false, showArchived = false
    var showHierarchy = true, showMiniMap = true
    var selection = Set<String>(), expandedSatisfied = Set<String>()
    init() {}
    private enum CodingKeys: String, CodingKey {
        case filter, trace, personMode, person, time, showClosed, showCancelled, showArchived
        case showHierarchy, showMiniMap, selection, expandedSatisfied
    }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filter = (try? c.decode(String.self, forKey: .filter)) ?? filter
        trace = (try? c.decode(String.self, forKey: .trace)) ?? trace
        personMode = (try? c.decode(String.self, forKey: .personMode)) ?? personMode
        person = (try? c.decode(String.self, forKey: .person)) ?? person
        time = (try? c.decode(String.self, forKey: .time)) ?? time
        showClosed = (try? c.decode(Bool.self, forKey: .showClosed)) ?? showClosed
        showCancelled = (try? c.decode(Bool.self, forKey: .showCancelled)) ?? showCancelled
        showArchived = (try? c.decode(Bool.self, forKey: .showArchived)) ?? showArchived
        showHierarchy = (try? c.decode(Bool.self, forKey: .showHierarchy)) ?? showHierarchy
        showMiniMap = (try? c.decode(Bool.self, forKey: .showMiniMap)) ?? showMiniMap
        selection = (try? c.decode(Set<String>.self, forKey: .selection)) ?? selection
        expandedSatisfied = (try? c.decode(Set<String>.self, forKey: .expandedSatisfied)) ?? expandedSatisfied
    }
}

enum TaskGraphGeometry {
    static let size = CGSize(width: 284, height: 194)
    static let titleOnlyZoom = 0.45
    static let overviewZoom = 0.20
    static let titleScreenFontSize = 13.0
    static func nodeRect(at point: CGPoint, zoom: Double) -> CGRect {
        if zoom <= titleOnlyZoom {
            // At everyday overview levels reserve two readable 13 pt lines.
            // Below 20%, use small location-preserving nodes and show the full
            // title in a screen-space inspector on hover / selection instead of
            // creating overlapping enormous labels or rearranging user data.
            let height = zoom >= overviewZoom ? max(88, 38 / zoom) : 88
            return CGRect(x: point.x, y: point.y + (size.height - height) / 2, width: size.width, height: height)
        }
        return CGRect(origin: point, size: size)
    }
    static func backwardPath(from a: CGRect, to b: CGRect) -> [CGPoint] {
        let lane = min(a.minY, b.minY) - 42
        return [CGPoint(x: a.maxX, y: a.midY), CGPoint(x: a.maxX + 32, y: a.midY),
                CGPoint(x: a.maxX + 32, y: lane), CGPoint(x: b.minX - 32, y: lane),
                CGPoint(x: b.minX - 32, y: b.midY), CGPoint(x: b.minX, y: b.midY)]
    }
    /// Packs nearest first, favouring each node's existing direction from the focus.
    /// This is only called by an explicit arrange action, never by pan/zoom/refresh.
    static func nearby(_ positions: [String: GraphPoint], focus: CGPoint, anchor: String?) -> [String: GraphPoint] {
        guard !positions.isEmpty else { return positions }
        let stepX = size.width + 56, stepY = size.height + 50
        let count = Int(ceil(sqrt(Double(positions.count)))) + 1
        struct Slot { let x: Int; let y: Int }
        var slots: [Slot] = []
        for x in -count...count { for y in -count...count where x != 0 || y != 0 { slots.append(Slot(x: x, y: y)) } }
        if anchor == nil { slots.append(Slot(x: 0, y: 0)) }
        func vector(_ id: String) -> CGPoint {
            let p = positions[id]!.point
            return CGPoint(x: (p.x + size.width / 2 - focus.x) / stepX, y: (p.y + size.height / 2 - focus.y) / stepY)
        }
        let ids = positions.keys.filter { $0 != anchor }.sorted {
            let a = vector($0), b = vector($1), da = hypot(a.x, a.y), db = hypot(b.x, b.y)
            return abs(da - db) < 0.0001 ? $0 < $1 : da < db
        }
        var result = positions
        for id in ids {
            let v = vector(id), magnitude = hypot(v.x, v.y)
            func cost(_ s: Slot) -> Double {
                let length = hypot(Double(s.x), Double(s.y))
                let dot = magnitude > 0.001 && length > 0 ? (v.x * Double(s.x) + v.y * Double(s.y)) / (magnitude * length) : 1
                return length * length + 4 * (1 - dot)
            }
            let best = slots.indices.min { cost(slots[$0]) < cost(slots[$1]) }!
            let slot = slots.remove(at: best)
            result[id] = GraphPoint(CGPoint(x: focus.x + Double(slot.x) * stepX - size.width / 2,
                                           y: focus.y + Double(slot.y) * stepY - size.height / 2))
        }
        return result
    }
    /// Deterministic dependency layers; unrelated tasks wrap instead of forming one endless column.
    static func arranged(_ tasks: [Record]) -> [String: GraphPoint] {
        let ids = Set(tasks.map(\.id))
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var degree: [String: Int] = [:], next: [String: [String]] = [:], levels: [String: Int] = [:]
        for task in tasks {
            let deps = Set(task["dependsOn"].array.map(\.string)).intersection(ids)
            degree[task.id] = deps.count
            for id in deps { next[id, default: []].append(task.id) }
        }
        var queue = tasks.filter { degree[$0.id] == 0 }.map(\.id), index = 0
        while index < queue.count {
            let id = queue[index]; index += 1
            for child in next[id] ?? [] {
                levels[child] = max(levels[child] ?? 0, (levels[id] ?? 0) + 1)
                degree[child, default: 0] -= 1
                if degree[child] == 0 { queue.append(child) }
            }
        }
        var result: [String: GraphPoint] = [:], rows: [Int: Int] = [:], detached = 0
        let linked = Set(next.keys).union(next.values.flatMap { $0 })
        for task in tasks.sorted(by: {
            let a = $0.text("parentId").isEmpty ? $0.id : $0.text("parentId")
            let b = $1.text("parentId").isEmpty ? $1.id : $1.text("parentId")
            if a != b { return (byID[a]?.title ?? a).localizedStandardCompare(byID[b]?.title ?? b) == .orderedAscending }
            if $0.id == a { return true }; if $1.id == b { return false }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }) where linked.contains(task.id) {
            let level = levels[task.id] ?? 0, row = rows[level, default: 0]
            result[task.id] = GraphPoint(CGPoint(x: level * 400, y: row * 224))
            rows[level] = row + 1
        }
        let bottom = (rows.values.max() ?? 0) * 224 + (rows.isEmpty ? 0 : 80)
        for task in tasks where !linked.contains(task.id) {
            result[task.id] = GraphPoint(CGPoint(x: (detached % 4) * 340, y: bottom + (detached / 4) * 224)); detached += 1
        }
        return result
    }
}

@MainActor final class TaskGraphModel: ObservableObject {
    // Camera movement is native AppKit work. Publishing every wheel event rebuilds
    // the SwiftUI toolbar and re-encodes the entire graph at trackpad frequency.
    var layout = GraphLayout() {
        didSet {
            if !updatingCamera {
                geometryRevision &+= 1
                objectWillChange.send()
            }
            surface?.needsDisplay = true
        }
    }
    @Published var selection = Set<String>() { didSet { scheduleViewStateSave() } }
    @Published var selectedEdge: GraphEdge?
    @Published var trace = GraphTrace.all { didSet { scheduleViewStateSave() } }
    @Published var filter = GraphFilter.all { didSet { scheduleViewStateSave() } }
    @Published var personFilter = GraphPersonFilter.all { didSet { scheduleViewStateSave() } }
    @Published var timeFilter = GraphTimeFilter.all { didSet { scheduleViewStateSave() } }
    @Published var showClosed = false { didSet { scheduleViewStateSave() } }
    @Published var showCancelled = false { didSet { scheduleViewStateSave() } }
    @Published var showArchived = false { didSet { scheduleViewStateSave() } }
    @Published var showHierarchy = true { didSet { scheduleViewStateSave() } }
    @Published var showMiniMap = true { didSet { scheduleViewStateSave() } }
    @Published var message = "单击选中 · 双击标题改名 · 双击卡片其他区域打开详情 · 悬停 0.5 秒查看概要；从前置任务右侧连到后续任务左侧"
    @Published var working = false
    @Published private(set) var undoCount = 0
    @Published private(set) var expandedSatisfied = Set<String>() { didSet { scheduleViewStateSave() } }
    @Published private(set) var completionFeedback: [String: Date] = [:]
    var tasks: [Record] = []
    /// A page graph draws only that page, but readiness still uses every
    /// authorized task so an existing cross-page dependency remains accurate.
    let space: TaskSpace?
    private var conditionRecords: [Record] = []
    private(set) var byID: [String: Record] = [:]
    private(set) var dependencies = TaskDependencies([])
    weak var surface: TaskGraphSurface?
    var needsInitialFit = false
    private var key = ""
    private let defaults: UserDefaults
    enum UndoItem { case layout(GraphLayout); case receipt(String); case completion(String, [String]) }
    private var undoItems: [UndoItem] = []
    private var observedReceipts = Set<String>()
    private var lastUpcomingTaskIDs: Set<String>?
    private let openedAt = Date()
    private var updatingCamera = false
    private var cameraSave: DispatchWorkItem?
    private var cameraPublication: DispatchWorkItem?
    private var viewStateSave: DispatchWorkItem?
    private var restoringViewState = false
    private var hasRestoredCamera = false
    private var lastPersistedViewState: TaskGraphViewState?
    private var lastPersistedLayout: GraphLayout?
    private(set) var persistenceWriteCount = 0
    private(set) var geometryRevision = 0
    private var taskRevision = 0
    private var presentationRevision = 0
    private var presentationTaskRevision = -1
    private var presentationDate = Date.distantFuture
    private var nextPresentationDate = Date.distantPast
    private var cachedPresentation: [String: TaskGraphNodePresentation] = [:]
    private struct VisibilityKey: Equatable {
        var tasks: Int, clock: Int
        var query: String
        var collapsed: Set<String>
        var filter: GraphFilter
        var people: GraphPersonFilter
        var time: GraphTimeFilter
        var closed: Bool, cancelled: Bool, archived: Bool, hierarchy: Bool
        var expanded: Set<String>, feedback: Set<String>
    }
    private var visibilityKey: VisibilityKey?
    private var cachedVisible: [Record] = []
    private var edgeKey: VisibilityKey?
    private var edgeVisible = Set<String>()
    private var cachedEdges: [(GraphEdge, [GraphEdge])] = []
    private var traceKey: String?
    private var traceSelection = Set<String>()
    private var cachedHighlighted = Set<String>()
    private(set) var visibilityBuildCount = 0
    private(set) var edgeBuildCount = 0
    private(set) var presentationBuildCount = 0
    var undoTitle: String {
        if case .completion = undoItems.last { return "撤销完成" }
        return "撤销"
    }
    init(defaults: UserDefaults = .standard, space: TaskSpace? = nil) { self.defaults = defaults; self.space = space }
    func creationSpaces(parent: String?, available: [TaskSpace]) -> [TaskSpace] {
        if let parent, let task = byID[parent] { return [task.taskSpace] }
        if let space { return [space] }
        return available
    }
    func connect(identity: String, tasks: [Record]) {
        let newKey = "HeroOOS.taskGraph.v1.\(identity)" + (space.map { ".page.\($0.rawValue)" } ?? "")
        if key != newKey {
            persist()
            restoringViewState = true
            key = newKey
            lastPersistedLayout = nil
            lastPersistedViewState = nil
            hasRestoredCamera = false
            needsInitialFit = false
            cameraPublication?.cancel(); cameraPublication = nil
            selectedEdge = nil; completionFeedback = [:]; lastUpcomingTaskIDs = nil
            undoItems = []; undoCount = 0; observedReceipts = []
            self.tasks = []; conditionRecords = []; byID = [:]; dependencies = TaskDependencies([]); taskRevision &+= 1
            if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode(GraphLayout.self, from: data) {
                layout = saved
                layout.zoom = min(3, max(0.08, saved.zoom.isFinite ? saved.zoom : 1))
                layout.positions = saved.positions.filter { $0.value.x.isFinite && $0.value.y.isFinite }
                if !layout.offset.x.isFinite || !layout.offset.y.isFinite { layout.offset = GraphPoint(CGPoint(x: 60, y: 60)) }
                lastPersistedLayout = layout
                hasRestoredCamera = true
            } else { layout = GraphLayout() }
            // Never let the former unfinished-default migration or a delayed
            // task refresh overwrite a user's saved viewport on app startup.
            needsInitialFit = !hasRestoredCamera
            let saved = defaults.data(forKey: key + ".view").flatMap { try? JSONDecoder().decode(TaskGraphViewState.self, from: $0) }
            restoreViewState(saved ?? TaskGraphViewState())
            lastPersistedViewState = saved
            restoringViewState = false
        }
        reconcile(tasks)
    }
    func reconcile(_ allRecords: [Record]) {
        let records = space.map { page in allRecords.filter { $0.taskSpace == page } } ?? allRecords
        let changed = conditionRecords != allRecords
        if changed { objectWillChange.send() }
        for task in records where task.status == "completed" && byID[task.id] != nil && byID[task.id]?.status != "completed" {
            completionFeedback[task.id] = Date().addingTimeInterval(3)
        }
        completionFeedback = completionFeedback.filter { id, _ in records.contains { $0.id == id && $0.status == "completed" } }
        if changed {
            tasks = records
            conditionRecords = allRecords
            byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            dependencies = TaskDependencies(allRecords)
            taskRevision &+= 1
        }
        let ids = Set(records.map(\.id))
        if !selection.isSubset(of: ids) { selection.formIntersection(ids) }
        if !expandedSatisfied.isSubset(of: ids) { expandedSatisfied.formIntersection(ids) }
        if let edge = selectedEdge, !ids.contains(edge.from) || !ids.contains(edge.to) { selectedEdge = nil }
        let missing = records.filter { layout.positions[$0.id] == nil }
        guard !missing.isEmpty else { return }
        if layout.positions.isEmpty { layout.positions = TaskGraphGeometry.arranged(records); needsInitialFit = !hasRestoredCamera }
        else {
            let bottom = (layout.positions.values.map(\.y).max() ?? 0) + 224
            for (i, item) in missing.enumerated() {
                let position = CGPoint(x: Double(i % 4) * 340, y: bottom + Double(i / 4) * 224)
                layout.positions[item.id] = GraphPoint(position)
            }
        }
        persist()
    }
    func persist() {
        cameraSave?.cancel(); cameraSave = nil
        persistViewState()
        guard !key.isEmpty, lastPersistedLayout != layout,
              let data = try? JSONEncoder().encode(layout) else { return }
        defaults.set(data, forKey: key)
        lastPersistedLayout = layout; persistenceWriteCount += 1
    }
    private var viewState: TaskGraphViewState {
        var value = TaskGraphViewState()
        value.filter = filter.rawValue; value.trace = trace.rawValue; value.time = timeFilter.rawValue
        switch personFilter {
        case .all: value.personMode = "all"
        case .none: value.personMode = "none"
        case .person(let person): value.personMode = "person"; value.person = person
        }
        value.showClosed = showClosed; value.showCancelled = showCancelled; value.showArchived = showArchived
        value.showHierarchy = showHierarchy; value.showMiniMap = showMiniMap
        value.selection = selection; value.expandedSatisfied = expandedSatisfied
        return value
    }
    private func restoreViewState(_ value: TaskGraphViewState) {
        filter = GraphFilter(rawValue: value.filter) ?? .all
        trace = GraphTrace(rawValue: value.trace) ?? .all
        timeFilter = GraphTimeFilter(rawValue: value.time) ?? .all
        switch value.personMode {
        case "none": personFilter = .none
        case "person":
            let person = value.person.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            personFilter = person.isEmpty ? .all : .person(person)
        default: personFilter = .all
        }
        showClosed = value.showClosed; showCancelled = value.showCancelled; showArchived = value.showArchived
        showHierarchy = value.showHierarchy; showMiniMap = value.showMiniMap
        selection = value.selection; expandedSatisfied = value.expandedSatisfied
    }
    private func scheduleViewStateSave() {
        guard !restoringViewState, !key.isEmpty else { return }
        viewStateSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.persistViewState() }
        viewStateSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }
    private func persistViewState() {
        viewStateSave?.cancel(); viewStateSave = nil
        guard !key.isEmpty, !restoringViewState else { return }
        let value = viewState
        guard value != lastPersistedViewState, let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key + ".view"); lastPersistedViewState = value
    }
    /// Do not move nodes, rebuild task topology or publish the whole SwiftUI tree.
    /// Camera writes are coalesced until the gesture settles; quitting / leaving
    /// the graph also flushes this same layout synchronously.
    func updateCamera(zoom: Double? = nil, offset: CGPoint, persistImmediately: Bool = false) {
        let nextZoom = zoom.map { min(3, max(0.08, $0.isFinite ? $0 : 1)) } ?? layout.zoom
        guard offset.x.isFinite, offset.y.isFinite,
              nextZoom != layout.zoom || GraphPoint(offset) != layout.offset else { return }
        let zoomChanged = nextZoom != layout.zoom
        updatingCamera = true
        var next = layout; next.zoom = nextZoom; next.offset = GraphPoint(offset); layout = next
        updatingCamera = false
        if zoomChanged, cameraPublication == nil {
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.cameraPublication = nil; self.objectWillChange.send()
            }
            cameraPublication = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
        }
        cameraSave?.cancel()
        if persistImmediately { persist() }
        else {
            let item = DispatchWorkItem { [weak self] in self?.persist() }
            cameraSave = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
        }
    }

    /// Conditions only change with task data or when the next actual time gate
    /// is crossed. Panning, drawing a pulse and selecting a node do not parse
    /// dates and rebuild the same condition lists again.
    func presentation(at now: Date = Date()) -> [String: TaskGraphNodePresentation] {
        if presentationTaskRevision == taskRevision, now >= presentationDate, now < nextPresentationDate { return cachedPresentation }
        presentationTaskRevision = taskRevision; presentationDate = now
        nextPresentationDate = .distantFuture
        cachedPresentation = Dictionary(tasks.map { task in
            let conditions = dependencies.conditions(task, at: now), pending = conditions.filter { !$0.satisfied }
            if let date = TaskDependencies.availableDate(task), date > now { nextPresentationDate = min(nextPresentationDate, date) }
            let ready = task.isExecutionTracked && task.status != "active" && pending.isEmpty && (task.status == "ready" || !conditions.isEmpty)
            let counts = [(TaskConditionKind.person, "人"), (.time, "时间"), (.task, "任务")].compactMap { kind, name -> String? in
                let count = pending.filter { $0.kind == kind }.count
                return count > 0 ? "\(name) \(count)" : nil
            }.joined(separator: " · ")
            return (task.id, TaskGraphNodePresentation(conditions: conditions, pending: pending, ready: ready,
                signalsReady: !conditions.isEmpty && ready, conditionCounts: counts, timePhase: dependencies.timePhase(task, at: now)))
        }, uniquingKeysWith: { a, _ in a })
        presentationRevision &+= 1; presentationBuildCount += 1
        return cachedPresentation
    }
    private func snapshotKey(query: String, clock: Int) -> VisibilityKey {
        VisibilityKey(tasks: taskRevision, clock: clock, query: query, collapsed: layout.collapsed,
                      filter: filter, people: personFilter, time: timeFilter, closed: showClosed,
                      cancelled: showCancelled, archived: showArchived, hierarchy: showHierarchy,
                      expanded: expandedSatisfied, feedback: Set(completionFeedback.keys))
    }
    func checkpoint(_ old: GraphLayout) { guard old != layout else { return }; push(.layout(old)); persist() }
    private func push(_ item: UndoItem) { undoItems.append(item); if undoItems.count > 60 { undoItems.removeFirst() }; undoCount = undoItems.count }
    func arrange(query: String? = nil) {
        let shown = visible(query: query ?? surface?.query ?? "")
        guard !shown.isEmpty else { return }
        let ids = Set(shown.map(\.id))
        // Use the drawn graph: collapsed children contribute edges to their visible representative.
        // These projected records are layout-only; the tasks and their real dependencies stay intact.
        let incoming = Dictionary(grouping: edges(visible: ids).map(\.0).filter { !$0.hierarchy }, by: \.to)
        let projected = shown.map { task -> Record in
            var node = task
            node["dependsOn"] = .array((incoming[task.id] ?? []).map { .string($0.from) })
            return node
        }
        let old = layout
        var positions = layout.positions
        for (id, point) in TaskGraphGeometry.arranged(projected) { positions[id] = point }
        // Hidden history, filtered tasks and collapsed children keep their saved coordinates.
        layout.positions = positions; checkpoint(old); surface?.fit()
        message = "已按当前显示的任务依赖整理，隐藏任务不占位，可撤销"
    }
    func arrangeNearby(query: String) {
        let shown = visible(query: query)
        guard !shown.isEmpty else { return }
        let viewport = surface.map { $0.world(CGPoint(x: $0.bounds.midX, y: $0.bounds.midY)) } ?? .zero
        func center(_ id: String) -> CGPoint {
            let p = layout.positions[id]?.point ?? .zero
            return CGPoint(x: p.x + TaskGraphGeometry.size.width / 2, y: p.y + TaskGraphGeometry.size.height / 2)
        }
        let anchor = shown.filter { selection.contains($0.id) }.min {
            let a = center($0.id), b = center($1.id)
            let da = hypot(a.x - viewport.x, a.y - viewport.y), db = hypot(b.x - viewport.x, b.y - viewport.y)
            return abs(da - db) < 0.0001 ? $0.id < $1.id : da < db
        }?.id
        let old = layout, focus = anchor.map(center) ?? viewport
        let ids = Set(shown.map(\.id))
        let arranged = TaskGraphGeometry.nearby(layout.positions.filter { ids.contains($0.key) }, focus: focus, anchor: anchor)
        var positions = layout.positions
        for (id, value) in arranged { positions[id] = value }
        // Collapsed descendants travel with their visible parent without losing their relative positions.
        for task in tasks where !ids.contains(task.id) {
            let parent = representative(task.id)
            if parent != task.id, let before = old.positions[parent], let after = arranged[parent], let child = old.positions[task.id] {
                positions[task.id] = GraphPoint(CGPoint(x: child.x + after.x - before.x, y: child.y + after.y - before.y))
            }
        }
        layout.positions = positions; checkpoint(old)
        message = anchor == nil ? "已围绕当前视野中心就近整理，可撤销" : "已围绕「\(byID[anchor!]?.title ?? "选中任务")」就近整理，焦点位置不变，可撤销"
    }
    func collapse(_ id: String) {
        if layout.collapsed.contains(id) { layout.collapsed.remove(id) } else { layout.collapsed.insert(id) }
        persist()
    }
    func satisfiedPredecessors(_ task: Record) -> [Record] {
        var seen = Set<String>()
        return task["dependsOn"].array.compactMap { value in
            guard seen.insert(value.string).inserted, let upstream = byID[value.string], upstream.status == "completed" else { return nil }
            return upstream
        }
    }
    func toggleSatisfied(_ id: String) {
        if !expandedSatisfied.insert(id).inserted { expandedSatisfied.remove(id) }
        message = expandedSatisfied.contains(id) ? "已展开这项任务的已完成前置；再次点击「已满足」可收起" : "已收起已完成前置，依赖关系保留"
    }
    private func statusVisible(_ task: Record) -> Bool {
        (showArchived || !task.isArchived) &&
        (task.status == "completed" ? showClosed || completionFeedback[task.id] != nil : task.status != "cancelled" || showCancelled)
    }
    private func pendingPeople(_ task: Record) -> Set<String> {
        Set(TaskPeopleWaits.entries(task).filter { !$0["resolved"].bool }.map {
            $0.text("person").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty })
    }
    var blockerPeople: [String] {
        var people = Set(tasks.filter(statusVisible).flatMap { pendingPeople($0) })
        // Keep a selected option available even when its last condition was resolved elsewhere.
        if case .person(let person) = personFilter { people.insert(person) }
        return people.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private func matchesPerson(_ task: Record) -> Bool {
        switch personFilter {
        case .all: return true
        case .none: return pendingPeople(task).isEmpty
        case .person(let person): return pendingPeople(task).contains(person)
        }
    }
    private func isUpcoming(_ task: Record, at now: Date) -> Bool {
        TaskDependencies.availableDate(task).map { $0 > now } ?? false
    }
    private func matchesTime(_ task: Record, at now: Date) -> Bool {
        switch timeFilter {
        case .all: return true
        case .hideUpcoming: return !isUpcoming(task, at: now)
        case .upcomingOnly: return isUpcoming(task, at: now)
        }
    }
    private func pruneHiddenSelection(query: String, at now: Date = Date()) {
        let ids = Set(visible(query: query, at: now).map(\.id))
        selection.formIntersection(ids)
        if let edge = selectedEdge, !ids.contains(edge.from) || !ids.contains(edge.to) { selectedEdge = nil }
    }
    func personFilterDidChange(query: String) {
        pruneHiddenSelection(query: query)
        switch personFilter {
        case .all: message = "已显示全部阻断人；卡片位置保持不变"
        case .none: message = "仅显示没有未解决等人条件的任务；时间与任务依赖仍可能阻断"
        case .person(let person): message = "仅显示当前等待 \(person) 的任务；折叠子任务由父节点代表，已展开前置保留为上下文"
        }
    }
    func timeFilterDidChange(query: String, at now: Date = Date()) {
        lastUpcomingTaskIDs = timeFilter == .all ? nil : Set(tasks.filter { isUpcoming($0, at: now) }.map(\.id))
        pruneHiddenSelection(query: query, at: now)
        switch timeFilter {
        case .all: message = "已显示全部阻断时间；其他筛选仍生效，卡片位置不变"
        case .hideUpcoming: message = "已隐藏可开始时间未到的任务；到点自动恢复显示，等人和任务依赖仍可能阻断"
        case .upcomingOnly: message = "仅显示可开始时间未到的任务；到点自动移出当前视图，任务内容与位置保留"
        }
    }
    /// The wall clock can cross a condition while task data stays unchanged.
    /// Reuse the surface's existing one-second check without moving or saving any card.
    func refreshTimeFilter(query: String, at now: Date = Date()) {
        guard timeFilter != .all else { lastUpcomingTaskIDs = nil; return }
        let upcoming = Set(tasks.filter { isUpcoming($0, at: now) }.map(\.id))
        guard upcoming != lastUpcomingTaskIDs else { return }
        objectWillChange.send()
        lastUpcomingTaskIDs = upcoming
        pruneHiddenSelection(query: query, at: now)
    }
    /// A hidden closed parent must not swallow a reopened child when collapsed.
    func representative(_ id: String) -> String {
        if expandedSatisfied.contains(where: { owner in byID[owner].map { satisfiedPredecessors($0).contains { $0.id == id } } ?? false }) { return id }
        let records = byID
        var result = id, current = records[id]?.text("parentId") ?? "", seen = Set<String>()
        while !current.isEmpty, seen.insert(current).inserted {
            if layout.collapsed.contains(current), let parent = records[current], statusVisible(parent) { result = current }
            current = records[current]?.text("parentId") ?? ""
        }
        return result
    }
    func reveal(_ id: String) {
        guard byID[id] != nil else { return }
        var current = byID[id]?.text("parentId") ?? "", seen = Set<String>()
        while !current.isEmpty, seen.insert(current).inserted { layout.collapsed.remove(current); current = byID[current]?.text("parentId") ?? "" }
        if let task = byID[id] {
            if task.status == "completed" { showClosed = true }
            if task.status == "cancelled" { showCancelled = true }
            if task.isArchived { showArchived = true }
        }
        filter = .all; personFilter = .all; timeFilter = .all; selection = [id]; persist()
        surface?.fit(ids: [id])
    }
    func visible(query: String, at now: Date = Date()) -> [Record] {
        let details = presentation(at: now)
        let key = snapshotKey(query: query, clock: presentationRevision)
        if visibilityKey == key { return cachedVisible }
        visibilityBuildCount += 1
        let matches = Set(tasks.filter {
            (query.isEmpty || StudioLedger.matches($0, query: query)) && matchesPerson($0) && matchesTime($0, at: now) &&
            ((personFilter == .all && timeFilter == .all) || statusVisible($0))
        }.map { representative($0.id) })
        let base = tasks.filter { task in
            representative(task.id) == task.id && statusVisible(task) &&
            matches.contains(task.id) &&
            (completionFeedback[task.id] != nil || filter == .all || (filter == .ready ? details[task.id]?.ready == true : !task.isClosed && details[task.id]?.pending.isEmpty == false))
        }
        let context = Set(base.filter { expandedSatisfied.contains($0.id) }.flatMap { satisfiedPredecessors($0).map(\.id) })
        let ids = Set(base.map(\.id)).union(context)
        cachedVisible = tasks.filter { ids.contains($0.id) }; visibilityKey = key
        return cachedVisible
    }
    func expireCompletionFeedback(at now: Date = Date()) {
        let expired = Set(completionFeedback.filter { $0.value <= now }.keys)
        guard !expired.isEmpty else { return }
        completionFeedback = completionFeedback.filter { !expired.contains($0.key) }
        let visibleIDs = Set(visible(query: "").map(\.id))
        selection.subtract(expired.subtracting(visibleIDs))
        if let edge = selectedEdge, !visibleIDs.contains(edge.from) || !visibleIDs.contains(edge.to) { selectedEdge = nil }
    }
    func observeCompletions(_ receipts: [Record], initial: Bool = false) {
        for receipt in receipts where observedReceipts.insert(receipt.id).inserted {
            guard !initial, receipt.text("clientMutationId").hasPrefix("native-"),
                  let date = RuntimeDate.parse(receipt.text("timestamp")), date >= openedAt else { continue }
            // Receipt undo is atomic. Never offer to undo a mixed-page batch
            // from inside a page-only graph, where its other effects are hidden.
            if space != nil {
                let operations = receipt["operations"].array + receipt["inverseOps"].array
                guard !operations.isEmpty, operations.allSatisfy({
                    $0["type"].string.hasPrefix("task.") && byID[$0["id"].string] != nil
                }), receipt["affected"].array.allSatisfy({ $0["entity"] == "task" && byID[$0["id"].string] != nil }) else { continue }
            }
            let ids = receipt["operations"].array.compactMap { op -> String? in
                guard op["type"] == "task.complete" || (op["type"] == "task.update" && op["changes"]["status"] == "completed"),
                      receipt["inverseOps"].array.contains(where: { $0["id"] == op["id"] && $0["changes"]["status"] != .null && $0["changes"]["status"] != "completed" }) else { return nil }
                return op["id"].string
            }
            guard !ids.isEmpty else { continue }
            push(.completion(receipt.id, ids))
            for id in ids { completionFeedback[id] = Date().addingTimeInterval(3) }
            message = "已完成 \(ids.count) 项；3 秒后收起，可点「撤销完成」恢复。依赖关系保留"
        }
    }
    func edges(visible: Set<String>) -> [(GraphEdge, [GraphEdge])] {
        let key = snapshotKey(query: "", clock: 0)
        if edgeKey == key, edgeVisible == visible { return cachedEdges }
        edgeBuildCount += 1
        var edges: [GraphEdge: [GraphEdge]] = [:]
        for task in tasks {
            for upstream in task["dependsOn"].array.map(\.string) {
                let edge = GraphEdge(from: representative(upstream), to: representative(task.id))
                if edge.from != edge.to, visible.contains(edge.from), visible.contains(edge.to) { edges[edge, default: []].append(GraphEdge(from: upstream, to: task.id)) }
            }
            if showHierarchy, !task.text("parentId").isEmpty {
                let edge = GraphEdge(from: representative(task.text("parentId")), to: representative(task.id), hierarchy: true)
                if edge.from != edge.to, visible.contains(edge.from), visible.contains(edge.to) { edges[edge, default: []].append(edge) }
            }
        }
        cachedEdges = edges.sorted { ($0.key.from + $0.key.to) < ($1.key.from + $1.key.to) }.map { ($0.key, $0.value) }
        edgeKey = key; edgeVisible = visible
        return cachedEdges
    }
    var highlighted: Set<String> {
        let key = "\(taskRevision):\(trace.rawValue)"
        if traceKey == key, traceSelection == selection { return cachedHighlighted }
        traceKey = key; traceSelection = selection
        guard trace != .all, !selection.isEmpty else { cachedHighlighted = Set(tasks.map(\.id)); return cachedHighlighted }
        let graph = dependencies
        var reverse: [String: [String]] = [:]
        for (id, deps) in graph.requirements { for dep in deps { reverse[dep, default: []].append(id) } }
        let up = TaskDependencies.reachable(selection, edges: graph.requirements)
        let down = TaskDependencies.reachable(selection, edges: reverse)
        cachedHighlighted = (trace == .upstream ? up : (trace == .downstream ? down : up.union(down))).intersection(Set(tasks.map(\.id)))
        return cachedHighlighted
    }
    func link(_ edge: GraphEdge, connected: Bool, store: OOSStore) async {
        guard !working else { return }
        if space != nil && (byID[edge.from] == nil || byID[edge.to] == nil) { return }
        if connected && !TaskDependencies(store.tasks).canDepend(edge.to, on: edge.from) { message = "这条连线会形成循环或父子死锁，未建立"; return }
        if connected && (store.task(edge.to)?["dependsOn"].array.map(\.string).contains(edge.from) ?? false) { message = "这条依赖已经存在"; return }
        working = true; defer { working = false }
        if await store.perform([["type": "task.dependency", "id": .string(edge.to), "upstreamId": .string(edge.from), "connected": .bool(connected)]]) {
            if let receipt = store.state["receipts"].records.last { push(.receipt(receipt.id)) }
            selectedEdge = nil
            message = connected ? "已建立：完成 \(store.task(edge.from)?.title ?? "前置任务") 后，才能开始 \(store.task(edge.to)?.title ?? "后续任务")" : "已解除依赖，任务保留"
        } else { message = store.error ?? "保存失败，请重试" }
    }
    func undo(store: OOSStore) async {
        guard !working, let item = undoItems.last else { return }
        switch item {
        case .layout(let old): layout = old; persist()
        case .receipt(let id):
            working = true; defer { working = false }
            guard await store.perform([["type": "receipt.undo", "receiptId": .string(id)]]) else { message = store.error ?? "后续已有修改，无法撤销"; return }
        case .completion(let id, let taskIDs):
            working = true; defer { working = false }
            guard await store.perform([["type": "receipt.undo", "receiptId": .string(id)]]) else { message = store.error ?? "后续已有修改，无法撤销"; return }
            reconcile(store.tasks)
            for taskID in taskIDs { completionFeedback.removeValue(forKey: taskID) }
            selection = Set(taskIDs)
        }
        undoItems.removeLast(); undoCount = undoItems.count; message = "已撤销"
    }
}

struct TaskGraphWorkspace: View {
    @EnvironmentObject var store: OOSStore
    @Binding var selected: String?
    let search: String
    @StateObject private var graph: TaskGraphModel
    init(selected: Binding<String?>, search: String, space: TaskSpace? = nil) {
        _selected = selected; self.search = search
        _graph = StateObject(wrappedValue: TaskGraphModel(space: space))
    }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    Picker("范围", selection: $graph.filter) { ForEach(GraphFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 160)
                    Picker("阻断人", selection: $graph.personFilter) {
                        Text("全部").tag(GraphPersonFilter.all)
                        Text("无等人阻断").tag(GraphPersonFilter.none)
                        ForEach(graph.blockerPeople, id: \.self) { person in
                            Text(person).tag(GraphPersonFilter.person(person))
                        }
                    }.frame(width: 210)
                        .help("按未解决的等人条件筛选；ALICE 与 alice 视为同一人，多人条件中命中任意一人即显示。不会修改任务或重排卡片。")
                    Picker("阻断时间", selection: $graph.timeFilter) {
                        ForEach(GraphTimeFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.frame(width: 240)
                        .help("按可开始时间筛选，不按截止日期。隐藏未到时间时，到点自动恢复显示；仍与阻断人、搜索和范围取交集，不改变任务或布局。")
                    Picker("追踪", selection: $graph.trace) { ForEach(GraphTrace.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 160)
                    Toggle("显示已完成", isOn: Binding(get: { graph.showClosed }, set: { value in
                        graph.showClosed = value
                        graph.surface?.fit() // Only an explicit toggle reframes, never restoring preferences.
                    })).toggleStyle(.checkbox)
                    Menu("显示") {
                        Toggle("已放弃", isOn: $graph.showCancelled)
                        Toggle("已归档", isOn: $graph.showArchived)
                        Toggle("父子关系（虚线）", isOn: $graph.showHierarchy)
                        Toggle("小地图", isOn: $graph.showMiniMap)
                        Button("展开全部子任务") { graph.layout.collapsed = []; graph.persist() }
                        Button("收起所有已满足的前置") {
                            for id in graph.expandedSatisfied { graph.toggleSatisfied(id) }
                        }.disabled(graph.expandedSatisfied.isEmpty)
                    }
                    Button("就近整理") { graph.arrangeNearby(query: search) }.help("以选中任务或视野中心为焦点，按现有方向就近排紧；仅点击后整理，可撤销")
                    Button("按依赖整理") { graph.arrange(query: search) }.help("只整理当前显示的任务，按依赖分层排紧；隐藏任务不占位，可撤销")
                    Button { Task { await graph.undo(store: store) } } label: { Label(graph.undoTitle, systemImage: "arrow.uturn.backward") }.disabled(graph.undoCount == 0 || graph.working)
                    Button("定位全部") { graph.surface?.fit() }
                    Button("定位选中") { graph.surface?.fit(ids: graph.selection) }.disabled(graph.selection.isEmpty)
                }.padding(10)
            }
            // SwiftUI pop-up buttons can hit a hosting view rather than an
            // NSControl. Do not let the global blank-area monitor dismiss the
            // inspector (and relayout the open menu) while a filter is clicked.
            .taskDetailClickTarget()
            Divider()
            TaskGraphView(store: store, graph: graph, selected: $selected, search: search)
                .taskDetailClickTarget()
            Divider()
            HStack {
                Text("\(graph.visible(query: search).count) / \(graph.tasks.count) 项 · \(graph.layout.zoom < TaskGraphGeometry.overviewZoom ? "全局概览：悬停/选中查看名称 · " : graph.layout.zoom <= TaskGraphGeometry.titleOnlyZoom ? "标题概览 · " : "")实线：完成后开始 · 虚线：子任务").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { graph.surface?.zoomBy(0.8) } label: { Image(systemName: "minus.magnifyingglass") }.help("缩小")
                Text("\(Int(graph.layout.zoom * 100))%").font(.caption.monospacedDigit()).frame(width: 40)
                Button { graph.surface?.zoomBy(1.25) } label: { Image(systemName: "plus.magnifyingglass") }.help("放大")
                Button("100%") { graph.surface?.zoomTo(1) }
            }.padding(.horizontal, 12).padding(.vertical, 6)
            Text(graph.message).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 8)
        }
        .onAppear { graph.connect(identity: store.api.draftIdentity, tasks: store.tasks); graph.observeCompletions(store.state["receipts"].records, initial: true) }
        .onChange(of: store.tasks) { _, tasks in graph.reconcile(tasks) }
        .onChange(of: store.state["receipts"]) { _, receipts in graph.observeCompletions(receipts.records) }
        .onChange(of: graph.personFilter) { _, _ in graph.personFilterDidChange(query: search) }
        .onChange(of: graph.timeFilter) { _, _ in graph.timeFilterDidChange(query: search) }
        .onReceive(NotificationCenter.default.publisher(for: .commitInlineTaskTitle)) { _ in graph.surface?.commitTitle(); graph.persist() }
        .onDisappear { graph.surface?.commitTitle(); graph.persist() }
    }
}
