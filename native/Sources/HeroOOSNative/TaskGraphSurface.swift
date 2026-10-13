import SwiftUI
import AppKit

struct TaskGraphView: NSViewRepresentable {
    @Environment(\.pageBackgroundVisible) private var pageBackgroundVisible
    @ObservedObject var store: OOSStore
    @ObservedObject var graph: TaskGraphModel
    @Binding var selected: String?
    var search: String
    func makeNSView(context: Context) -> TaskGraphSurface { TaskGraphSurface() }
    func updateNSView(_ view: TaskGraphSurface, context: Context) {
        view.store = store; view.graph = graph; graph.surface = view; view.query = search
        view.pageBackgroundVisible = pageBackgroundVisible
        view.openDetail = { selected = $0 }
        view.refreshHoverPreview()
        view.needsDisplay = true
        view.needsLayout = true
    }
}

@MainActor final class TaskGraphSurface: NSView, NSTextFieldDelegate, NSMenuDelegate {
    var pageBackgroundVisible = false
    weak var store: OOSStore?
    weak var graph: TaskGraphModel?
    var query = ""
    var openDetail: ((String?) -> Void)?
    private var nodeRects: [String: CGRect] = [:]
    private var edgePaths: [(GraphEdge, [GraphEdge], [CGPoint])] = []
    private var edgeBounds: [CGRect] = []
    private var cachedGeometryRevision = -1, cachedEdgeRevision = -1
    private var cachedGeometryScale = -1.0
    private var cachedGeometryIDs: [String] = []
    private var cachedGraphID: ObjectIdentifier?
    private var dragStart = CGPoint.zero, downScreen = CGPoint.zero
    private var beforeDrag: GraphLayout?
    private var dragIDs = Set<String>()
    private var downID: String?
    private var action = ""
    private var moved = false, spaceHeld = false
    private var connection: (id: String, output: Bool)?
    private var pointer = CGPoint.zero
    private var marquee: CGRect?
    private var marqueeBase = Set<String>()
    private var miniRect = CGRect.zero, miniWorld = CGRect.zero
    private var miniScale = 1.0
    private var titleEditor: NSTextField?
    private var conditionsPopover: NSPopover?
    private var editingID: String?
    private var tracking: NSTrackingArea?
    private var hoveredID: String?
    private var hoverDwell = TaskGraphHoverDwell()
    private var hoverWork: DispatchWorkItem?
    private var hoverPanel: NSPanel?
    private var hoverSummary: TaskGraphHoverSummary?
    private var hoverScreenPoint: CGPoint?
    private var hoverWindowObservers: [NSObjectProtocol] = []
    private var menuActions: [Int: () -> Void] = [:]
    private var timeTimer: Timer?
    private var lastTimeCheck = Date.distantPast
    private var timePhases: [String: TaskTimePhase] = [:]
    private var readySignals = Set<String>()
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy/MM/dd HH:mm"; return f
    }()
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timeTimer?.invalidate(); timeTimer = nil
        cancelHoverPreview()
        hoverWindowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        hoverWindowObservers = []
        guard window != nil else { return }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            hoverWindowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelHoverPreview() }
            })
        }
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickTimeConditions() }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common); timeTimer = timer
    }
    deinit {
        timeTimer?.invalidate(); hoverWork?.cancel()
        hoverWindowObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil { cancelHoverPreview(); conditionsPopover?.close() }
        super.viewWillMove(toSuperview: newSuperview)
    }
    private func tickTimeConditions() {
        guard let graph, window?.occlusionState.contains(.visible) == true, !isHiddenOrHasHiddenAncestor else { return }
        let now = Date()
        graph.expireCompletionFeedback(at: now)
        if now.timeIntervalSince(lastTimeCheck) >= 1 {
            lastTimeCheck = now
            graph.refreshTimeFilter(query: query, at: now)
            let presentation = graph.presentation(at: now)
            let phases = presentation.mapValues(\.timePhase)
            let signals = Set(presentation.filter { $0.value.signalsReady }.keys)
            if phases != timePhases || signals != readySignals { timePhases = phases; readySignals = signals; graph.objectWillChange.send(); needsDisplay = true }
            refreshHoverPreview()
        }
        let viewport = CGRect(origin: world(.zero), size: CGSize(width: bounds.width / scale, height: bounds.height / scale))
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
           readySignals.contains(where: { nodeRects[$0]?.intersects(viewport) == true }) { needsDisplay = true }
    }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func layout() {
        super.layout()
        if let graph, graph.needsInitialFit, bounds.width > 100, bounds.height > 100 {
            graph.needsInitialFit = false
            DispatchQueue.main.async { [weak self] in self?.fit() }
        }
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Zoomed/panned cards must not paint over the sibling filter toolbar.
        clipsToBounds = true
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("任务关系画布")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var scale: Double { graph?.layout.zoom ?? 1 }
    private var offset: CGPoint { graph?.layout.offset.point ?? .zero }
    func world(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - offset.x) / scale, y: (p.y - offset.y) / scale) }
    func screen(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * scale + offset.x, y: p.y * scale + offset.y) }
    private var titleOnly: Bool { scale <= TaskGraphGeometry.titleOnlyZoom }
    private var globalOverview: Bool { scale < TaskGraphGeometry.overviewZoom }
    func rect(_ id: String) -> CGRect { TaskGraphGeometry.nodeRect(at: graph?.layout.positions[id]?.point ?? .zero, zoom: scale) }
    private func titleRect(_ id: String) -> CGRect {
        let r = rect(id), padding = titleOnly ? 4 / scale : 14
        return CGRect(x: r.minX + padding, y: r.minY + (titleOnly ? 3 / scale : 30),
                      width: r.width - 2 * padding, height: titleOnly ? 32 / scale : 43)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    func zoomTo(_ value: Double, anchor: CGPoint? = nil) {
        cancelHoverPreview()
        conditionsPopover?.close()
        commitTitle()
        guard let graph else { return }
        let anchor = anchor ?? CGPoint(x: bounds.midX, y: bounds.midY), before = world(anchor)
        let zoom = min(3, max(0.08, value))
        graph.updateCamera(zoom: zoom, offset: CGPoint(x: anchor.x - before.x * zoom, y: anchor.y - before.y * zoom))
        needsDisplay = true
    }
    func zoomBy(_ multiplier: Double) { zoomTo(scale * multiplier) }
    func fit(ids: Set<String>? = nil) {
        cancelHoverPreview()
        commitTitle()
        guard let graph else { return }
        let tasks = graph.visible(query: query).filter { ids == nil || ids!.contains($0.id) }
        guard let first = tasks.first, bounds.width > 100, bounds.height > 100 else { return }
        func fullRect(_ id: String) -> CGRect { CGRect(origin: graph.layout.positions[id]?.point ?? .zero, size: TaskGraphGeometry.size) }
        let area = tasks.dropFirst().reduce(fullRect(first.id)) { $0.union(fullRect($1.id)) }
        let zoom = min(1, max(0.08, min((bounds.width - 110) / max(1, area.width), (bounds.height - 100) / max(1, area.height))))
        graph.updateCamera(zoom: zoom, offset: CGPoint(x: bounds.midX - area.midX * zoom, y: bounds.midY - area.midY * zoom), persistImmediately: true)
        needsDisplay = true
    }
    override func magnify(with event: NSEvent) { zoomTo(scale * (1 + event.magnification), anchor: convert(event.locationInWindow, from: nil)) }
    override func scrollWheel(with event: NSEvent) {
        cancelHoverPreview()
        conditionsPopover?.close()
        commitTitle()
        if event.modifierFlags.contains(.command) { zoomTo(scale * exp(-event.scrollingDeltaY * 0.01), anchor: convert(event.locationInWindow, from: nil)) }
        else if let graph {
            let multiplier = event.hasPreciseScrollingDeltas ? 1.0 : 10.0
            graph.updateCamera(offset: CGPoint(x: offset.x + event.scrollingDeltaX * multiplier, y: offset.y + event.scrollingDeltaY * multiplier))
            needsDisplay = true
        }
    }
    private func text(_ string: String, rect: CGRect, size: Double = 12, color: NSColor = .labelColor, bold: Bool = false, wrap: Bool = false) {
        let style = NSMutableParagraphStyle(); style.lineBreakMode = wrap ? .byWordWrapping : .byTruncatingTail
        (string as NSString).draw(in: rect, withAttributes: [.font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: style])
    }
    private func curve(_ edge: GraphEdge) -> [CGPoint] {
        let a = rect(edge.from), b = rect(edge.to)
        if !edge.hierarchy && b.minX <= a.maxX + 40 { return TaskGraphGeometry.backwardPath(from: a, to: b) }
        if edge.hierarchy && b.minY <= a.maxY {
            let y = min(a.minY, b.minY) - 32
            return [CGPoint(x: a.midX, y: a.minY), CGPoint(x: a.midX, y: y), CGPoint(x: b.midX, y: y), CGPoint(x: b.midX, y: b.minY)]
        }
        let from = edge.hierarchy ? CGPoint(x: a.midX, y: a.maxY) : CGPoint(x: a.maxX, y: a.midY)
        let to = edge.hierarchy ? CGPoint(x: b.midX, y: b.minY) : CGPoint(x: b.minX, y: b.midY)
        let distance = max(60, abs(to.x - from.x) * 0.5)
        let c1 = edge.hierarchy ? CGPoint(x: from.x, y: from.y + 48) : CGPoint(x: from.x + distance, y: from.y)
        let c2 = edge.hierarchy ? CGPoint(x: to.x, y: to.y - 48) : CGPoint(x: to.x - distance, y: to.y)
        return (0...32).map { i in
            let t = Double(i) / 32, u = 1 - t
            return CGPoint(x: u*u*u*from.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*to.x,
                           y: u*u*u*from.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*to.y)
        }
    }
    /// World-space node and edge geometry survives a pan unchanged. Rebuild only
    /// when positions / semantic size / visible topology actually change.
    private func prepareGeometry(_ tasks: [Record]) {
        guard let graph else { return }
        let ids = tasks.map(\.id), edges = graph.edges(visible: Set(ids))
        let identity = ObjectIdentifier(graph)
        guard identity != cachedGraphID || cachedGeometryRevision != graph.geometryRevision ||
              cachedEdgeRevision != graph.edgeBuildCount || cachedGeometryScale != scale || cachedGeometryIDs != ids else { return }
        cachedGraphID = identity; cachedGeometryRevision = graph.geometryRevision
        cachedEdgeRevision = graph.edgeBuildCount; cachedGeometryScale = scale; cachedGeometryIDs = ids
        nodeRects = Dictionary(tasks.map { ($0.id, rect($0.id)) }, uniquingKeysWith: { a, _ in a })
        edgePaths = edges.map { ($0.0, $0.1, curve($0.0)) }
        edgeBounds = edgePaths.map { _, _, points in
            guard let first = points.first else { return .zero }
            return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }.insetBy(dx: -12 / scale, dy: -24 / scale)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let graph, let store, let c = NSGraphicsContext.current?.cgContext else { return }
        if !pageBackgroundVisible { NSColor.windowBackgroundColor.setFill(); bounds.fill() }
        let tasks = graph.visible(query: query), highlighted = graph.highlighted
        let dependencies = graph.dependencies, presentation = graph.presentation()
        prepareGeometry(tasks)
        c.saveGState(); c.translateBy(x: offset.x, y: offset.y); c.scaleBy(x: scale, y: scale)
        let viewport = CGRect(origin: world(.zero), size: CGSize(width: bounds.width / scale, height: bounds.height / scale))
        let step = max(32, 24 / scale)
        c.setFillColor(NSColor.separatorColor.withAlphaComponent(0.28).cgColor)
        for x in stride(from: floor(viewport.minX / step) * step, through: viewport.maxX, by: step) {
            for y in stride(from: floor(viewport.minY / step) * step, through: viewport.maxY, by: step) { c.fillEllipse(in: CGRect(x: x, y: y, width: 1 / scale, height: 1 / scale)) }
        }
        for (index, entry) in edgePaths.enumerated() where edgeBounds[index].intersects(viewport) {
            let (edge, originals, points) = entry
            let selected = graph.selectedEdge == edge
            let hot = highlighted.contains(edge.from) && highlighted.contains(edge.to)
            c.setAlpha(hot ? 1 : 0.12)
            let satisfied = originals.allSatisfy { dependencies.records[$0.from]?.status == "completed" }
            let color: NSColor = selected ? .systemYellow : (edge.hierarchy ? .tertiaryLabelColor : (satisfied ? .systemGreen : .systemBlue))
            c.setStrokeColor(color.cgColor); c.setLineWidth((selected ? 3 : 1.5) / scale)
            c.setLineDash(phase: 0, lengths: edge.hierarchy ? [5 / scale, 5 / scale] : [])
            c.addLines(between: points); c.strokePath(); c.setLineDash(phase: 0, lengths: [])
            if !edge.hierarchy, let tip = points.last {
                let prev = points[points.count - 2], angle = atan2(tip.y - prev.y, tip.x - prev.x), length = 9 / scale
                c.move(to: tip); c.addLine(to: CGPoint(x: tip.x - length * cos(angle - 0.5), y: tip.y - length * sin(angle - 0.5)))
                c.move(to: tip); c.addLine(to: CGPoint(x: tip.x - length * cos(angle + 0.5), y: tip.y - length * sin(angle + 0.5))); c.strokePath()
            }
            if originals.count > 1 {
                let mid = points[points.count / 2]; text("\(originals.count) 条", rect: CGRect(x: mid.x, y: mid.y - 20, width: 80, height: 22), size: 12 / scale, color: color)
            }
        }
        c.setAlpha(1)
        let pulse = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0.66 + 0.34 * sin(Date.timeIntervalSinceReferenceDate * .pi)
        for task in tasks where nodeRects[task.id]?.intersects(viewport.insetBy(dx: -24 / scale, dy: -24 / scale)) == true {
            let r = rect(task.id), selected = graph.selection.contains(task.id)
            let historyOpacity = task.isClosed && graph.completionFeedback[task.id] == nil && !selected ? 0.62 : 1.0
            let opacity = (highlighted.contains(task.id) ? 1 : 0.2) * historyOpacity
            c.saveGState(); c.setAlpha(opacity)
            let shape = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
            NSColor.controlBackgroundColor.setFill(); shape.fill()
            let detail = presentation[task.id]
            let conditions = detail?.conditions ?? [], pending = detail?.pending ?? []
            let blocked = !pending.isEmpty && !task.isClosed
            let readySignal = detail?.signalsReady == true
            let statusColor: NSColor = blocked ? .systemOrange : (TaskStatus(rawValue: task.status)?.color ?? .secondaryLabelColor)
            if !titleOnly { statusColor.withAlphaComponent(0.08).setFill(); shape.fill() }
            (selected ? NSColor.systemBlue : NSColor.separatorColor).setStroke(); shape.lineWidth = (selected ? 2.5 : 1) / scale; shape.stroke()
            if readySignal {
                NSColor.systemGreen.withAlphaComponent(pulse).setStroke()
                let glow = NSBezierPath(roundedRect: r.insetBy(dx: 3 / scale, dy: 3 / scale), xRadius: 10, yRadius: 10)
                glow.lineWidth = 2 / scale; glow.stroke()
            }
            let children = dependencies.children[task.id] ?? []
            if !titleOnly {
                text(store.title(for: task.taskSpace) + (task.isArchived ? " · 已归档" : ""), rect: CGRect(x: r.minX + 14, y: r.minY + 10, width: 190, height: 19), size: 11, color: .secondaryLabelColor)
                if !children.isEmpty {
                    let closed = children.filter { dependencies.records[$0]?.isClosed == true }.count
                    text("\(graph.layout.collapsed.contains(task.id) ? "▸" : "▾") \(closed)/\(children.count)", rect: CGRect(x: r.maxX - 70, y: r.minY + 8, width: 60, height: 20), color: .systemBlue, bold: true)
                }
            }
            if !globalOverview {
                text(task.title, rect: titleRect(task.id), size: titleOnly ? TaskGraphGeometry.titleScreenFontSize / scale : 16, bold: true, wrap: true)
            } else {
                // The location is still visible and hittable; the actual title is
                // drawn at screen size below for the hovered / selected task.
                statusColor.withAlphaComponent(0.8).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 3 / scale, dy: 2 / scale), xRadius: 2 / scale, yRadius: 2 / scale).fill()
            }
            let status = TaskStatus(rawValue: task.status)?.title ?? task.status
            if !titleOnly {
                let satisfied = conditions.filter(\.satisfied).count
                let stateLabel = blocked ? "\(status) · 阻断 \(pending.count) 项" : detail?.ready == true ? "\(status) · 可开始" : status
                text(stateLabel, rect: CGRect(x: r.minX + 14, y: r.minY + 78, width: satisfied > 0 ? r.width - 151 : r.width - 28, height: 19), size: 12, color: readySignal ? .systemGreen : statusColor)
                if satisfied > 0 {
                    let badge = satisfiedRect(task.id)
                    NSColor.systemGreen.withAlphaComponent(0.12).setFill(); NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
                    text("✓ 已满足 \(satisfied) 项 ›", rect: badge.insetBy(dx: 5, dy: 3), size: 11, color: .systemGreen, bold: true)
                }
                let area = conditionsRect(task.id)
                NSColor.secondaryLabelColor.withAlphaComponent(0.06).setFill()
                NSBezierPath(roundedRect: area.insetBy(dx: -4, dy: -2), xRadius: 5, yRadius: 5).fill()
                var row = 0
                for (kind, name) in [(TaskConditionKind.person, "等人"), (.time, "等时间"), (.task, "等任务")] {
                    let group = pending.filter { $0.kind == kind }
                    guard let first = group.first else { continue }
                    let label = kind == .time ? TaskDependencies.availableDate(task).map(Self.timeFormatter.string(from:)) ?? first.label : first.label
                    let count = group.count > 1 ? "（\(group.count) 项）" : ""
                    text("\(name)\(count)：\(label)", rect: CGRect(x: area.minX, y: area.minY + Double(row) * 20, width: area.width, height: 19), size: 12, color: .systemOrange)
                    row += 1
                }
                if row < 3 { text("\(conditions.isEmpty ? "＋ 设置阻断条件" : "管理条件 / 查看已满足")…", rect: CGRect(x: area.minX, y: area.minY + Double(row) * 20, width: area.width, height: 19), size: 11, color: .secondaryLabelColor) }
                if !task.text("codexThreadId").isEmpty { text("Codex ↗", rect: CGRect(x: r.minX + 14, y: r.maxY - 26, width: 90, height: 20), color: .systemBlue) }
                let footer = graph.completionFeedback[task.id] != nil && !graph.showClosed ? "✓ 即将收起" : task.isClosed ? "恢复待办" : "✓ 双击完成"
                text(footer, rect: CGRect(x: r.maxX - 108, y: r.maxY - 26, width: 96, height: 20), color: .secondaryLabelColor)
            }
            for x in [r.minX, r.maxX] where !globalOverview && (!titleOnly || selected || hoveredID == task.id || connection != nil) {
                let port = CGRect(x: x - 6 / scale, y: r.midY - 6 / scale, width: 12 / scale, height: 12 / scale)
                NSColor.controlBackgroundColor.setFill(); NSBezierPath(ovalIn: port).fill()
                NSColor.systemBlue.setStroke(); let border = NSBezierPath(ovalIn: port); border.lineWidth = 2 / scale; border.stroke()
            }
            c.restoreGState()
        }
        if let connection {
            let r = rect(connection.id), start = CGPoint(x: connection.output ? r.maxX : r.minX, y: r.midY)
            c.setStrokeColor(NSColor.systemBlue.cgColor); c.setLineWidth(2 / scale); c.setLineDash(phase: 0, lengths: [6 / scale, 4 / scale]); c.move(to: start); c.addLine(to: pointer); c.strokePath(); c.setLineDash(phase: 0, lengths: [])
        }
        if let marquee {
            c.setFillColor(NSColor.systemBlue.withAlphaComponent(0.12).cgColor); c.fill(marquee)
            c.setStrokeColor(NSColor.systemBlue.cgColor); c.setLineWidth(1 / scale); c.stroke(marquee)
        }
        c.restoreGState()
        drawOverviewTitle()
        if tasks.isEmpty { text("没有匹配的任务。右键空白处可新建任务。", rect: CGRect(x: 40, y: 40, width: 550, height: 35), size: 16, color: .secondaryLabelColor) }
        if graph.showMiniMap { drawMiniMap(tasks, context: c) } else { miniRect = .zero }
    }
    private func drawMiniMap(_ tasks: [Record], context c: CGContext) {
        guard let first = tasks.first, bounds.width > 400, bounds.height > 260 else { miniRect = .zero; return }
        miniRect = CGRect(x: bounds.maxX - 200, y: bounds.maxY - 138, width: 184, height: 122)
        let visible = CGRect(origin: world(.zero), size: CGSize(width: bounds.width / scale, height: bounds.height / scale))
        miniWorld = tasks.dropFirst().reduce(rect(first.id)) { $0.union(rect($1.id)) }.union(visible).insetBy(dx: -70, dy: -70)
        miniScale = min((miniRect.width - 16) / miniWorld.width, (miniRect.height - 16) / miniWorld.height)
        NSColor.controlBackgroundColor.withAlphaComponent(0.94).setFill(); NSBezierPath(roundedRect: miniRect, xRadius: 8, yRadius: 8).fill()
        func map(_ r: CGRect) -> CGRect { CGRect(x: miniRect.minX + 8 + (r.minX - miniWorld.minX) * miniScale, y: miniRect.minY + 8 + (r.minY - miniWorld.minY) * miniScale, width: r.width * miniScale, height: r.height * miniScale) }
        for task in tasks { (graph?.selection.contains(task.id) == true ? NSColor.systemBlue : NSColor.secondaryLabelColor.withAlphaComponent(0.45)).setFill(); map(rect(task.id)).fill() }
        c.setStrokeColor(NSColor.systemBlue.cgColor); c.setLineWidth(1.5); c.stroke(map(visible))
    }
    /// Readable detail lives in screen coordinates, never shrinks with the camera
    /// and never changes saved positions or the geometry of adjacent tasks.
    private func drawOverviewTitle() {
        guard titleOnly, hoverPanel?.isVisible != true, let graph,
              let id = graph.selection.count == 1 ? graph.selection.first : nil,
              nodeRects[id] != nil, let task = graph.byID[id] else { return }
        let node = rect(id), anchor = screen(CGPoint(x: node.midX, y: node.maxY))
        guard bounds.insetBy(dx: -20, dy: -20).contains(anchor) else { return }
        let width = min(380, max(120, bounds.width - 32))
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
        let titleHeight = ceil((task.title as NSString).boundingRect(with: CGSize(width: width - 24, height: 500), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.boldSystemFont(ofSize: 14), .paragraphStyle: paragraph]).height)
        let count = graph.presentation()[id]?.conditionCounts ?? ""
        let height = max(20, titleHeight) + (count.isEmpty ? 24 : 44)
        let x = min(max(12, anchor.x - width / 2), max(12, bounds.width - width - 12))
        let y = anchor.y + height + 12 < bounds.maxY ? anchor.y + 8 : max(12, screen(node.origin).y - height - 8)
        let panel = CGRect(x: x, y: y, width: width, height: height)
        NSColor.controlBackgroundColor.setFill(); NSBezierPath(roundedRect: panel, xRadius: 8, yRadius: 8).fill()
        NSColor.systemBlue.withAlphaComponent(0.75).setStroke()
        let outline = NSBezierPath(roundedRect: panel, xRadius: 8, yRadius: 8); outline.lineWidth = 1; outline.stroke()
        text(task.title, rect: CGRect(x: x + 12, y: y + 10, width: width - 24, height: titleHeight + 4), size: 14, bold: true, wrap: true)
        if !count.isEmpty { text(count, rect: CGRect(x: x + 12, y: panel.maxY - 25, width: width - 24, height: 18), size: 11, color: .systemOrange) }
    }
    func hit(_ point: CGPoint) -> String? { graph?.visible(query: query).reversed().first { rect($0.id).contains(point) }?.id }
    func satisfiedRect(_ id: String) -> CGRect {
        let r = rect(id)
        return CGRect(x: r.maxX - 132, y: r.minY + 76, width: 118, height: 21)
    }
    func conditionsRect(_ id: String) -> CGRect {
        let r = rect(id)
        return CGRect(x: r.minX + 14, y: r.minY + (titleOnly ? 65 : 102), width: r.width - 28, height: titleOnly ? 20 : 58)
    }
    func conditionKind(_ id: String, at point: CGPoint) -> TaskConditionKind? {
        guard !titleOnly, let graph, let task = graph.byID[id], conditionsRect(id).contains(point) else { return nil }
        let pending = graph.dependencies.pendingConditions(task)
        let kinds = TaskConditionKind.allCases.filter { kind in pending.contains { $0.kind == kind } }
        let row = Int((point.y - conditionsRect(id).minY) / 20)
        return kinds.indices.contains(row) ? kinds[row] : nil
    }
    func showConditions(_ id: String, kind: TaskConditionKind? = nil) {
        cancelHoverPreview()
        guard let store, let graph else { return }
        commitTitle(); conditionsPopover?.close()
        let popover = NSPopover(); popover.behavior = .transient
        let task = store.task(id)
        let initialKind = kind ?? task.flatMap { graph.dependencies.pendingConditions($0).first?.kind ?? graph.dependencies.conditions($0).first?.kind } ?? .person
        popover.contentViewController = NSHostingController(rootView: TaskConditionsPanel(store: store, id: id, kind: initialKind, resize: { [weak popover] size in popover?.contentSize = size }, close: { [weak popover] in popover?.close() }))
        popover.contentSize = TaskConditionsPanel.size(for: initialKind, task: task)
        conditionsPopover = popover
        let r = titleOnly ? rect(id) : conditionsRect(id)
        popover.show(relativeTo: CGRect(origin: screen(r.origin), size: CGSize(width: r.width * scale, height: r.height * scale)), of: self, preferredEdge: .maxX)
    }
    func port(_ point: CGPoint) -> (String, Bool)? {
        // At extreme overview sizes, connection hit targets would consume the
        // entire node. Preserve selection / drag and expose ports after zooming.
        guard !globalOverview else { return nil }
        if let graph { prepareGeometry(graph.visible(query: query)) }
        for (id, r) in nodeRects where !titleOnly || graph?.selection.contains(id) == true || hoveredID == id || connection != nil {
            for output in [false, true] where hypot(point.x - (output ? r.maxX : r.minX), point.y - r.midY) < 12 / scale { return (id, output) }
        }
        return nil
    }
    private func edge(at p: CGPoint) -> (GraphEdge, [GraphEdge])? {
        for (edge, original, points) in edgePaths.reversed() {
            for (a, b) in zip(points, points.dropFirst()) {
                let dx = b.x - a.x, dy = b.y - a.y
                let t = min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / max(0.001, dx*dx + dy*dy)))
                if hypot(p.x - a.x - t*dx, p.y - a.y - t*dy) < 7 / scale { return (edge, original) }
            }
        }
        return nil
    }
    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil), p = world(location)
        let hover = miniRect.contains(location) && graph?.showMiniMap == true ? nil : hit(p)
        if hoveredID != hover { hoveredID = hover; needsDisplay = true }
        if let (_, output) = port(p) {
            cancelHoverPreview(); toolTip = output ? "拖到后续任务左侧：本任务完成后才能开始它" : "拖到前置任务右侧：等待它完成"; NSCursor.crosshair.set()
        }
        else if !titleOnly, let id = hover, conditionsRect(id).contains(p) || satisfiedRect(id).contains(p) {
            toolTip = nil; NSCursor.pointingHand.set(); scheduleHoverPreview(id, at: location)
        } else {
            toolTip = hover == nil ? "双指滚动平移 · 捏合缩放 · 空白拖动框选 · 空格拖动画布 · 单击选中 · 双击标题改名 · 双击卡片其他区域打开详情" : nil
            NSCursor.arrow.set(); scheduleHoverPreview(hover, at: location)
        }
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) {
        hoveredID = nil; cancelHoverPreview(); toolTip = nil; needsDisplay = true
    }
    private func scheduleHoverPreview(_ id: String?, at point: CGPoint) {
        guard action.isEmpty, !spaceHeld, titleEditor == nil, conditionsPopover?.isShown != true,
              window?.isKeyWindow == true, !isHiddenOrHasHiddenAncestor else { cancelHoverPreview(); return }
        hoverScreenPoint = point
        guard hoverDwell.update(id, at: ProcessInfo.processInfo.systemUptime) else { return }
        hoverWork?.cancel(); hoverWork = nil; dismissHoverPanel()
        guard let id else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hoverDwell.ready(at: ProcessInfo.processInfo.systemUptime) == id else { return }
            self.showHoverPreview(id)
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + TaskGraphHoverDwell.delay, execute: work)
    }
    func cancelHoverPreview() {
        hoverWork?.cancel(); hoverWork = nil; hoverDwell.cancel(); hoverScreenPoint = nil
        dismissHoverPanel()
    }
    private func dismissHoverPanel() {
        if let panel = hoverPanel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
        hoverPanel = nil; hoverSummary = nil; needsDisplay = true
    }
    func refreshHoverPreview() {
        guard let id = hoverDwell.candidate else { return }
        guard let location = hoverScreenPoint, bounds.contains(location), hit(world(location)) == id,
              action.isEmpty, !spaceHeld, titleEditor == nil, conditionsPopover?.isShown != true,
              window?.isKeyWindow == true, !isHiddenOrHasHiddenAncestor else { cancelHoverPreview(); return }
        if hoverPanel?.isVisible == true { showHoverPreview(id) }
    }
    private func showHoverPreview(_ id: String) {
        guard let graph, let store, let window, window.isKeyWindow, let point = hoverScreenPoint,
              bounds.contains(point), hit(world(point)) == id, action.isEmpty, !spaceHeld,
              titleEditor == nil, conditionsPopover?.isShown != true, !isHiddenOrHasHiddenAncestor,
              let task = store.task(id) else { cancelHoverPreview(); return }
        let summary = TaskGraphHoverSummary(task: task, spaceTitle: store.title(for: task.taskSpace), dependencies: graph.dependencies)
        guard hoverPanel == nil || hoverSummary != summary else { return }
        dismissHoverPanel()
        let host = NSHostingView(rootView: TaskGraphHoverSummaryView(summary: summary))
        let size = NSSize(width: 360, height: min(450, max(160, host.fittingSize.height)))
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.hasShadow = true
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.contentView = host
        panel.level = .popUpMenu; panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = true
        panel.setAccessibilityLabel("任务概要")
        let anchor = window.convertPoint(toScreen: convert(point, to: nil))
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        var origin = CGPoint(x: anchor.x + 18, y: anchor.y - size.height - 14)
        if origin.x + size.width > visible.maxX - 10 { origin.x = anchor.x - size.width - 18 }
        if origin.y < visible.minY + 10 { origin.y = anchor.y + 18 }
        origin.x = max(visible.minX + 10, min(origin.x, visible.maxX - size.width - 10))
        origin.y = max(visible.minY + 10, min(origin.y, visible.maxY - size.height - 10))
        panel.setFrameOrigin(origin); window.addChildWindow(panel, ordered: .above); panel.orderFront(nil)
        hoverPanel = panel; hoverSummary = summary; needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        cancelHoverPreview()
        commitTitle(); window?.makeFirstResponder(self)
        guard let graph else { return }
        downScreen = convert(event.locationInWindow, from: nil); dragStart = world(downScreen); pointer = dragStart
        beforeDrag = graph.layout; moved = false; downID = nil; graph.selectedEdge = nil
        if graph.showMiniMap && miniRect.contains(downScreen) {
            let center = CGPoint(x: miniWorld.minX + (downScreen.x - miniRect.minX - 8) / miniScale, y: miniWorld.minY + (downScreen.y - miniRect.minY - 8) / miniScale)
            graph.updateCamera(offset: CGPoint(x: bounds.midX - center.x * scale, y: bounds.midY - center.y * scale), persistImmediately: true); action = ""; return
        }
        if spaceHeld || event.buttonNumber == 2 { action = "pan"; return }
        if let (id, output) = port(dragStart) { connection = (id, output); action = "link"; return }
        if let id = hit(dragStart), let task = store?.task(id) {
            let r = rect(id), relative = CGPoint(x: dragStart.x - r.minX, y: dragStart.y - r.minY)
            if !titleOnly, conditionsRect(id).contains(dragStart) {
                if event.clickCount == 1 { showConditions(id, kind: conditionKind(id, at: dragStart)) }
                action = ""; return
            }
            if !titleOnly, satisfiedRect(id).contains(dragStart), graph.dependencies.conditions(task).contains(where: \.satisfied) {
                if event.clickCount == 1 { showConditions(id, kind: graph.dependencies.conditions(task).first(where: \.satisfied)?.kind) }
                action = ""; return
            }
            if !titleOnly, relative.y < 31, relative.x > r.width - 80, graph.tasks.contains(where: { $0.text("parentId") == id }) { graph.collapse(id); action = ""; return }
            if !titleOnly, relative.y > r.height - 31 {
                action = ""
                if relative.x > r.width - 116 { if event.clickCount == 2 { store?.edit(id, "status", task.isClosed ? "ready" : "completed") }; return }
                if relative.x < 110, !task.text("codexThreadId").isEmpty { openCodex(task); return }
            }
            if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command) {
                if graph.selection.contains(id) { graph.selection.remove(id) } else { graph.selection.insert(id) }
            } else if !graph.selection.contains(id) || event.clickCount == 2 { graph.selection = [id] }
            dragIDs = graph.selection
            // A collapsed parent carries the invisible children with it.
            let children = graph.dependencies.children
            for selected in graph.selection where graph.layout.collapsed.contains(selected) { dragIDs.formUnion(TaskDependencies.reachable([selected], edges: children)) }
            downID = id; action = "move"
        } else if let (edge, originals) = edge(at: dragStart) {
            graph.selectedEdge = edge; action = ""
            graph.message = edge.hierarchy ? "父子关系：可在任务详情中修改父任务" : (originals.count > 1 ? "\(originals.count) 条汇总依赖，右键展开后编辑" : "依赖：完成前置后才能开始后续。按 Delete 解除，可撤销")
        } else {
            marqueeBase = event.modifierFlags.contains(.shift) ? graph.selection : []
            graph.selection = marqueeBase; marquee = CGRect(origin: dragStart, size: .zero); action = "marquee"
        }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        cancelHoverPreview()
        guard let graph, let old = beforeDrag else { return }
        let current = convert(event.locationInWindow, from: nil)
        moved = moved || hypot(current.x - downScreen.x, current.y - downScreen.y) > 4
        let p = world(current); pointer = p
        if action == "pan" { graph.updateCamera(offset: CGPoint(x: old.offset.x + current.x - downScreen.x, y: old.offset.y + current.y - downScreen.y)) }
        if action == "move", moved {
            var positions = graph.layout.positions
            for id in dragIDs { if let start = old.positions[id] { positions[id] = GraphPoint(CGPoint(x: start.x + p.x - dragStart.x, y: start.y + p.y - dragStart.y)) } }
            graph.layout.positions = positions
        }
        if action == "marquee" {
            let region = CGRect(x: min(p.x, dragStart.x), y: min(p.y, dragStart.y), width: abs(p.x - dragStart.x), height: abs(p.y - dragStart.y))
            marquee = region; graph.selection = marqueeBase.union(nodeRects.filter { $0.value.intersects(region) }.keys)
        }
        if action == "link", let connection {
            if let target = hit(p) ?? port(p)?.0, target != connection.id {
                let from = connection.output ? connection.id : target, to = connection.output ? target : connection.id
                let valid = graph.dependencies.canDepend(to, on: from)
                graph.message = valid ? "松开建立：完成 \(graph.byID[from]?.title ?? "") 后，才能开始 \(graph.byID[to]?.title ?? "")" : "不能建立：会形成循环依赖或父子死锁"
            }
        }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let graph else { return }
        let location = convert(event.locationInWindow, from: nil), p = world(location)
        let restingID = action == "move" && !moved && event.clickCount == 1 && hit(p) == downID ? downID : nil
        if action == "link", let connection, let target = port(p)?.0 ?? hit(p), target != connection.id, let store {
            let edge = GraphEdge(from: connection.output ? connection.id : target, to: connection.output ? target : connection.id)
            Task { await graph.link(edge, connected: true, store: store) }
        }
        if action == "move", moved, let old = beforeDrag { graph.checkpoint(old) }
        else if action == "move", !moved, let id = downID, hit(p) == id, graph.selection.count == 1,
                event.clickCount == 2, event.modifierFlags.intersection([.shift, .command, .control, .option]).isEmpty {
            // Resolve after mouse-up so dragging a title still moves the card.
            // A slight pointer drift out of the title must not open details.
            let titleArea = titleRect(id).insetBy(dx: -4, dy: -1)
            if titleOnly || titleArea.contains(dragStart) || titleArea.contains(p) {
                if let task = store?.task(id) { beginTitle(task) }
            } else {
                openDetail?(id)
            }
        }
        if action == "marquee", !moved { openDetail?(nil) }
        if action == "pan" { graph.persist() }
        action = ""; connection = nil; marquee = nil; downID = nil; beforeDrag = nil; needsDisplay = true
        if let restingID { scheduleHoverPreview(restingID, at: location) }
    }
    override func otherMouseDown(with event: NSEvent) { mouseDown(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseDragged(with: event) }
    override func otherMouseUp(with event: NSEvent) { mouseUp(with: event) }
    func beginTitle(_ task: Record) {
        cancelHoverPreview()
        if titleOnly {
            let current = rect(task.id)
            zoomTo(1, anchor: screen(CGPoint(x: current.midX, y: current.midY)))
        }
        let r = rect(task.id), start = screen(CGPoint(x: r.minX + 10, y: r.minY + 29))
        let editor = NSTextField(frame: CGRect(x: start.x, y: start.y, width: (r.width - 20) * scale, height: max(34, 44 * scale)))
        editor.stringValue = task.title; editor.font = .systemFont(ofSize: max(13, 16 * scale)); editor.maximumNumberOfLines = 2
        editor.isEditable = true; editor.isSelectable = true; editor.delegate = self
        editor.setAccessibilityLabel("编辑任务名称")
        editingID = task.id; titleEditor = editor; addSubview(editor)
        window?.makeFirstResponder(editor)
        editor.currentEditor()?.selectAll(nil)
    }
    func commitTitle() {
        guard let editor = titleEditor, let id = editingID else { return }
        let title = editor.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        titleEditor = nil; editingID = nil; editor.delegate = nil; editor.removeFromSuperview()
        if !title.isEmpty { store?.edit(id, "title", .string(title)) } else { graph?.message = "名称不能为空，已保留原名" }
        needsDisplay = true
    }
    func controlTextDidEndEditing(_ obj: Notification) { commitTitle() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { titleEditor?.delegate = nil; titleEditor?.removeFromSuperview(); titleEditor = nil; editingID = nil; window?.makeFirstResponder(self); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { commitTitle(); window?.makeFirstResponder(self); return true }
        return false
    }
    private func openCodex(_ task: Record) {
        let raw = task.text("codexThreadId")
        if let url = URL(string: raw.contains("://") ? raw : "codex://threads/\(raw)") { NSWorkspace.shared.open(url) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        cancelHoverPreview()
        commitTitle(); guard let graph, let store else { return nil }
        let p = world(convert(event.locationInWindow, from: nil)), menu = NSMenu(); menuActions = [:]
        func add(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
            let index = menuActions.count; menuActions[index] = action
            let item = NSMenuItem(title: title, action: #selector(runMenu(_:)), keyEquivalent: ""); item.target = self; item.tag = index; item.isEnabled = enabled; menu.addItem(item)
        }
        menu.autoenablesItems = false; menu.delegate = self
        if let id = hit(p), let task = store.task(id) {
            if !graph.selection.contains(id) { graph.selection = [id] }
            add("打开任务详情") { self.openDetail?(id) }
            add("修改名称") { self.beginTitle(task) }
            add("管理阻断条件（等人 / 等时间 / 等任务）…") { self.showConditions(id) }
            let satisfied = graph.satisfiedPredecessors(task).count
            if satisfied > 0 {
                add("\(graph.expandedSatisfied.contains(id) ? "收起" : "展开")已满足的 \(satisfied) 项前置") { graph.toggleSatisfied(id) }
            }
            add("添加子任务…") { self.createTask(parent: id, point: CGPoint(x: self.rect(id).maxX + 56, y: self.rect(id).minY)) }
            add("\(graph.layout.collapsed.contains(id) ? "展开" : "收起")子任务", enabled: graph.tasks.contains { $0.text("parentId") == id }) { graph.collapse(id) }
            menu.addItem(.separator())
            for mode in GraphTrace.allCases { add(mode.rawValue) { graph.selection = [id]; graph.trace = mode } }
            menu.addItem(.separator())
            for status in TaskStatus.allCases {
                let canStart = status != .active || store.blocked(task) == nil
                add("设为\(status.title)", enabled: task.status != status.rawValue && canStart) { store.edit(id, "status", .string(status.rawValue)) }
            }
            menu.addItem(.separator())
            add("修改截止日期 / 其他属性…") { self.openDetail?(id) }
            if !task.text("codexThreadId").isEmpty { add("打开 Codex 对话") { self.openCodex(task) } }
            add(task.isArchived ? "取消归档" : "归档") { store.edit(id, "archived", .bool(!task.isArchived)) }
            add("删除任务…") {
                let alert = NSAlert(); alert.messageText = "删除「\(task.title)」？"; alert.informativeText = "有子任务或依赖引用时需先解除关系。删除后可在归档与恢复中撤销。"
                alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "删除任务")
                if alert.runModal() == .alertSecondButtonReturn { Task { _ = await store.perform([["type": "task.delete", "id": .string(id)]], confirmed: true) } }
            }
        } else if let (edge, original) = edge(at: p) {
            graph.selectedEdge = edge
            if edge.hierarchy { add("编辑子任务的父任务…") { self.openDetail?(edge.to) } }
            else if original.count == 1 { add("解除依赖（保留任务）") { Task { await graph.link(original[0], connected: false, store: store) } } }
            else { add("展开这组依赖") { graph.layout.collapsed.remove(edge.from); graph.layout.collapsed.remove(edge.to); graph.persist() } }
        } else {
            add("新建任务…") { self.createTask(parent: nil, point: p) }
            add("定位全部任务") { self.fit() }
            add("以当前视野为中心就近整理") { graph.arrangeNearby(query: self.query) }
            add("按依赖分层整理") { graph.arrange() }
        }
        needsDisplay = true; return menu
    }
    @objc private func runMenu(_ sender: NSMenuItem) {
        let action = menuActions[sender.tag]; menuActions.removeAll(); action?()
    }
    func menuDidClose(_ menu: NSMenu) {
        DispatchQueue.main.async { [weak self] in self?.menuActions.removeAll() }
    }
    private func createTask(parent: String?, point: CGPoint) {
        guard let store, let graph else { return }
        let alert = NSAlert(); alert.messageText = parent == nil ? (graph.space == .personal ? "新建私人任务" : "新建任务") : "添加子任务"
        alert.addButton(withTitle: "创建"); alert.addButton(withTitle: "取消")
        let input = NSTextField(frame: CGRect(x: 0, y: 38, width: 360, height: 28)); input.placeholderString = "任务名称"
        let accessory = NSView(frame: CGRect(x: 0, y: 0, width: 360, height: 70)); accessory.addSubview(input)
        let spaces = graph.creationSpaces(parent: parent, available: store.taskSpaces)
        guard !spaces.isEmpty else { return }
        let pages = NSPopUpButton(frame: CGRect(x: 0, y: 0, width: 360, height: 28)); pages.addItems(withTitles: spaces.map { store.title(for: $0) }); pages.isEnabled = spaces.count > 1; accessory.addSubview(pages)
        alert.accessoryView = accessory; alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn, !input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let title = input.stringValue, space = spaces[max(0, pages.indexOfSelectedItem)]
        Task {
            if let id = await store.createTask(title: title, parent: parent, space: space) {
                graph.layout.positions[id] = GraphPoint(point); graph.selection = [id]
                if let parent { graph.layout.collapsed.remove(parent) }
                graph.persist(); self.openDetail?(id)
            }
        }
    }
    override func keyDown(with event: NSEvent) {
        cancelHoverPreview()
        guard let graph, let store else { return }
        if event.keyCode == 49 { spaceHeld = true; NSCursor.openHand.set(); return }
        if event.keyCode == 53 { connection = nil; marquee = nil; action = ""; graph.selection = []; graph.selectedEdge = nil; openDetail?(nil); needsDisplay = true; return }
        if [51, 117].contains(event.keyCode), let edge = graph.selectedEdge, !edge.hierarchy {
            if let entry = edgePaths.first(where: { $0.0 == edge }), entry.1.count == 1 { Task { await graph.link(entry.1[0], connected: false, store: store) } }
            else { graph.message = "请先右键展开汇总依赖，再解除具体连线" }; return
        }
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": graph.selection = Set(graph.visible(query: query).map(\.id))
            case "z": Task { await graph.undo(store: store) }
            case "0": fit()
            default: super.keyDown(with: event)
            }
        } else { super.keyDown(with: event) }
    }
    override func keyUp(with event: NSEvent) { if event.keyCode == 49 { spaceHeld = false; NSCursor.arrow.set() } else { super.keyUp(with: event) } }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.contains(.command), ["a", "z", "0"].contains(event.charactersIgnoringModifiers?.lowercased() ?? "") else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event); return true
    }
}
