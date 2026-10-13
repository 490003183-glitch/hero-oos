import SwiftUI

/// A task's time condition (or fallback deadline) is a date marker, not an
/// appointment with an invented duration. Editing uses the source task.
struct TaskAgendaRow: View {
    @EnvironmentObject var store: OOSStore
    let entry: TaskAgenda.Entry
    let open: () -> Void

    var body: some View {
        let dependencies = TaskDependencies(store.tasks)
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(entry.milestones) { milestone in
                    if milestone.isAllDay { Text("全天") }
                    else { Text(milestone.date, style: .time).monospacedDigit() }
                }
                Text(entry.milestones.first?.kind == .availableAt ? "阻断日期" : "截止日期").font(.caption).foregroundStyle(.secondary)
            }.font(.callout).frame(width: 80, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.task.title).font(.headline)
                HStack(spacing: 10) {
                    Label(entry.milestones.first?.kind == .availableAt ? "可开始时间" : "任务截止日", systemImage: "clock")
                    if entry.task.taskSpace == .personal { Label("私人", systemImage: "person.crop.circle") }
                }.font(.caption).foregroundStyle(.secondary)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if let blocked = dependencies.blocked(entry.task, at: context.date) {
                        Text(blocked).font(.caption).foregroundStyle(.orange)
                    } else if entry.milestones.first?.kind == .availableAt {
                        Text("时间条件已满足 · 不会自动开始任务").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            StatusLabel(status: entry.task.status)
            Button(action: open) { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless).help("打开任务，修改阻断日期或截止日期")
        }.padding(.vertical, 12).contentShape(Rectangle()).taskDetailClickTarget()
            .onTapGesture(perform: open)
    }
}
