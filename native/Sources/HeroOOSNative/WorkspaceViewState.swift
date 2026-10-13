import Foundation

/// Local presentation preferences only. Never part of task or cloud data.
struct WorkspaceViewState: Codable, Equatable {
    var pageKey = "tasks"
    var selectedTaskID: String?
    var searches: [String: String] = [:]
    var modes: [String: Int] = [:]
    var sidebarHidden = false

    var page: Page { Page(persistenceKey: pageKey) ?? .progress }
    var pageSearches: [Page: String] {
        searches.reduce(into: [:]) { result, entry in
            if let page = Page(persistenceKey: entry.key) { result[page] = entry.value }
        }
    }
    func mode(for space: TaskSpace, defaults: UserDefaults = .standard) -> TaskViewMode {
        if let raw = modes[space.rawValue], let mode = TaskViewMode(rawValue: raw), TaskViewMode.available(for: space).contains(mode) { return mode }
        return TaskViewPreferences.mode(for: space, defaults: defaults)
    }
    func validated(pageIDs: Set<String>, tasks: [Record]) -> Self {
        var result = self
        if case .taskPage(let space) = page, !pageIDs.contains(space.rawValue) { result.pageKey = "tasks" }
        if let id = result.selectedTaskID {
            if let task = tasks.first(where: { $0.id == id }), result.page.taskSpace == nil || result.page.taskSpace == task.taskSpace { }
            else { result.selectedTaskID = nil }
        }
        return result
    }
    static func key(for identity: String) -> String { "HeroOOS.workspaceView.v1." + identity }
    static func preferenceKey(_ name: String, identity: String) -> String { key(for: identity) + "." + name }
    static func load(identity: String, defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: key(for: identity)),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func save(identity: String, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key(for: identity))
    }
}

extension Page {
    var persistenceKey: String {
        switch self {
        case .today: return "today"
        case .plan: return "plan"
        case .tracks: return "tracks"
        case .progress: return "tasks"
        case .personal: return "personal"
        case .ledger: return "ledger"
        case .graph: return "graph"
        case .focus: return "focus"
        case .collage: return "collage"
        case .recovery: return "recovery"
        case .shared: return "shared"
        case .account: return "account"
        case .taskPage(let space): return "task-page:" + space.rawValue
        }
    }
    init?(persistenceKey: String) {
        if let page = Self.allCases.first(where: { $0.persistenceKey == persistenceKey }) { self = page }
        else if persistenceKey == "shared" { self = .progress }
        else if persistenceKey.hasPrefix("task-page:"),
                let space = TaskSpace(rawValue: String(persistenceKey.dropFirst("task-page:".count))), space.isCustom {
            self = .taskPage(space)
        } else { return nil }
    }
}
