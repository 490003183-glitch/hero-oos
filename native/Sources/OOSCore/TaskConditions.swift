import Foundation

/// Explicit human acknowledgements, independent of task status and dependency edges.
public enum TaskPeopleWaits {
    public static func entries(_ task: Record) -> [Record] {
        if case .array = task["peopleWaits"] { return task["peopleWaits"].records }
        let legacy = task.text("blockedBy").trimmingCharacters(in: .whitespacesAndNewlines)
        return legacy.isEmpty ? [] : [Record(["id": "legacy-blocked-by", "person": .string(legacy), "outcome": "", "resolved": false])]
    }
    public static func label(_ entry: Record) -> String {
        let person = entry.text("person"), outcome = entry.text("outcome")
        return outcome.isEmpty ? person : "\(person) · \(outcome)"
    }
    public static func summary(_ task: Record) -> String {
        entries(task).filter { !$0["resolved"].bool }.map(label).joined(separator: "；")
    }
    /// Mirror the legacy ledger field only on an explicit edit, never on read/startup.
    /// Old clients editing blockedBy still replace the human-wait list intentionally.
    public static func normalized(_ fields: JSON, current: Record? = nil) throws -> JSON {
        var result = fields
        if fields.object.keys.contains("peopleWaits") {
            guard case .array(let entries) = fields["peopleWaits"] else {
                throw RuntimeError("invalid_people_waits", "等人条件必须是列表，清除时请使用空列表。")
            }
            var ids = Set<String>()
            for entry in entries {
                guard case .object = entry, !entry["id"].trimmed.isEmpty, ids.insert(entry["id"].string).inserted,
                      !entry["person"].trimmed.isEmpty, case .string = entry["outcome"], case .bool = entry["resolved"] else {
                    throw RuntimeError("invalid_people_waits", "每项等人条件需要独立 ID、等谁、等待结果文字及明确的解决状态。")
                }
            }
            result["blockedBy"] = .string(summary(Record(result.object)))
        } else if fields.object.keys.contains("blockedBy"), let current, case .array = current["peopleWaits"], fields["blockedBy"].string != summary(current) {
            let record = Record(["blockedBy": fields["blockedBy"]])
            result["peopleWaits"] = .array(entries(record).map(\.json))
        }
        return result
    }
}

public enum TaskConditionKind: String, CaseIterable { case person, time, task }
public struct TaskCondition: Identifiable, Equatable {
    public let id: String
    public let kind: TaskConditionKind
    public let label: String
    public let satisfied: Bool
}

extension TaskDependencies {
    public func conditions(_ task: Record, at now: Date = Date()) -> [TaskCondition] {
        var result = TaskPeopleWaits.entries(task).map {
            TaskCondition(id: "person:\($0.id)", kind: .person, label: TaskPeopleWaits.label($0), satisfied: $0["resolved"].bool)
        }
        if let date = Self.availableDate(task) {
            result.append(TaskCondition(id: "time", kind: .time, label: task.text("availableAt"), satisfied: date <= now))
        }
        var seen = Set<String>()
        for id in task["dependsOn"].array.map(\.string) where seen.insert(id).inserted {
            let upstream = records[id]
            let label = upstream.map { ($0.status == "cancelled" ? "前置已放弃：" : "") + $0.title } ?? "前置任务缺失：\(id)"
            result.append(TaskCondition(id: "task:\(id)", kind: .task, label: label, satisfied: upstream?.status == "completed"))
        }
        return result
    }
    public func pendingConditions(_ task: Record, at now: Date = Date()) -> [TaskCondition] {
        conditions(task, at: now).filter { !$0.satisfied }
    }
    public func readyToBegin(_ task: Record, at now: Date = Date()) -> Bool {
        // A legacy waiting/review item with only prose is not evidence that its wait is over.
        task.isExecutionTracked && task.status != "active" && pendingConditions(task, at: now).isEmpty &&
        (task.status == "ready" || !conditions(task, at: now).isEmpty)
    }
    public func shouldSignalReady(_ task: Record, at now: Date = Date()) -> Bool {
        !conditions(task, at: now).isEmpty && readyToBegin(task, at: now)
    }
    public func conditionCounts(_ task: Record, at now: Date = Date()) -> String {
        let pending = pendingConditions(task, at: now)
        return [(TaskConditionKind.person, "人"), (.time, "时间"), (.task, "任务")].compactMap { kind, name in
            let count = pending.filter { $0.kind == kind }.count
            return count > 0 ? "\(name) \(count)" : nil
        }.joined(separator: " · ")
    }
}
