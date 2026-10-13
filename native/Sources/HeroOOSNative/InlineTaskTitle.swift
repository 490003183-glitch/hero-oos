import SwiftUI
import AppKit

extension Notification.Name {
    static let commitInlineTaskTitle = Notification.Name("HeroOOS.commitInlineTaskTitle")
}

struct TaskTitleDraft {
    let original: String
    var text: String
    init(_ title: String) { original = title; text = title }
    func change(cancelled: Bool = false) -> String? {
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return cancelled || title.isEmpty || title == original ? nil : title
    }
}

struct InlineTaskTitle: View {
    @EnvironmentObject var store: OOSStore
    let task: Record
    @Binding var editing: Bool
    @State private var draft: TaskTitleDraft?
    @FocusState private var focused: Bool
    var body: some View {
        Group {
            if editing {
                TextField("任务名称", text: Binding(get: { draft?.text ?? task.title }, set: { draft?.text = $0 }))
                    .textFieldStyle(.roundedBorder).focused($focused)
                    .accessibilityLabel("编辑任务名称")
                    .onAppear { draft = TaskTitleDraft(task.title) }
                    .task { await Task.yield(); focused = true }
                    .onSubmit { finish() }
                    .onExitCommand { finish(cancelled: true) }
                    .onChange(of: focused) { wasFocused, isFocused in
                        if wasFocused && !isFocused { finish() }
                    }
                    .background(TitleOutsideClick { finish() })
                    .onDisappear { finish() }
            } else {
                Text(task.title).lineLimit(3)
            }
        }.fontWeight(task.status == "active" ? .bold : .medium)
            .onReceive(NotificationCenter.default.publisher(for: .commitInlineTaskTitle)) { _ in finish() }
    }
    private func finish(cancelled: Bool = false) {
        guard let current = draft else { return }
        draft = nil
        if let title = current.change(cancelled: cancelled) { store.edit(task.id, "title", .string(title)) }
        editing = false; focused = false
    }
}

private struct TitleOutsideClick: NSViewRepresentable {
    let commit: () -> Void
    func makeNSView(context: Context) -> TitleClickMonitor { TitleClickMonitor() }
    func updateNSView(_ view: TitleClickMonitor, context: Context) { view.commit = commit }
    static func dismantleNSView(_ view: TitleClickMonitor, coordinator: ()) { view.stop() }
}

private final class TitleClickMonitor: NSView {
    var commit: (() -> Void)?
    private var monitor: Any?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); stop()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, event.window === self.window,
                  !self.bounds.intersection(self.visibleRect).contains(self.convert(event.locationInWindow, from: nil)) else { return event }
            DispatchQueue.main.async { [weak self] in self?.commit?() }
            return event
        }
    }
    func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
