import Foundation

public struct TaskSpace: RawRepresentable, Hashable, CaseIterable, Identifiable, Sendable {
    public let rawValue: String
    public init?(rawValue: String) {
        guard rawValue == "work" || rawValue == "personal" ||
              (rawValue.hasPrefix("page-") && UUID(uuidString: String(rawValue.dropFirst(5))) != nil) else { return nil }
        self.rawValue = rawValue
    }
    public static let work = TaskSpace(rawValue: "work")!
    public static let personal = TaskSpace(rawValue: "personal")!
    public static let allCases: [TaskSpace] = [.work, .personal]
    public var isCustom: Bool { self != .work && self != .personal }
    public var id: String { rawValue }
    public var title: String { self == .personal ? "私人任务" : (isCustom ? "任务页" : "任务") }
    public var symbol: String { self == .personal ? "person.crop.circle" : (isCustom ? "list.bullet.rectangle" : "checklist") }
    public func contains(_ task: Record) -> Bool { task.taskSpace == self }
    public func matches(_ task: Record, status: String, track: String, query: String) -> Bool {
        contains(task) && !task.isArchived &&
        (status == "all" || (status == "open" ? task.isOpen : task.status == status)) &&
        (track == "all" || task.text("trackId") == track) && StudioLedger.matches(task, query: query)
    }
}

extension Record {
    // Existing records remain in the original task area without a data migration.
    public var taskSpace: TaskSpace { TaskSpace(rawValue: text("taskSpace")) ?? .work }
}
