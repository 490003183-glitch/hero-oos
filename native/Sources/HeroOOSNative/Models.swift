import Foundation
import AppKit

@_exported import OOSCore
typealias Record = OOSCore.Record

enum TaskViewMode: Int, CaseIterable, Identifiable {
    case list, board, graph
    var id: Int { rawValue }
    var title: String {
        switch self { case .list: return "列表"; case .board: return "看板"; case .graph: return "关系图" }
    }
    var symbol: String {
        switch self { case .list: return "list.bullet"; case .board: return "rectangle.split.3x1"; case .graph: return "point.3.connected.trianglepath.dotted" }
    }
    static func available(for space: TaskSpace) -> [Self] { space == .personal ? [.list, .board, .graph] : [.list, .board] }
}

enum TaskViewPreferences {
    static let workKey = "HeroOOS.tasks.work.defaultView"
    static let personalKey = "HeroOOS.tasks.personal.defaultView"
    static func key(for space: TaskSpace) -> String { "HeroOOS.tasks.\(space.rawValue).defaultView" }
    static func mode(for space: TaskSpace, defaults: UserDefaults = .standard) -> TaskViewMode {
        let key = key(for: space)
        guard let raw = defaults.object(forKey: key) as? Int, let mode = TaskViewMode(rawValue: raw),
              TaskViewMode.available(for: space).contains(mode) else { return .board }
        return mode
    }
}

enum TaskStatus: String, CaseIterable, Identifiable {
    case ready, active, waiting, review, backlog, blocked, paused, information, completed, cancelled
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ready: return "待办"
        case .active: return "进行中"
        case .waiting: return "等待"
        case .review: return "待确认"
        case .backlog: return "暂未排期"
        case .blocked: return "前置阻塞"
        case .paused: return "暂停"
        case .information: return "只知情"
        case .completed: return "已完成"
        case .cancelled: return "已放弃"
        }
    }
    var symbol: String {
        switch self {
        case .ready: return "circle"
        case .active: return "play.circle.fill"
        case .waiting: return "clock"
        case .review: return "questionmark.circle"
        case .backlog: return "tray"
        case .blocked: return "lock.circle"
        case .paused: return "pause.circle"
        case .information: return "info.circle"
        case .completed: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle"
        }
    }
    var color: NSColor {
        switch self {
        case .active: return .systemTeal
        case .waiting: return .systemOrange
        case .review: return .systemPink
        case .completed: return .systemGreen
        default: return .secondaryLabelColor
        }
    }
}

enum NativeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let v) = self { return v }; return nil }
}

struct APIError: LocalizedError {
    var code: String
    var payload: JSON
    var errorDescription: String? { payload["message"].string.isEmpty ? code : payload["message"].string }
}

enum Dates {
    static func day(_ date: Date = Date()) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }
    static func parse(_ text: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: text) { return d }
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"; return day.date(from: text)
    }
    static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}

enum Merge {
    // Only fields changed locally participate, so independent external edits survive.
    static func patch(base: Record, remote: Record, changes: [String: JSON]) throws -> [String: JSON] {
        for (key, value) in changes where remote[key] != base[key] && remote[key] != value {
            throw NativeError.message("「\(remote.title)」的 \(key) 已被另一端修改。你的输入已保留，请核对后再保存。")
        }
        return changes
    }
}

enum Relations {
    // Walk reverse edges once per menu, instead of rebuilding the graph for every candidate.
    static func choices(for task: Record, tasks: [Record]) -> (parents: [Record], dependencies: [Record]) {
        func dependents(links: (Record) -> [String]) -> Set<String> {
            var reverse: [String: [String]] = [:]
            for record in tasks {
                for id in links(record) where !id.isEmpty { reverse[id, default: []].append(record.id) }
            }
            var visited = Set<String>(), queue = [task.id]
            while let id = queue.popLast() {
                guard visited.insert(id).inserted else { continue }
                queue.append(contentsOf: reverse[id] ?? [])
            }
            return visited
        }
        let graph = TaskDependencies(tasks)
        let downstream = dependents { graph.requirements[$0.id] ?? [] }
        let existing = Set(task["dependsOn"].array.map(\.string))
        let candidates = tasks.filter { $0.taskSpace == task.taskSpace }
        return (candidates.filter { (!$0.isClosed || $0.id == task.text("parentId")) && graph.canParent(task.id, under: $0.id) },
                tasks.filter { !$0.id.isEmpty && !downstream.contains($0.id) && !existing.contains($0.id) })
    }
    static func reaches(_ start: String, _ target: String, tasks: [Record], links: (Record) -> [String]) -> Bool {
        let records = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var queue = [start]; var seen = Set<String>()
        while let id = queue.popLast() {
            if id == target { return true }
            guard seen.insert(id).inserted, let record = records[id] else { continue }
            queue.append(contentsOf: links(record).filter { !$0.isEmpty })
        }
        return false
    }
    static func canParent(_ id: String, under parent: String, tasks: [Record]) -> Bool {
        TaskDependencies(tasks).canParent(id, under: parent)
    }
    static func canDepend(_ id: String, on upstream: String, tasks: [Record]) -> Bool {
        TaskDependencies(tasks).canDepend(id, on: upstream)
    }
    private static func sameSpace(_ id: String, _ other: String, tasks: [Record]) -> Bool {
        guard let task = tasks.first(where: { $0.id == id }), let linked = tasks.first(where: { $0.id == other }) else { return true }
        return task.taskSpace == linked.taskSpace
    }
    static func canMove(_ id: String, to space: TaskSpace, tasks: [Record]) -> Bool {
        guard let task = tasks.first(where: { $0.id == id }) else { return false }
        let outgoing = Set([task.text("parentId")])
        return !tasks.contains { other in
            other.id != id && other.taskSpace != space &&
            (outgoing.contains(other.id) || other.text("parentId") == id)
        }
    }
}

extension NSColor {
    convenience init(hex: String) {
        let n = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(srgbRed: Double((n >> 16) & 255) / 255, green: Double((n >> 8) & 255) / 255, blue: Double(n & 255) / 255, alpha: 1)
    }
    var hex: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}
