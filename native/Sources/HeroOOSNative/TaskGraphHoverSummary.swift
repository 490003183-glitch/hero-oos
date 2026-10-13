import SwiftUI
import OOSCore

/// A small, read-only projection of the hovered task. Never carries the source record,
/// free-form notes, paths, credentials or unrelated task records into the tooltip.
struct TaskGraphHoverSummary: Equatable {
    struct Field: Equatable, Identifiable {
        let id: String
        let title: String
        let value: String
    }
    struct ConditionGroup: Equatable, Identifiable {
        let id: String
        let title: String
        let value: String
        let count: Int
    }

    static let backgroundCharacterLimit = 350
    let taskID: String
    let title: String
    let spaceTitle: String
    let status: String
    let statusTitle: String
    let background: String
    let backgroundIsEmpty: Bool
    let backgroundIsTruncated: Bool
    let conditionGroups: [ConditionGroup]
    let conditionHeading: String
    let emptyConditionsText: String
    let fields: [Field]

    init(task: Record, spaceTitle: String, dependencies: TaskDependencies, at now: Date = Date()) {
        taskID = task.id
        title = Self.preview(task.title, limit: 120).text
        self.spaceTitle = Self.preview(spaceTitle, limit: 40).text
        status = task.status
        statusTitle = TaskStatus(rawValue: task.status)?.title ?? "未设置状态"
        let source = task.text("background").trimmingCharacters(in: .whitespacesAndNewlines)
        backgroundIsEmpty = source.isEmpty
        let backgroundPreview = Self.preview(source, limit: Self.backgroundCharacterLimit, lines: 8)
        background = source.isEmpty ? "未填写任务基础背景" : backgroundPreview.text
        backgroundIsTruncated = backgroundPreview.truncated

        let pending = dependencies.pendingConditions(task, at: now)
        conditionGroups = TaskConditionKind.allCases.compactMap { kind in
            let conditions = pending.filter { $0.kind == kind }
            guard !conditions.isEmpty else { return nil }
            let heading: String
            switch kind {
            case .person: heading = "等人"
            case .time: heading = "等时间"
            case .task: heading = "等任务"
            }
            let labels = conditions.prefix(2).map { condition -> String in
                if kind == .time { return "尚未到可开始时间" }
                if kind == .task {
                    let id = String(condition.id.dropFirst("task:".count))
                    // A missing / no-longer-visible predecessor must not expose a raw ID.
                    guard dependencies.records[id] != nil else { return "前置任务不可用" }
                }
                return condition.label
            }
            var value = labels.joined(separator: "；")
            if conditions.count > labels.count { value += "；另 \(conditions.count - labels.count) 项" }
            return ConditionGroup(id: kind.rawValue, title: heading,
                                  value: Self.preview(value, limit: 100, lines: 2).text,
                                  count: conditions.count)
        }
        conditionHeading = task.isClosed ? "保留的未解除条件" : "当前阻断"
        if task.isClosed { emptyConditionsText = "任务已结束" }
        else if dependencies.readyToBegin(task, at: now) { emptyConditionsText = "无未解除条件 · 可开始" }
        else { emptyConditionsText = "无未解除的阻断条件" }

        var projected: [Field] = []
        if let value = Self.dateText(task.text("availableAt"), kind: .availableAt) {
            projected.append(Field(id: "availableAt", title: "可开始", value: value))
        }
        if let value = Self.dateText(task.text("due"), kind: .due) {
            projected.append(Field(id: "due", title: "截止", value: value))
        }
        for (key, name) in [("project", "项目"), ("nextAction", "当前待办")] {
            let value = task.text(key).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { projected.append(Field(id: key, title: name, value: Self.preview(value, limit: 100, lines: 1).text)) }
        }
        fields = projected
    }

    /// Space goes to the conditions/dates when there are many; the tooltip never
    /// becomes an unscrollable full inspector or steals mouse input from the card.
    var isDense: Bool { conditionGroups.count + fields.count > 4 }
    var conditionLineLimit: Int { isDense ? 1 : 2 }
    var backgroundLineLimit: Int { max(3, 8 - max(0, conditionGroups.count + fields.count - 2)) }

    private static func preview(_ value: String, limit: Int, lines: Int = .max) -> (text: String, truncated: Bool) {
        let rows = value.components(separatedBy: .newlines)
        let lineLimited = rows.prefix(lines).joined(separator: "\n")
        let truncated = rows.count > lines || lineLimited.count > limit
        return (String(lineLimited.prefix(limit)) + (truncated ? "…" : ""), truncated)
    }

    private static func dateText(_ text: String, kind: TaskAgenda.Kind) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        // Reuse the agenda's strict public projection, not Foundation's permissive
        // date normalization. The isolated record prevents the other date's
        // priority or the original task's closed state from hiding this field.
        let dateOnlyRecord = Record(["id": "hover-date", "status": "ready", kind.rawValue: .string(value)])
        guard let milestone = TaskAgenda.entries(tasks: [dateOnlyRecord]).first?.milestones.first else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = milestone.isAllDay ? "yyyy/MM/dd" : "yyyy/MM/dd HH:mm"
        return formatter.string(from: milestone.date)
    }
}

/// Intentionally has no buttons, links, scrolling or text selection. The parent
/// panel ignores mouse events so a double click still reaches the original card.
struct TaskGraphHoverSummaryView: View {
    let summary: TaskGraphHoverSummary

    var body: some View {
        VStack(alignment: .leading, spacing: summary.isDense ? 8 : 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(summary.spaceTitle).lineLimit(1).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(summary.statusTitle).foregroundStyle(statusColor)
                }.font(.system(size: 12, weight: .medium))
                Text(summary.title).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("任务基础背景").fontWeight(.semibold)
                    Spacer()
                    if !summary.backgroundIsEmpty {
                        Text(summary.backgroundIsTruncated ? "已截取概要" : "概要预览")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.font(.system(size: 12))
                Text(summary.background).font(.system(size: 13)).lineSpacing(2)
                    .foregroundStyle(summary.backgroundIsEmpty ? Color.secondary : Color.primary)
                    .lineLimit(summary.backgroundLineLimit).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(summary.conditionHeading).font(.system(size: 12, weight: .semibold))
                if summary.conditionGroups.isEmpty {
                    Text(summary.emptyConditionsText).font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    ForEach(summary.conditionGroups) { group in
                        HStack(alignment: .top, spacing: 6) {
                            Text("\(group.title) \(group.count)").foregroundStyle(.orange).frame(width: 61, alignment: .leading)
                            Text(group.value).lineLimit(summary.conditionLineLimit).fixedSize(horizontal: false, vertical: true)
                        }.font(.system(size: 12))
                    }
                }
            }
            if !summary.fields.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(summary.fields) { field in
                        HStack(alignment: .top, spacing: 6) {
                            Text(field.title).foregroundStyle(.secondary).frame(width: 61, alignment: .leading)
                            Text(field.value).lineLimit(1)
                        }
                    }
                }.font(.system(size: 12))
            }
            Text("双击标题改名 · 双击卡片其他区域查看详情")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
        .frame(maxHeight: 450, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.16), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .allowsHitTesting(false)
    }

    private var statusColor: Color {
        TaskStatus(rawValue: summary.status).map { Color(nsColor: $0.color) } ?? .secondary
    }
}
