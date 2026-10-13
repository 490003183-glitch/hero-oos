import SwiftUI
import AppKit

extension View {
    func taskDetailClickTarget() -> some View { background(TaskDetailClickTarget()) }
}

private struct TaskDetailClickTarget: NSViewRepresentable {
    func makeNSView(context: Context) -> DetailProtectedView { DetailProtectedView() }
    func updateNSView(_ view: DetailProtectedView, context: Context) {}
}

final class DetailProtectedView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

enum DetailClickPolicy {
    static func isBlank(at point: NSPoint, in root: NSView, hit: NSView?) -> Bool {
        func isProtected(_ view: NSView) -> Bool {
            guard !view.isHiddenOrHasHiddenAncestor else { return false }
            let localPoint = view.convert(point, from: root)
            if view is DetailProtectedView,
               view.bounds.intersection(view.visibleRect).contains(localPoint) { return true }
            if let split = view as? NSSplitView, split.bounds.intersection(split.visibleRect).contains(localPoint) {
                let frames = split.arrangedSubviews.filter { !$0.isHidden }.map(\.frame).sorted {
                    split.isVertical ? $0.minX < $1.minX : $0.minY < $1.minY
                }
                for (before, after) in zip(frames, frames.dropFirst()) {
                    let coordinate = split.isVertical ? localPoint.x : localPoint.y
                    let start = split.isVertical ? before.maxX : before.maxY
                    let end = split.isVertical ? after.minX : after.minY
                    if coordinate >= start - 3 && coordinate <= end + 3 { return true }
                }
            }
            return view.subviews.contains(where: isProtected)
        }
        guard !isProtected(root) else { return false }
        var current = hit
        while let view = current {
            if let table = view as? NSTableView {
                if table.row(at: table.convert(point, from: root)) >= 0 { return false }
                current = table.superview; continue
            }
            if view is NSControl || view is NSTextView || view is NSScroller || view is NSTableHeaderView { return false }
            current = view.superview
        }
        return true
    }
}

struct BlankAreaDismissal: NSViewRepresentable {
    var enabled: Bool
    var dismiss: () -> Void
    func makeNSView(context: Context) -> BlankAreaMonitor { BlankAreaMonitor() }
    func updateNSView(_ view: BlankAreaMonitor, context: Context) {
        view.enabled = enabled; view.dismiss = dismiss
    }
    static func dismantleNSView(_ view: BlankAreaMonitor, coordinator: ()) { view.stop() }
}

final class BlankAreaMonitor: NSView {
    var enabled = false
    var dismiss: (() -> Void)?
    private var monitor: Any?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); stop()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, self.enabled, let window = self.window, event.window === window,
                  window.attachedSheet == nil, let root = window.contentView,
                  self.bounds.intersection(self.visibleRect).contains(self.convert(event.locationInWindow, from: nil)) else { return event }
            let point = root.convert(event.locationInWindow, from: nil)
            let hit = root.hitTest(point)
            if DetailClickPolicy.isBlank(at: point, in: root, hit: hit) {
                // Let the original click and text-field commit finish before removing the detail view.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.enabled else { return }
                    self.dismiss?()
                }
            }
            return event
        }
    }
    func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
