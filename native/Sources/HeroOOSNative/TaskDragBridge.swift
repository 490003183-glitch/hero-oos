import SwiftUI
import AppKit

struct TaskDragBridge: NSViewRepresentable {
    let task: Record
    var select: () -> Void
    var rename: () -> Void
    var canAccept: (String) -> Bool
    var accept: (String, Bool) -> Bool
    var hover: (Bool, Bool) -> Void
    func makeNSView(context: Context) -> TaskDragView { TaskDragView() }
    func updateNSView(_ view: TaskDragView, context: Context) {
        view.task = task; view.selectTask = select; view.renameTask = rename; view.canAccept = canAccept; view.accept = accept; view.hover = hover
    }
}

struct TaskColumnDropBridge: NSViewRepresentable {
    var canAccept: (String) -> Bool
    var accept: (String, Bool) -> Bool
    func makeNSView(context: Context) -> TaskDropView { TaskDropView() }
    func updateNSView(_ view: TaskDropView, context: Context) {
        view.canAccept = canAccept; view.accept = accept
    }
}

class TaskDropView: NSView {
    private static let targets = NSHashTable<TaskDropView>.weakObjects()
    var canAccept: ((String) -> Bool)?
    var accept: ((String, Bool) -> Bool)?
    var hover: ((Bool, Bool) -> Void)?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); Self.targets.add(self) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func insertsBefore(_ windowPoint: NSPoint) -> Bool {
        windowPoint.y > convert(bounds, to: nil).midY
    }
    static func containsDropPoint(_ point: NSPoint, bounds: NSRect, visibleRect: NSRect) -> Bool {
        bounds.intersection(visibleRect).contains(point)
    }

    static func target(at point: NSPoint, in window: NSWindow?, source: TaskDragView) -> TaskDropView? {
        guard let window else { return nil }
        let hits = targets.allObjects.filter {
            $0.window === window && !$0.isHiddenOrHasHiddenAncestor &&
            containsDropPoint($0.convert(point, from: nil), bounds: $0.bounds, visibleRect: $0.visibleRect)
        }
        // A row takes precedence over the enclosing column's empty-area drop zone.
        if let row = hits.first(where: { $0 is TaskDragView }) {
            return row !== source && row.canAccept?(source.task.id) == true ? row : nil
        }
        return hits.first { $0.canAccept?(source.task.id) == true }
    }
}

enum TaskDoubleClickContinuation {
    private static var monitor: Any?
    static func matches(count: Int, elapsed: TimeInterval, distance: CGFloat, interval: TimeInterval) -> Bool {
        count == 2 && elapsed >= 0 && elapsed <= interval && distance <= 8
    }
    private static func clear() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
    static func arm(after click: NSEvent, rename: @escaping () -> Void) {
        clear()
        let point = click.locationInWindow, timestamp = click.timestamp
        var consumeMouseUp = false
        // Details can move the row before the second click; keep that click tied to its original task.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown]) { [weak firstWindow = click.window] event in
            if consumeMouseUp {
                clear()
                return event.type == .leftMouseUp ? nil : event
            }
            guard event.type != .leftMouseUp else { return event }
            let delta = event.locationInWindow
            guard firstWindow != nil, event.window === firstWindow, event.type == .leftMouseDown,
                  matches(count: event.clickCount, elapsed: event.timestamp - timestamp,
                          distance: hypot(delta.x - point.x, delta.y - point.y), interval: NSEvent.doubleClickInterval) else {
                clear(); return event
            }
            consumeMouseUp = true; rename(); return nil
        }
    }
}

final class TaskDragView: TaskDropView {
    var task = Record()
    var selectTask: (() -> Void)?
    var renameTask: (() -> Void)?
    private var start: NSPoint?
    private var dragging = false
    private weak var destination: TaskDropView?
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden ? nil : (frame.contains(point) ? self : nil)
    }
    override func mouseDown(with event: NSEvent) {
        start = event.locationInWindow; dragging = false
    }
    override func mouseUp(with event: NSEvent) {
        if dragging {
            if let target = Self.target(at: event.locationInWindow, in: window, source: self) {
                _ = target.accept?(task.id, target.insertsBefore(event.locationInWindow))
            }
            destination?.hover?(false, false); destination = nil
            NSCursor.pop()
        } else {
            handleClick(count: event.clickCount)
            if event.clickCount == 1, let renameTask { TaskDoubleClickContinuation.arm(after: event, rename: renameTask) }
        }
        start = nil; dragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = event.locationInWindow
        if !dragging {
            guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
            dragging = true; NSCursor.closedHand.push()
        }
        let target = Self.target(at: point, in: window, source: self)
        if destination !== target { destination?.hover?(false, false); destination = target }
        if let target { target.hover?(true, target.insertsBefore(point)) }
        _ = target?.enclosingScrollView?.contentView.autoscroll(with: event)
    }
    func handleClick(count: Int) {
        if count == 2 { renameTask?() } else { selectTask?() }
    }
}
