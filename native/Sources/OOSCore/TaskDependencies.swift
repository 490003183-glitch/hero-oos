import Foundation

public enum TaskTimePhase: Equatable {
    case none, upcoming, waitingForPredecessors, waitingForPeople, ready, inactive
}

/// Completion requirements include explicit predecessors and the parent's child-closure rule.
public struct TaskDependencies {
    public let records: [String: Record]
    public let children: [String: [String]]
    public let requirements: [String: [String]]
    public init(_ tasks: [Record]) {
        records = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let kids = Dictionary(grouping: tasks.filter { !$0.text("parentId").isEmpty }, by: { $0.text("parentId") }).mapValues { $0.map(\.id) }
        children = kids
        requirements = Dictionary(tasks.map { ($0.id, $0["dependsOn"].array.map(\.string) + (kids[$0.id] ?? [])) }, uniquingKeysWith: { a, _ in a })
    }
    public static func reachable(_ seeds: Set<String>, edges: [String: [String]]) -> Set<String> {
        var seen = Set<String>(), queue = Array(seeds)
        while let id = queue.popLast() {
            guard seen.insert(id).inserted else { continue }
            queue.append(contentsOf: edges[id] ?? [])
        }
        return seen
    }
    public func canDepend(_ id: String, on upstream: String) -> Bool {
        guard records[id] != nil, records[upstream] != nil, id != upstream else { return false }
        return !Self.reachable([upstream], edges: requirements).contains(id)
    }
    public func canParent(_ id: String, under parent: String) -> Bool {
        guard !parent.isEmpty else { return true }
        guard let task = records[id], let target = records[parent], task.taskSpace == target.taskSpace, id != parent else { return false }
        var edges = requirements
        let old = task.text("parentId")
        if !old.isEmpty { edges[old] = (edges[old] ?? []).filter { $0 != id } + (records[old]?["dependsOn"].array.map(\.string).filter { $0 == id } ?? []) }
        return !Self.reachable([id], edges: edges).contains(parent)
    }
    public func unmet(_ task: Record) -> [String] {
        task["dependsOn"].array.map(\.string).filter { records[$0]?.status != "completed" }
    }
    public static func availableDate(_ task: Record) -> Date? {
        let value = task.text("availableAt")
        return value.isEmpty ? nil : RuntimeDate.parse(value)
    }
    public func timePhase(_ task: Record, at now: Date = Date()) -> TaskTimePhase {
        guard let date = Self.availableDate(task) else { return .none }
        guard !task.isClosed, !task.isArchived, !["active", "paused", "information"].contains(task.status) else { return .inactive }
        if date > now { return .upcoming }
        if !TaskPeopleWaits.entries(task).filter({ !$0["resolved"].bool }).isEmpty { return .waitingForPeople }
        return unmet(task).isEmpty ? .ready : .waitingForPredecessors
    }
    public func blocked(_ task: Record, at now: Date = Date()) -> String? {
        let pending = pendingConditions(task, at: now)
        guard !pending.isEmpty else { return nil }
        return pending.map { condition in
            switch condition.kind {
            case .person: return "等人：\(condition.label)"
            case .time: return "尚未到可开始时间"
            case .task: return "等任务：\(condition.label)"
            }
        }.joined(separator: "；")
    }
    public func validateCompletionGraph() throws {
        var done = Set<String>()
        for id in records.keys where !done.contains(id) {
            var visiting = Set<String>(), stack: [(String, Bool)] = [(id, false)]
            while let (current, exiting) = stack.popLast() {
                if exiting { visiting.remove(current); done.insert(current); continue }
                if visiting.contains(current) {
                    throw RuntimeError("relationship_cycle", "「\(records[current]?.title ?? current)」形成循环依赖（含父任务等待子任务完成），请解除其中一条关系。")
                }
                if done.contains(current) { continue }
                visiting.insert(current); stack.append((current, true))
                stack.append(contentsOf: (requirements[current] ?? []).map { ($0, false) })
            }
        }
    }
}
