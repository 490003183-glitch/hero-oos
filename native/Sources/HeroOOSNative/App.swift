import SwiftUI
import AppKit

@main struct HeroOOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var workspace = CloudWorkspace()
    @StateObject private var account = CloudAccount()
    @StateObject private var updates = UpdateManager()
    @State private var restoredAccount = false
    var body: some Scene {
        Window("Hero OOS", id: "main") {
            RootView(workspaceIdentity: workspace.store.api.draftIdentity).id(workspace.store.api.draftIdentity)
                .environmentObject(workspace.store).environmentObject(workspace.collage)
                .environmentObject(account).environmentObject(workspace)
                .frame(minWidth: 960, minHeight: 620)
                .task {
                    guard !restoredAccount else { return }
                    await account.restoreSession(validateInBackground: true)
                    restoredAccount = true
                }
                .task(id: restoredAccount ? (account.identityKey ?? "local") : "restoring") {
                    guard restoredAccount else { return }
                    await workspace.activate(account: account)
                    delegate.store = workspace.store; delegate.collage = workspace.collage
                    updates.start()
                }
                .onChange(of: ObjectIdentifier(workspace.store)) { _, _ in delegate.store = workspace.store; delegate.collage = workspace.collage }
        }
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建任务") { NotificationCenter.default.post(name: .newTask, object: nil) }.keyboardShortcut("n")
            }
            CommandGroup(after: .saveItem) {
                Button("立即保存") {
                    NotificationCenter.default.post(name: .commitInlineTaskTitle, object: nil)
                    Task { _ = await workspace.store.flush(); _ = await workspace.collage.save(); await workspace.sync?.synchronize(); await workspace.personalSync?.synchronize() }
                }.keyboardShortcut("s")
                Button("刷新") { Task { await workspace.store.refresh(); await workspace.collage.load() } }.keyboardShortcut("r")
            }
            CommandGroup(after: .appInfo) { Button("检查更新…") { updates.check() }.disabled(!updates.canCheck) }
            CommandGroup(after: .sidebar) {
                Divider()
                Button("页面背景…") { NotificationCenter.default.post(name: .configurePageBackground, object: nil) }
            }
        }
        Settings {
            Group {
                if workspace.matches(account: account) { SettingsView().environmentObject(workspace.store).environmentObject(updates) }
                else { Text("工作区切换尚未完成，请先回到账号与组织页面处理。").padding(30) }
            }
        }
    }
}

extension Notification.Name { static let newTask = Notification.Name("HeroOOS.newTask") }

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: OOSStore?
    weak var collage: CollageStore?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        NotificationCenter.default.post(name: .commitInlineTaskTitle, object: nil)
        if collage?.importing == true {
            let alert = NSAlert(); alert.messageText = "图片仍在导入"; alert.informativeText = "导入完成后再退出，避免中断当前操作。"; alert.addButton(withTitle: "返回"); alert.runModal()
            return .terminateCancel
        }
        guard store?.hasUnsavedChanges == true || collage?.dirty == true else { return .terminateNow }
        Task {
            let taskSaved = await store?.flush() ?? true
            let canvasSaved = await collage?.save() ?? true
            if taskSaved && canvasSaved { sender.reply(toApplicationShouldTerminate: true) }
            else {
                let alert = NSAlert(); alert.messageText = "仍有更改未保存"
                alert.informativeText = "未同步的编辑已保存在本机。保留草稿退出后，下次打开将继续尝试同步。"
                alert.addButton(withTitle: "返回"); alert.addButton(withTitle: "保留草稿并退出")
                sender.reply(toApplicationShouldTerminate: alert.runModal() == .alertSecondButtonReturn)
            }
        }
        return .terminateLater
    }
}

enum Page: Hashable, CaseIterable, Identifiable {
    case today, plan, tracks, progress, personal, ledger, graph, focus, collage, recovery, shared, account
    case taskPage(TaskSpace)
    static let allCases: [Page] = [.today, .plan, .tracks, .progress, .personal, .ledger, .graph, .focus, .collage, .recovery, .account]
    static func tasks(in space: TaskSpace) -> Page {
        space == .work ? .progress : (space == .personal ? .personal : .taskPage(space))
    }
    var rawValue: String {
        switch self {
        case .today: return "今日"
        case .plan: return "日程"
        case .tracks: return "板块"
        case .progress: return "任务"
        case .personal: return "私人任务"
        case .ledger: return "工作室台账"
        case .graph: return "任务关系图"
        case .focus: return "专注画布"
        case .collage: return "拼图"
        case .recovery: return "归档与恢复"
        case .shared: return "组织共享任务"
        case .account: return "账号与组织"
        case .taskPage(let space): return space.rawValue
        }
    }
    var id: String { rawValue }
    var taskSpace: TaskSpace? {
        switch self { case .progress: return .work; case .personal: return .personal; case .taskPage(let space): return space; default: return nil }
    }
    var symbol: String {
        switch self {
        case .today: return "sun.max"
        case .plan: return "calendar"
        case .tracks: return "square.grid.2x2"
        case .progress: return "checklist"
        case .personal: return "person.crop.circle"
        case .ledger: return "tablecells"
        case .graph: return "point.3.connected.trianglepath.dotted"
        case .focus: return "rectangle.3.group"
        case .collage: return "photo.on.rectangle.angled"
        case .recovery: return "archivebox"
        case .shared: return "person.2"
        case .account: return "person.crop.circle.badge.checkmark"
        case .taskPage: return "list.bullet.rectangle"
        }
    }
}

struct RootView: View {
    let workspaceIdentity: String
    @StateObject private var backgrounds: PageBackgroundStore
    @State private var configuringBackground = false
    @EnvironmentObject var store: OOSStore
    @EnvironmentObject var collage: CollageStore
    @EnvironmentObject var account: CloudAccount
    @EnvironmentObject var workspace: CloudWorkspace
    @State private var page: Page? = .progress
    @State private var selected: String?
    @State private var searches: [Page: String] = [:]
    @State private var newTask = false
    @State private var newTitle = ""
    @State private var parent: String?
    @State private var creating = false
    @State private var workMode = TaskViewPreferences.mode(for: .work)
    @State private var personalMode = TaskViewPreferences.mode(for: .personal)
    @State private var customModes: [TaskSpace: TaskViewMode] = [:]
    @State private var editingPage: Record?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var hasActivated = false
    @AppStorage(TaskViewPreferences.workKey) private var workDefault = TaskViewMode.board
    @AppStorage(TaskViewPreferences.personalKey) private var personalDefault = TaskViewMode.board
    init(workspaceIdentity: String) {
        self.workspaceIdentity = workspaceIdentity
        _backgrounds = StateObject(wrappedValue: PageBackgroundStore(identity: workspaceIdentity))
        let saved = WorkspaceViewState.load(identity: workspaceIdentity)
        _page = State(initialValue: saved.page)
        _selected = State(initialValue: saved.selectedTaskID)
        _searches = State(initialValue: saved.pageSearches)
        _workMode = State(initialValue: saved.mode(for: .work))
        _personalMode = State(initialValue: saved.mode(for: .personal))
        _customModes = State(initialValue: Dictionary(uniqueKeysWithValues: saved.modes.compactMap { key, value in
            guard let space = TaskSpace(rawValue: key), space.isCustom, let mode = TaskViewMode(rawValue: value),
                  TaskViewMode.available(for: space).contains(mode) else { return nil }
            return (space, mode)
        }))
        _columnVisibility = State(initialValue: saved.sidebarHidden ? .detailOnly : .all)
    }
    private var viewState: WorkspaceViewState {
        var modes = Dictionary(uniqueKeysWithValues: customModes.map { ($0.key.rawValue, $0.value.rawValue) })
        modes[TaskSpace.work.rawValue] = workMode.rawValue
        modes[TaskSpace.personal.rawValue] = personalMode.rawValue
        return WorkspaceViewState(pageKey: (page ?? .progress).persistenceKey, selectedTaskID: selected,
            searches: Dictionary(uniqueKeysWithValues: searches.map { ($0.key.persistenceKey, $0.value) }),
            modes: modes, sidebarHidden: columnVisibility == .detailOnly)
    }
    private func persistView() {
        guard hasActivated, store.api.draftIdentity == workspaceIdentity else { return }
        viewState.save(identity: workspaceIdentity)
    }
    private func validateRestoredView() {
        // An empty store during sign-in is not evidence that a saved page/task was deleted.
        guard workspaceAccessible, store.api.draftIdentity == workspaceIdentity else { return }
        let valid = viewState.validated(pageIDs: Set(store.taskPages.map(\.id)), tasks: store.tasks)
        page = valid.page; selected = valid.selectedTaskID
        hasActivated = true
        persistView()
    }
    private var search: String { searches[page ?? .progress, default: ""] }
    private var searchBinding: Binding<String> {
        Binding(get: { search }, set: { searches[page ?? .progress] = $0 })
    }
    private var creationSpace: TaskSpace {
        parent.flatMap { store.task($0)?.taskSpace } ?? page?.taskSpace ?? .work
    }
    private var pageTitle: String { page?.taskSpace.map { store.title(for: $0) } ?? (page ?? .progress).rawValue }
    private var pageBackground: PageBackgroundConfiguration? { backgrounds.effective(for: (page ?? .progress).persistenceKey) }
    private var pageBackgroundImage: NSImage? { pageBackground.flatMap { backgrounds.image(for: $0) } }
    private var hasPageBackground: Bool { (pageBackground?.opacity ?? 0) > 0 && pageBackgroundImage != nil }
    private var backgroundPages: [PageBackgroundChoice] {
        Page.allCases.flatMap { item in
            var choices = [PageBackgroundChoice(id: item.persistenceKey, title: item.rawValue)]
            if item == .personal {
                choices += store.taskPages.compactMap { record in
                    guard let space = TaskSpace(rawValue: record.id) else { return nil }
                    return PageBackgroundChoice(id: Page.taskPage(space).persistenceKey, title: record.title)
                }
            }
            return choices
        }
    }
    private var accountPage: Bool { page == .account || page == .shared }
    private var workspaceAccessible: Bool { workspace.matches(account: account) }
    private func refreshCurrentPage() {
        let refreshCollage = page == .collage
        Task { await store.refresh(); if refreshCollage { await collage.load() } }
    }
    private func mode(for space: TaskSpace) -> Binding<TaskViewMode> {
        Binding(get: { customModes[space] ?? TaskViewPreferences.mode(for: space) }, set: { customModes[space] = $0 })
    }
    private var sidebar: some View {
            List(selection: $page) {
                Section {
                    ForEach(Page.allCases) { item in
                        Label(item.rawValue, systemImage: item.symbol).tag(item)
                        if item == .personal && workspaceAccessible {
                            ForEach(store.taskPages) { taskPage in
                                if let space = TaskSpace(rawValue: taskPage.id) {
                                    Label(taskPage.title, systemImage: space.symbol).lineLimit(2).tag(Page.taskPage(space))
                                        .contextMenu {
                                            Button { editingPage = taskPage } label: { Label("重命名", systemImage: "pencil") }
                                            Button(role: .destructive) { deletePage(taskPage) } label: { Label("删除空任务页", systemImage: "trash") }
                                                .disabled(store.tasks.contains { $0.taskSpace == space })
                                        }
                                }
                            }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                HStack {
                    Text(Bundle.main.object(forInfoDictionaryKey: "HeroOOSRoot") == nil ? "HERO OOS" : "HERO OOS · 测试环境")
                        .font(.headline).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button { editingPage = Record() } label: { Image(systemName: "plus.square").frame(width: 22, height: 22) }
                        .buttonStyle(.borderless).help("添加任务页").accessibilityLabel("添加任务页").disabled(!workspaceAccessible)
                }.padding(.horizontal, 16).padding(.vertical, 12)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 230)
            .safeAreaInset(edge: .bottom) {
                WorkspaceSyncFooter { page = .account }
            }
    }
    private var pageDetail: some View {
            VStack(spacing: 0) {
                if workspaceAccessible, let error = store.error {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(error).font(.callout).textSelection(.enabled)
                        Spacer()
                        if store.conflictTaskID != nil { Button("核对冲突") { store.resolveConflict() } }
                        Button("重试保存") { Task { _ = await store.flush() } }
                        Button { store.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("关闭提示")
                    }.padding(12).background(Color.orange.opacity(0.1))
                }
                if !workspaceAccessible && page != .account {
                    VStack(spacing: 14) {
                        if workspace.switching { ProgressView("正在安全切换工作区…") }
                        if let error = workspace.error { Text(error).foregroundStyle(.orange) }
                        Button("账号与组织") { page = .account }
                        Button("重试加载工作区") { Task { await workspace.activate(account: account) } }.disabled(workspace.switching)
                    }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                TaskDetailLayout(expanded: selected.flatMap { store.task($0) } != nil && page != .collage && !accountPage) {
                    selectedPageContent.frame(maxWidth: .infinity, maxHeight: .infinity)
                } detail: {
                    if let id = selected, page != .collage, !accountPage, let task = store.task(id), page?.taskSpace == nil || page?.taskSpace == task.taskSpace {
                        TaskInspector(id: id, close: { selected = nil }, addChild: {
                            parent = id; newTitle = ""; newTask = true
                        }).id(id)
                    }
                }
                }
            }
            .scrollContentBackground(hasPageBackground ? .hidden : .automatic)
            .environment(\.pageBackgroundVisible, hasPageBackground)
            .background {
                if hasPageBackground { PageBackgroundLayer(image: pageBackgroundImage, configuration: pageBackground) }
            }
            .navigationTitle(pageTitle)
            .modifier(WorkspaceSearch(text: searchBinding, enabled: !accountPage, prompt: page == .personal ? "搜索私人任务" : "搜索任务"))
            .toolbar {
                ToolbarItemGroup {
                    if !accountPage {
                        Button { parent = nil; newTitle = ""; newTask = true } label: { Image(systemName: "plus") }.help(page == .personal ? "新建私人任务" : "新建任务").disabled(!workspaceAccessible)
                        Button(action: refreshCurrentPage) { Image(systemName: "arrow.clockwise") }.help("刷新").disabled(!workspaceAccessible)
                    }
                }
            }
    }
    @ViewBuilder private var selectedPageContent: some View {
        switch page ?? .progress {
        case .today: TodayView(selected: $selected)
        case .plan: PlanView(selected: $selected, workspaceIdentity: workspaceIdentity)
        case .tracks: TracksView(selected: $selected, search: search)
        case .progress: TasksView(selected: $selected, search: search, space: .work, mode: $workMode, workspaceIdentity: workspaceIdentity).id(TaskSpace.work)
        case .personal: TasksView(selected: $selected, search: search, space: .personal, mode: $personalMode, workspaceIdentity: workspaceIdentity).id(TaskSpace.personal)
        case .taskPage(let space): TasksView(selected: $selected, search: search, space: space, mode: mode(for: space), workspaceIdentity: workspaceIdentity).id(space)
        case .ledger: LedgerView(selected: $selected, search: search, workspaceIdentity: workspaceIdentity)
        case .graph: TaskGraphWorkspace(selected: $selected, search: search)
        case .focus: FocusView(selected: $selected)
        case .collage: CollageWorkspace()
        case .recovery: RecoveryView(selected: $selected, search: search, workspaceIdentity: workspaceIdentity)
        case .shared: Text("非私人任务已直接同步到当前组织，请在任务或任务关系图中管理。")
        case .account: CloudAccountView()
        }
    }
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) { sidebar } detail: { pageDetail }
        .background(BlankAreaDismissal(enabled: selected != nil && page != .collage) { selected = nil })
        .onReceive(NotificationCenter.default.publisher(for: .newTask)) { _ in guard workspaceAccessible else { return }; parent = nil; newTitle = ""; newTask = true }
        .onReceive(NotificationCenter.default.publisher(for: .configurePageBackground)) { _ in configuringBackground = true }
        .onChange(of: account.identityKey) { _, _ in editingPage = nil; newTask = false; configuringBackground = false }
        .sheet(isPresented: $configuringBackground) {
            PageBackgroundSettings(backgrounds: backgrounds, pages: backgroundPages, currentPage: (page ?? .progress).persistenceKey)
        }
        .onAppear { if account.bootstrapAvailable { page = .account }; validateRestoredView() }
        .onChange(of: workspaceAccessible) { _, accessible in if accessible { validateRestoredView() } }
        .onChange(of: viewState) { _, _ in persistView() }
        .onReceive(NotificationCenter.default.publisher(for: .commitInlineTaskTitle)) { _ in persistView() }
        .onDisappear { persistView() }
        .onChange(of: workDefault) { _, mode in workMode = TaskViewMode.available(for: .work).contains(mode) ? mode : .board }
        .onChange(of: personalDefault) { _, mode in personalMode = mode }
        .onChange(of: page) { _, _ in
            if let id = selected, let task = store.task(id), let space = page?.taskSpace, task.taskSpace != space { selected = nil }
        }
        .onChange(of: store.taskPages.map(\.id)) { _, _ in validateRestoredView() }
        .onChange(of: store.tasks.map(\.id)) { _, _ in validateRestoredView() }
        .onChange(of: search) { _, value in
            if !value.isEmpty && page?.taskSpace == nil && ![.ledger, .tracks, .graph, .recovery, .account, .shared].contains(page) { searches[.progress] = value; page = .progress; selected = nil }
        }
        .sheet(item: $editingPage) { record in
            TaskPageEditor(page: record) { id in
                if record.id.isEmpty, let space = TaskSpace(rawValue: id) { selected = nil; page = .taskPage(space) }
            }.environmentObject(store)
        }
        .sheet(isPresented: $newTask) {
            VStack(alignment: .leading, spacing: 20) {
                Text(parent == nil ? (creationSpace == .personal ? "新建私人任务" : "新建任务") : "添加子任务").font(.title2.bold())
                TextField("任务名称", text: $newTitle).textFieldStyle(.roundedBorder).onSubmit { create() }
                HStack { Spacer(); Button("取消") { newTask = false }.keyboardShortcut(.cancelAction).disabled(creating)
                    Button(creating ? "创建中…" : "创建") { create() }.keyboardShortcut(.defaultAction).disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || creating || store.busy)
                }
            }.padding(24).frame(width: 420)
        }
    }
    private func deletePage(_ record: Record) {
        let alert = NSAlert(); alert.messageText = "删除任务页「\(record.title)」？"
        alert.informativeText = "只能删除没有任何任务的页面。删除后可在归档与恢复中撤销。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "删除")
        if alert.runModal() == .alertSecondButtonReturn { Task { _ = await store.deleteEmptyTaskPage(record.id) } }
    }
    private func create() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty && !creating else { return }
        creating = true
        let parentID = parent
        let space = creationSpace
        let inLedger = page == .ledger
        Task {
            defer { creating = false }
            if let id = await store.createTask(title: title, parent: parentID, space: space, fields: inLedger ? ["ledgerEnabled": true, "recordType": "项目"] : [:]) {
                if !inLedger {
                    UserDefaults.standard.set("open", forKey: WorkspaceViewState.preferenceKey("tasks.\(space.rawValue).status", identity: workspaceIdentity))
                    UserDefaults.standard.set("all", forKey: WorkspaceViewState.preferenceKey("tasks.\(space.rawValue).track", identity: workspaceIdentity))
                    page = .tasks(in: space)
                }
                searches[page ?? .progress] = ""
                selected = id; newTask = false
            }
        }
    }
}

private struct WorkspaceSearch: ViewModifier {
    @Binding var text: String
    let enabled: Bool
    let prompt: String
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.searchable(text: $text, placement: .toolbar, prompt: prompt) }
        else { content }
    }
}

struct StatusLabel: View {
    let status: String
    var body: some View {
        let s = TaskStatus(rawValue: status) ?? .ready
        Label(s.title, systemImage: s.symbol).font(.caption.weight(status == "active" ? .bold : .medium))
            .foregroundStyle(Color(nsColor: s.color)).fixedSize()
    }
}

struct TaskRow: View {
    @EnvironmentObject var store: OOSStore
    let task: Record
    var indent = 0
    var renaming: Binding<Bool> = .constant(false)
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if indent > 0 { Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(.tertiary).padding(.leading, CGFloat(min(indent, 10) - 1) * 16) }
            VStack(alignment: .leading, spacing: 5) {
                InlineTaskTitle(task: task, editing: renaming)
                HStack(spacing: 10) {
                    if task.isArchived { Label("已归档", systemImage: "archivebox") }
                    if task.taskSpace == .personal { Label("私人", systemImage: "person.crop.circle") }
                    if task.taskSpace.isCustom { Label(store.title(for: task.taskSpace), systemImage: task.taskSpace.symbol) }
                    if !task.text("project").isEmpty { Text(task.text("project")) }
                    if !task.text("due").isEmpty { Label(String(task.text("due").prefix(10)), systemImage: "calendar") }
                    Text("P\(Int(task.number("priority", 5)))").monospacedDigit()
                }.font(.caption).foregroundStyle(.secondary)
                if let block = store.blocked(task) { Text(block).font(.caption).foregroundStyle(.orange).lineLimit(1) }
                else if task.status == "waiting", !task.text("waitingCondition").isEmpty { Text(task.text("waitingCondition")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 12)
            StatusLabel(status: task.status)
        }.padding(.vertical, 8).contentShape(Rectangle()).taskDetailClickTarget()
    }
}

struct TasksView: View {
    @EnvironmentObject var store: OOSStore
    @Binding var selected: String?
    let search: String
    let space: TaskSpace
    @Binding var mode: TaskViewMode
    @State private var renamingTaskID: String?
    @AppStorage private var track: String
    @AppStorage private var status: String
    init(selected: Binding<String?>, search: String, space: TaskSpace, mode: Binding<TaskViewMode>, workspaceIdentity: String) {
        _selected = selected; self.search = search; self.space = space
        _mode = mode
        _track = AppStorage(wrappedValue: UserDefaults.standard.string(forKey: "HeroOOS.tasks.\(space.rawValue).track") ?? "all",
            WorkspaceViewState.preferenceKey("tasks.\(space.rawValue).track", identity: workspaceIdentity))
        _status = AppStorage(wrappedValue: UserDefaults.standard.string(forKey: "HeroOOS.tasks.\(space.rawValue).status") ?? "open",
            WorkspaceViewState.preferenceKey("tasks.\(space.rawValue).status", identity: workspaceIdentity))
    }
    var filtered: [Record] {
        store.displayOrdered(store.tasks.filter {
            space.matches($0, status: status, track: track, query: search)
        }, mode: mode)
    }
    private func renaming(_ id: String) -> Binding<Bool> {
        Binding(get: { renamingTaskID == id }, set: { value in
            if value { selected = nil; renamingTaskID = id }
            else if renamingTaskID == id { renamingTaskID = nil }
        })
    }
    func treeRows(_ items: [Record]) -> [(Record, Int)] {
        let available = Set(items.map(\.id))
        let children = Dictionary(grouping: items, by: { $0.text("parentId") })
        var result: [(Record, Int)] = []; var seen = Set<String>()
        func append(_ r: Record, depth: Int) {
            guard seen.insert(r.id).inserted else { return }
            result.append((r, depth))
            for child in children[r.id] ?? [] { append(child, depth: depth + 1) }
        }
        for r in items where !available.contains(r.text("parentId")) { append(r, depth: 0) }
        for r in items where !seen.contains(r.id) { append(r, depth: 0) }
        return result
    }
    var body: some View {
        let items = filtered
        let columns = Dictionary(grouping: items, by: \.status)
        VStack(spacing: 0) {
            HStack {
                if mode == .graph {
                    Label("私人任务关系图", systemImage: "person.crop.circle").font(.callout).foregroundStyle(.secondary)
                } else {
                    Picker("归属", selection: $track) { Text("全部板块").tag("all"); ForEach(store.tracks) { Text($0.text("navLabel")).tag($0.id) } }.labelsHidden().frame(width: 150).taskDetailClickTarget()
                    Picker("状态", selection: $status) { Text("开放任务").tag("open"); Text("所有状态").tag("all"); ForEach(TaskStatus.allCases) { Text($0.title).tag($0.rawValue) } }.labelsHidden().frame(width: 125).taskDetailClickTarget()
                }
                Spacer()
                if mode != .graph { Text("\(items.count) 项").font(.caption).foregroundStyle(.secondary) }
                Picker("视图", selection: $mode) {
                    ForEach(TaskViewMode.available(for: space)) { Image(systemName: $0.symbol).tag($0).accessibilityLabel($0.title).help($0.title) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: space == .personal ? 132 : 85)
                    .help(space == .personal ? "列表、看板或关系图；自动记住上次选择" : "列表或看板").taskDetailClickTarget()
            }.padding(16)
            Divider()
            if mode == .graph {
                TaskGraphWorkspace(selected: $selected, search: search, space: space)
            } else if items.isEmpty {
                ContentUnavailableView(search.isEmpty ? (space == .personal ? "暂无私人任务" : "暂无任务") : "没有匹配结果", systemImage: space.symbol)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contextMenu { TaskBlankMenu() }
            } else if mode == .list {
                List(selection: $selected) {
                    ForEach(treeRows(items), id: \.0.id) { task, depth in
                        TaskRow(task: task, indent: depth, renaming: renaming(task.id)).tag(task.id)
                            .modifier(TaskDropTarget(task: task, mode: .list, renaming: renaming(task.id), select: { selected = task.id }))
                    }
                }.listStyle(.inset)
                    .contextMenu(forSelectionType: String.self) { ids in
                        if let id = ids.first, let task = store.task(id) {
                            TaskContextMenu(task: task, mode: .list, didHide: { if selected == id { selected = nil } })
                        } else { TaskBlankMenu() }
                    }
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(TaskStatus.allCases.filter { status == "all" || (status == "open" ? [.ready, .active, .waiting, .review, .backlog, .blocked, .information].contains($0) : $0.rawValue == status) }) { column in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack { StatusLabel(status: column.rawValue); Spacer(); Text("\(columns[column.rawValue, default: []].count)").foregroundStyle(.secondary) }.padding(.horizontal, 12)
                                ScrollView {
                                    LazyVStack(spacing: 8) {
                                        ForEach(columns[column.rawValue, default: []]) { item in
                                            TaskRow(task: item, renaming: renaming(item.id)).padding(.horizontal, 12).background(selected == item.id ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                                                .taskDetailClickTarget()
                                                .modifier(TaskDropTarget(task: item, mode: .board, renaming: renaming(item.id), select: { selected = item.id }))
                                                .contextMenu { TaskContextMenu(task: item, mode: .board, didHide: { if selected == item.id { selected = nil } }) }
                                        }
                                    }.padding(.horizontal, 8)
                                }
                            }.padding(.top, 16).frame(width: 280)
                                .contentShape(Rectangle()).contextMenu { TaskBlankMenu() }
                                .background(TaskColumnDropBridge(canAccept: { store.task($0)?.taskSpace == space }, accept: { id, _ in
                                    Task { _ = await store.moveTask(id, mode: .board, placement: "last", status: column.rawValue) }
                                    return true
                                }))
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

struct TaskInspector: View {
    @EnvironmentObject var store: OOSStore
    let id: String
    let close: () -> Void
    let addChild: () -> Void
    @State private var dependency = ""
    func text(_ key: String) -> Binding<String> { Binding(get: { store.task(id)?.text(key) ?? "" }, set: { store.edit(id, key, .string($0)) }) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("任务详情").font(.headline)
                Text(store.task(id)?.title ?? "").foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless).help("关闭详情")
            }.padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            if let task = store.task(id) {
                let choices = Relations.choices(for: task, tasks: store.tasks)
                HStack(spacing: 0) {
                Form {
                    Section {
                        TextField("名称", text: text("title"), axis: .vertical).font(.headline)
                        TaskBackgroundField(text: text("background")).id(id)
                        Picker("任务分区", selection: Binding(get: { task.taskSpace.rawValue }, set: { store.edit(id, "taskSpace", .string($0)) })) {
                            ForEach(store.taskSpaces) { Text(store.title(for: $0)).tag($0.rawValue) }
                        }
                        Picker("状态", selection: text("status")) { ForEach(TaskStatus.allCases) { Text($0.title).tag($0.rawValue) } }
                        Stepper(value: Binding(get: { Int(task.number("priority", 5)) }, set: { store.edit(id, "priority", .number(Double($0))) }), in: 1...10) {
                            Text("优先级 \(Int(task.number("priority", 5)))/10")
                        }
                        Text("基础 \(Int(task.number("priorityBase", 5))) · 延后 \(Int(task.number("deferCount"))) 次").font(.caption).foregroundStyle(.secondary)
                        Picker("板块", selection: text("trackId")) { Text("未归属").tag(""); ForEach(store.tracks) { Text($0.text("navLabel")).tag($0.id) } }
                        if let track = store.tracks.first(where: { $0.id == task.text("trackId") }), !track["stages"].array.isEmpty {
                            Picker("阶段", selection: text("stage")) { Text("未指定").tag(""); ForEach(track["stages"].array.map(\.string), id: \.self) { Text($0).tag($0) } }
                        }
                        TextField("项目", text: text("project"))
                        TextField("委托人", text: text("requester"))
                        DateField(title: "截止", value: text("due"))
                        DateField(title: "复查", value: text("reviewDate"))
                        EffortField(value: Binding(get: { store.task(id)?["effortHours"] ?? .null }, set: { store.edit(id, "effortHours", $0) }))
                    }
                    if StudioLedger.contains(task) {
                        LedgerInspectorFields(id: id)
                    } else if task.taskSpace == .work {
                        Section {
                            Button("加入工作室台账") { store.edit(id, "ledgerEnabled", true) }
                        }
                    }
                }.formStyle(.grouped).frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                Form {
                    TaskConditionsFields(id: id).id(id)
                    Section("当前情况") {
                        TextField("等待条件", text: text("waitingCondition"), axis: .vertical)
                        TextField("状态说明", text: text("statusNote"), axis: .vertical).lineLimit(3...10)
                        TextField("备注", text: text("note"), axis: .vertical).lineLimit(3...12)
                        ForEach(Array(task["details"].array.enumerated()), id: \.offset) { _, item in
                            Text(item.string.isEmpty ? String(describing: item.object) : item.string).font(.callout).textSelection(.enabled)
                        }
                    }
                    Section("任务关系") {
                        Picker("父任务", selection: text("parentId")) {
                            Text("无").tag("")
                            ForEach(choices.parents) { Text($0.title).tag($0.id) }
                        }
                        Button("添加子任务", action: addChild)
                        if let block = store.blocked(task) { Text(block).foregroundStyle(.orange).font(.caption) }
                    }
                    Section("关联") {
                        TextField("Codex 对话", text: text("codexThreadId"))
                        if !task.text("codexThreadId").isEmpty {
                            Button("打开对话") {
                                let raw = task.text("codexThreadId")
                                let url = raw.contains("://") ? raw : "codex://threads/\(raw)"
                                if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                            }
                        }
                        Toggle("加入专注画布", isOn: Binding(get: { task["focused"].bool }, set: { store.edit(id, "focused", .bool($0)) }))
                    }
                    Section {
                        HStack {
                            if task.isArchived { Button("取消归档") { store.edit(id, "archived", false) } }
                            Button(task.isClosed ? "恢复待办" : "标记完成") { store.edit(id, "status", .string(task.isClosed ? "ready" : "completed")) }
                            Spacer()
                            Menu {
                                ForEach([1, 2, 7], id: \.self) { days in
                                    Button("延后 \(days) 天") {
                                        store.deferTask(id, days: days)
                                    }
                                }
                            } label: { Image(systemName: "calendar.badge.clock") }.help("延期")
                        }
                        Text(task.id).font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
                        if store.pending[id] != nil {
                            Button("撤销此任务未保存的修改", role: .destructive) {
                                let alert = NSAlert(); alert.messageText = "撤销尚未保存的修改？"; alert.informativeText = "此任务会恢复到最近同步的版本。"
                                alert.addButton(withTitle: "保留编辑"); alert.addButton(withTitle: "撤销修改")
                                if alert.runModal() == .alertSecondButtonReturn { store.discardDraft(id) }
                            }.disabled(store.busy)
                        }
                    }
                }.formStyle(.grouped).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

struct EffortField: View {
    @Binding var value: JSON
    @State private var input = ""
    @FocusState private var focused: Bool
    var valid: Bool { input.isEmpty || Double(input).map { $0.isFinite && $0 >= 0 } == true }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("预计工时", text: $input).focused($focused)
                .onAppear { sync() }
                .onChange(of: value) { _, _ in if !focused { sync() } }
                .onChange(of: input) { _, text in
                    if text.isEmpty { value = .null }
                    else if let number = Double(text), number.isFinite && number >= 0 { value = .number(number) }
                }
            if !valid { Text("请输入非负数字，此项尚未保存").font(.caption).foregroundStyle(.red) }
        }
    }
    private func sync() { input = value == .null ? "" : String(value.number) }
}

struct DateField: View {
    let title: String
    @Binding var value: String
    var body: some View {
        HStack {
            if value.isEmpty {
                Text(title); Spacer(); Button("设置") { value = Dates.day() }.buttonStyle(.borderless)
            } else {
                DatePicker(title, selection: Binding(get: { Dates.parse(value) ?? Date() }, set: { value = Dates.day($0) }), displayedComponents: .date)
                Button { value = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).help("清除日期")
            }
        }
    }
}

struct TodayView: View {
    @EnvironmentObject var store: OOSStore
    @Binding var selected: String?
    @State private var capture = ""
    @State private var submitting = false
    var body: some View {
        List(selection: $selected) {
            Section("\(Dates.day()) · 今日安排") {
                let blocks = store.schedules.filter { Dates.parse($0.text("start")).map { Calendar.current.isDateInToday($0) } == true && $0.status != "completed" }
                if blocks.isEmpty { Text("今天没有固定日程").foregroundStyle(.secondary) }
                ForEach(blocks) { block in
                    HStack { Text(Dates.parse(block.text("start")) ?? Date(), style: .time); Text(block.title); if store.task(block.text("taskId"))?.taskSpace == .personal { Text("私人").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button { Task { await store.perform([.object(["type": .string("schedule.complete"), "id": .string(block.id)])]) } } label: { Image(systemName: "checkmark.circle") }.buttonStyle(.borderless).help("完成这次日程") }
                }
            }
            Section("当前可推进") {
                let items = store.ranked(store.tasks.filter { $0.isExecutionTracked && !["waiting", "backlog", "blocked"].contains($0.status) && store.blocked($0) == nil })
                if items.isEmpty { Text("暂无可执行任务").foregroundStyle(.secondary) }
                ForEach(items) { TaskRow(task: $0).tag($0.id) }
            }
            Section("待复查与等待") {
                ForEach(store.ranked(store.tasks.filter { $0.isExecutionTracked && ($0.status == "waiting" || store.blocked($0) != nil) })) { TaskRow(task: $0).tag($0.id) }
            }
            Section("快速记录") {
                HStack { TextField("记录一件事…", text: $capture).onSubmit { submitCapture() }; Button(action: submitCapture) { Image(systemName: "arrow.up.circle.fill") }.buttonStyle(.borderless).disabled(capture.isEmpty).help("提交记录") }
                ForEach(store.state["captures"].records.suffix(5).reversed()) { Text($0.text("text")).font(.callout).foregroundStyle(.secondary) }
            }
        }.listStyle(.inset)
    }
    func submitCapture() {
        guard !submitting && !capture.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        submitting = true
        let value = capture
        Task { defer { submitting = false }; if await store.perform([.object(["type": .string("capture.add"), "text": .string(value)])]), capture == value { capture = "" } }
    }
}

struct PlanView: View {
    @EnvironmentObject var store: OOSStore
    @Binding var selected: String?
    @AppStorage private var savedDate: Double
    @AppStorage private var savedMode: String
    @AppStorage private var showsDay: Bool
    private var mode: AgendaCalendar.Mode {
        get { AgendaCalendar.Mode(rawValue: savedMode) ?? .month }
        nonmutating set { savedMode = newValue.rawValue }
    }
    private var date: Date {
        get { Date(timeIntervalSince1970: savedDate) }
        nonmutating set { savedDate = newValue.timeIntervalSince1970 }
    }
    init(selected: Binding<String?>, workspaceIdentity: String) {
        _selected = selected
        _savedDate = AppStorage(wrappedValue: Date().timeIntervalSince1970, WorkspaceViewState.preferenceKey("plan.date", identity: workspaceIdentity))
        _savedMode = AppStorage(wrappedValue: "month", WorkspaceViewState.preferenceKey("plan.mode", identity: workspaceIdentity))
        _showsDay = AppStorage(wrappedValue: true, WorkspaceViewState.preferenceKey("plan.showsDay", identity: workspaceIdentity))
    }
    @State private var adding = false
    @State private var title = ""
    @State private var taskID = ""
    @State private var start = Date()
    @State private var end = Date().addingTimeInterval(3600)
    @State private var editingID: String?
    @State private var submitting = false
    var body: some View {
        let snapshot = AgendaCalendarSnapshot(tasks: store.tasks, schedules: store.schedules, date: date, mode: mode)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }.help("上一" + mode.title)
                Button("今天") { date = Date() }
                Button { shift(1) } label: { Image(systemName: "chevron.right") }.help("下一" + mode.title)
                Text(AgendaCalendarText.period(date, mode: mode)).font(.headline).lineLimit(1)
                Spacer()
                Button { newSchedule() } label: { Label("添加日程", systemImage: "plus") }
                Picker("日历视图", selection: Binding(get: { mode }, set: { mode = $0 })) {
                    ForEach(AgendaCalendar.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).frame(width: 162).help("切换周、月、年日历；自动记住上次选择")
            }.padding(12).taskDetailClickTarget()
            HStack(spacing: 16) {
                DatePicker("选中日期", selection: Binding(get: { date }, set: { date = $0; showsDay = true }), displayedComponents: .date).frame(width: 210)
                AgendaCalendarLegend()
                Spacer(minLength: 0)
            }.font(.caption).padding(.horizontal, 14).padding(.bottom, 10).taskDetailClickTarget()
            Divider()
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    AgendaCalendarContent(date: date, mode: mode, snapshot: snapshot,
                                          selectDay: { date = $0; showsDay = true; selected = nil },
                                          selectMonth: { date = $0; mode = .month; selected = nil },
                                          openItem: openCalendarItem)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    Button { showsDay.toggle(); selected = nil } label: {
                        HStack {
                            Image(systemName: showsDay && selected == nil ? "chevron.down" : "chevron.right")
                            Text(AgendaCalendarText.day(date) + " · 当天明细")
                            Text("\(snapshot.items(on: date).count) 项").foregroundStyle(.secondary)
                            Spacer()
                            Text("阻断日期优先 · 无则按截止日期").font(.caption).foregroundStyle(.secondary)
                        }.padding(.horizontal, 14).padding(.vertical, 9).contentShape(Rectangle())
                    }.buttonStyle(.plain).taskDetailClickTarget()
                    if showsDay && selected == nil {
                        dayAgenda.frame(height: max(90, min(230, geometry.size.height * 0.34)))
                    }
                }
            }
        }.sheet(isPresented: $adding) {
            VStack(alignment: .leading, spacing: 18) {
                Text(editingID == nil ? "添加日程" : "编辑日程").font(.title2.bold())
                TextField("标题", text: $title)
                Picker("关联任务", selection: $taskID) { Text("无").tag(""); ForEach(store.tasks.filter { $0.isExecutionTracked || $0.id == taskID }) { Text(($0.taskSpace == .personal ? "[私人] " : "") + $0.title).tag($0.id) } }
                    .onChange(of: taskID) { _, value in if let task = store.task(value), title.isEmpty { title = task.title } }
                DatePicker("开始", selection: $start)
                DatePicker("结束", selection: $end)
                HStack { Spacer(); Button("取消") { adding = false }.disabled(submitting); Button(editingID == nil ? "添加" : "保存") {
                    guard !submitting else { return }
                    submitting = true
                    Task {
                        defer { submitting = false }
                        let block: JSON = .object(["title": .string(title), "taskId": .text(taskID), "start": .string(Dates.iso(start)), "end": .string(Dates.iso(end))])
                        let ops: [JSON]
                        if let id = editingID {
                            ops = [.object(["type": .string("schedule.update"), "id": .string(id), "changes": .object(["title": .string(title), "taskId": .text(taskID)])]), .object(["type": .string("schedule.move"), "id": .string(id), "start": .string(Dates.iso(start)), "end": .string(Dates.iso(end))])]
                        } else { ops = [.object(["type": .string("schedule.create"), "block": block])] }
                        if await store.perform(ops) { adding = false; title = ""; editingID = nil }
                    }
                }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || end <= start || submitting).keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 440)
        }
    }
    private func shift(_ amount: Int) { date = AgendaCalendar.shifted(date, by: amount, mode: mode) }
    private func newSchedule() {
        editingID = nil; title = ""; taskID = ""
        start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date
        end = start.addingTimeInterval(3600); adding = true
    }
    private func editSchedule(_ block: Record) {
        editingID = block.id; title = block.title; taskID = block.text("taskId")
        start = Dates.parse(block.text("start")) ?? date
        end = Dates.parse(block.text("end")) ?? start.addingTimeInterval(3600); adding = true
    }
    private func openCalendarItem(_ item: AgendaCalendarItem) {
        if let task = item.task { selected = task.task.id }
        else if let block = item.schedule { editSchedule(block) }
    }
    private var dayAgenda: some View {
        List {
            let blocks = AgendaCalendar.schedules(on: date, from: store.schedules)
            let taskDates = TaskAgenda.entries(tasks: store.tasks, on: date)
            if blocks.isEmpty && taskDates.isEmpty {
                Text("当天暂无日程或任务日期").foregroundStyle(.secondary).padding(.vertical, 16)
            }
            if !taskDates.isEmpty {
                Section("任务日期 · 自动关联") {
                    ForEach(taskDates) { entry in TaskAgendaRow(entry: entry) { selected = entry.task.id } }
                }
            }
            if !blocks.isEmpty {
                Section("手动安排") {
                    ForEach(blocks) { block in
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading) {
                                Text(Dates.parse(block.text("start")) ?? date, format: .dateTime.month().day().hour().minute())
                                Text(Dates.parse(block.text("end")) ?? date, format: .dateTime.month().day().hour().minute()).foregroundStyle(.secondary)
                            }.font(.caption.monospacedDigit()).frame(width: 110, alignment: .leading)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(block.title).font(.headline)
                                Text(block.status == "completed" ? "已完成" : "已安排").font(.caption).foregroundStyle(.secondary)
                                if store.task(block.text("taskId"))?.taskSpace == .personal { Label("私人", systemImage: "person.crop.circle").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if let task = store.task(block.text("taskId")) {
                                Button { selected = task.id } label: { Image(systemName: "arrow.up.right.square") }.help("打开关联任务")
                            }
                            Button { editSchedule(block) } label: { Image(systemName: "pencil") }.help("编辑日程")
                            if block.status != "completed" {
                                Button { Task { await store.perform([.object(["type": .string("schedule.complete"), "id": .string(block.id)])]) } } label: { Image(systemName: "checkmark.circle") }.help("完成日程")
                            }
                        }.padding(.vertical, 10).contentShape(Rectangle()).taskDetailClickTarget().onTapGesture { editSchedule(block) }
                    }
                }
            }
        }.listStyle(.inset)
    }
}

struct TracksView: View {
    @EnvironmentObject var store: OOSStore
    @Binding var selected: String?
    let search: String
    var body: some View {
        List(selection: $selected) {
            ForEach(store.tracks) { track in
                Section {
                    let tasks = store.ranked(store.tasks.filter { $0.text("trackId") == track.id && $0.isOpen && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) })
                    if tasks.isEmpty { Text("暂无开放任务").foregroundStyle(.secondary) }
                    ForEach(tasks) { TaskRow(task: $0).tag($0.id) }
                    if track.text("archetype") == "habit" {
                        Button("记录今天维护") { Task { await store.perform([.object(["type": .string("checkin.record"), "trackId": .string(track.id), "value": .bool(true), "date": .string(Dates.day())])]) } }
                    }
                } header: { Text(track.text("name")).font(.headline) }
            }
        }.listStyle(.inset)
    }
}

struct RecoveryView: View {
    @EnvironmentObject var store: OOSStore
    @Binding var selected: String?
    let search: String
    @AppStorage private var tab: Int
    init(selected: Binding<String?>, search: String, workspaceIdentity: String) {
        _selected = selected; self.search = search
        _tab = AppStorage(wrappedValue: 0, WorkspaceViewState.preferenceKey("recovery.tab", identity: workspaceIdentity))
    }
    var body: some View {
        VStack(spacing: 0) {
            Picker("内容", selection: $tab) { Text("归档、已关闭与暂停").tag(0); Text("操作记录").tag(1) }.pickerStyle(.segmented).padding(16).frame(maxWidth: 400)
            if tab == 0 {
                List(selection: $selected) {
                    ForEach(store.tasks.filter { !$0.isOpen && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }.reversed()) { task in
                        TaskRow(task: task).tag(task.id).contextMenu { TaskContextMenu(task: task, didHide: { selected = nil }) }
                    }
                }
            } else {
                List {
                    ForEach(store.state["receipts"].records.reversed()) { receipt in
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(receipt["operations"].array.map { operationName($0) }.joined(separator: " · ")).font(.callout)
                                if let date = Dates.parse(receipt.text("timestamp")) { Text(date, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary) }
                                let names = receipt["affected"].array.filter { $0["entity"].string == "task" }.compactMap { store.task($0["id"].string)?.title }
                                if !names.isEmpty { Text(names.joined(separator: "、")).font(.caption).lineLimit(2).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if let reason = store.undoBlock(receipt) { Text(reason).font(.caption).foregroundStyle(.secondary) }
                            else {
                                Button("撤销") {
                                    let alert = NSAlert(); alert.messageText = "撤销这次操作？"; alert.informativeText = "将恢复此操作修改前的数据。"; alert.addButton(withTitle: "撤销"); alert.addButton(withTitle: "取消")
                                    if alert.runModal() == .alertFirstButtonReturn { Task { await store.perform([.object(["type": .string("receipt.undo"), "receiptId": .string(receipt.id)])]) } }
                                }
                            }
                        }.padding(.vertical, 6)
                    }
                }
            }
        }
    }
    func operationName(_ operation: JSON) -> String {
        if operation["type"].string == "task.reorder" { return "调整任务顺序" }
        if operation["changes"]["archived"] != .null { return operation["changes"]["archived"].bool ? "归档任务" : "取消归档" }
        let labels = ["task.create": "新增任务", "task.update": "修改任务", "task.complete": "完成任务", "task.delete": "删除任务", "task.restore": "恢复任务", "schedule.create": "新增日程", "schedule.move": "调整日程", "schedule.complete": "完成日程", "schedule.update": "编辑日程", "receipt.undo": "撤销操作", "capture.add": "添加记录", "checkin.record": "记录维护", "onboarding.step": "更新设置"]
        let pageLabels = ["taskPage.create": "新增任务页", "taskPage.update": "重命名任务页", "taskPage.delete": "删除空任务页", "taskPage.restore": "恢复任务页"]
        return pageLabels[operation["type"].string] ?? labels[operation["type"].string] ?? "状态更新"
    }
}

struct FocusView: View {
    @EnvironmentObject var store: OOSStore
    @Environment(\.pageBackgroundVisible) private var pageBackgroundVisible
    @Binding var selected: String?
    @State private var positions: [String: CGPoint] = [:]
    @State private var origins: [String: CGPoint] = [:]
    var items: [Record] { store.tasks.filter { $0.isExecutionTracked && $0["focused"].bool } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(items.count) 项专注任务").foregroundStyle(.secondary)
                Spacer()
                Menu { ForEach(store.tasks.filter { $0.isExecutionTracked && !$0["focused"].bool }) { task in Button((task.taskSpace == .personal ? "[私人] " : "") + task.title) { store.edit(task.id, "focused", .bool(true)) } } } label: { Image(systemName: "plus") }.help("加入任务")
            }.padding(16)
            Divider()
            if items.isEmpty { ContentUnavailableView("专注画布为空", systemImage: "rectangle.3.group") }
            else {
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        if !pageBackgroundVisible { Color(nsColor: .underPageBackgroundColor) }
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, task in
                            let point = positions[task.id] ?? CGPoint(x: 32 + (index % 4) * 324, y: 32 + (index / 4) * 160)
                            VStack(alignment: .leading, spacing: 10) {
                                Text(task.title).fontWeight(task.status == "active" ? .bold : .medium).lineLimit(3)
                                HStack { StatusLabel(status: task.status); if task.taskSpace == .personal { Text("私人").font(.caption).foregroundStyle(.secondary) }; Spacer(); Text("P\(Int(task.number("priority", 5)))").font(.caption).foregroundStyle(.secondary) }
                            }.padding(16).frame(width: 292, height: 125, alignment: .topLeading)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected == task.id ? Color.accentColor : Color.secondary.opacity(0.2)))
                                .taskDetailClickTarget()
                                .offset(x: point.x, y: point.y)
                                .onTapGesture { selected = task.id }
                                .gesture(DragGesture(minimumDistance: 4).onChanged { value in
                                    if origins[task.id] == nil { origins[task.id] = point }
                                    let origin = origins[task.id]!
                                    positions[task.id] = CGPoint(x: max(0, origin.x + value.translation.width), y: max(0, origin.y + value.translation.height))
                                }.onEnded { _ in origins.removeValue(forKey: task.id); savePositions() })
                                .contextMenu { Button("移出专注画布") { store.edit(task.id, "focused", .bool(false)) } }
                        }
                    }.frame(width: max(2000, (positions.values.map(\.x).max() ?? 0) + 400), height: max(1400, (positions.values.map(\.y).max() ?? 0) + 250))
                }
            }
        }.onAppear {
            if let data = UserDefaults.standard.data(forKey: "focusPositions"), let saved = try? JSONDecoder().decode([String: [Double]].self, from: data) {
                positions = saved.compactMapValues { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
            }
        }
    }
    func savePositions() { UserDefaults.standard.set(try? JSONEncoder().encode(positions.mapValues { [$0.x, $0.y] }), forKey: "focusPositions") }
}

struct SettingsView: View {
    @EnvironmentObject var store: OOSStore
    @EnvironmentObject var updates: UpdateManager
    var body: some View {
        Form {
            Section("首次使用的默认视图") {
                ForEach(store.taskSpaces) { space in TaskPageViewPreference(space: space, title: store.title(for: space)) }
                Text("之后启动会恢复退出前的页面和视图；不同账号分别记忆。").font(.caption).foregroundStyle(.secondary)
            }
            Section { SoftwareUpdateSettingsView(updates: updates) }
            Section("应用信息") {
            LabeledContent("应用", value: "Hero OOS Native \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.0")")
            LabeledContent("数据引擎", value: "Swift 本地读写")
            LabeledContent("数据目录", value: store.api.base.path)
            LabeledContent("当前版本", value: "v\(store.version)")
            Button("打开 OOS 数据目录") { NSWorkspace.shared.open(store.api.base) }
            }
        }.formStyle(.grouped).frame(width: 590, height: 600)
    }
}
