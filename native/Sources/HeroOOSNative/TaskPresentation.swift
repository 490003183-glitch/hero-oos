import SwiftUI
import AppKit

struct TaskDetailLayout<Content: View, Detail: View>: View {
    let expanded: Bool
    @ViewBuilder var content: () -> Content
    @ViewBuilder var detail: () -> Detail
    @AppStorage("HeroOOS.taskDetail.heightRatio") private var ratio = 0.62
    @State private var dragStart: Double?
    var body: some View {
        GeometryReader { geometry in
            let available = max(1, geometry.size.height - 8)
            let height = min(max(240, available * min(0.85, max(0.35, ratio))), max(240, available - 140))
            VStack(spacing: 0) {
                content().frame(maxWidth: .infinity, maxHeight: .infinity)
                if expanded {
                    Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.45))
                        .frame(height: 8)
                        .overlay(Capsule().fill(.secondary).frame(width: 44, height: 3))
                        .contentShape(Rectangle()).taskDetailClickTarget()
                        .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            if dragStart == nil { dragStart = height }
                            ratio = min(0.85, max(0.35, (dragStart! - value.translation.height) / available))
                        }.onEnded { _ in dragStart = nil })
                        .accessibilityLabel("调整任务详情高度")
                    detail().frame(height: height).taskDetailClickTarget()
                }
            }
        }
    }
}

struct TaskContextMenu: View {
    @EnvironmentObject var store: OOSStore
    let task: Record
    var mode: TaskViewMode = .list
    var didHide: () -> Void = {}
    var body: some View {
        Button {
            store.edit(task.id, "archived", .bool(!task.isArchived)); didHide()
        } label: { Label(task.isArchived ? "取消归档" : "归档任务", systemImage: "archivebox") }
        Button(role: .destructive) {
            let alert = NSAlert(); alert.messageText = "删除「\(task.title)」？"
            alert.informativeText = "删除后可在“归档与恢复”的操作记录中撤销。有子任务或依赖引用时需先解除关联。"
            alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "删除任务")
            if alert.runModal() == .alertSecondButtonReturn {
                Task { if await store.perform([["type": "task.delete", "id": .string(task.id)]], confirmed: true) { didHide() } }
            }
        } label: { Label("删除任务", systemImage: "trash") }
        Button {
            Task { _ = await store.perform([["type": "task.complete", "id": .string(task.id)]]) }
        } label: { Label("已完成", systemImage: "checkmark.circle") }.disabled(task.status == "completed")
        if !task.isArchived {
            Divider()
            Button { move("last") } label: { Label("移到末尾", systemImage: "arrow.down.to.line") }
            Button { move("first") } label: { Label("移到最前", systemImage: "arrow.up.to.line") }
        }
    }
    private func move(_ placement: String) {
        Task { _ = await store.moveTask(task.id, mode: mode, placement: placement) }
    }
}

struct TaskBlankMenu: View {
    @EnvironmentObject var store: OOSStore
    var body: some View {
        Button { NotificationCenter.default.post(name: .newTask, object: nil) } label: { Label("新建任务", systemImage: "plus") }
        Button { Task { await store.refresh() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
    }
}

struct TaskDropTarget: ViewModifier {
    @EnvironmentObject var store: OOSStore
    let task: Record
    let mode: TaskViewMode
    @Binding var renaming: Bool
    var select: () -> Void
    @State private var targeted = false
    @State private var insertBefore = true
    func body(content: Content) -> some View {
        content
            .overlay { if !renaming { TaskDragBridge(task: task, select: select, rename: { renaming = true }, canAccept: { id in
                guard let source = store.task(id) else { return false }
                return source.taskSpace == task.taskSpace && (mode == .board || source.text("parentId") == task.text("parentId"))
            }, accept: { id, before in
                guard let source = store.task(id), source.taskSpace == task.taskSpace,
                      mode == .board || source.text("parentId") == task.text("parentId") else { return false }
                Task { _ = await store.moveTask(id, mode: mode, placement: before ? "before" : "after", anchor: task.id, status: mode == .board ? task.status : nil) }
                return true
            }, hover: { active, before in targeted = active; insertBefore = before }) } }
            .overlay(alignment: insertBefore ? .top : .bottom) {
                if targeted { Rectangle().fill(Color.accentColor).frame(height: 3).allowsHitTesting(false) }
            }
    }
}

extension OOSStore {
    func displayOrdered(_ items: [Record], mode: TaskViewMode) -> [Record] {
        TaskOrdering.sorted(ranked(items), mode: mode == .board ? "board" : "list")
    }
    @discardableResult func moveTask(_ id: String, mode: TaskViewMode, placement: String, anchor: String? = nil, status: String? = nil) async -> Bool {
        guard let item = task(id) else { return false }
        var operation: JSON = ["type": "task.reorder", "id": .string(id), "mode": mode == .board ? "board" : "list", "placement": .string(placement),
                               "seedIds": .array(ranked(tasks.filter { $0.taskSpace == item.taskSpace }).map { .string($0.id) })]
        if let anchor { operation["anchorId"] = .string(anchor) }
        if let status { operation["status"] = .string(status) }
        return await perform([operation])
    }
}
