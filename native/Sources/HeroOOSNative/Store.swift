import Foundation
import AppKit
import Combine

struct OOSAPI {
    let base: URL
    var transport: ((String, String, JSON?, Data?) async throws -> JSON)?
    init(base: URL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HERO_OOS_ROOT"] ?? Bundle.main.object(forInfoDictionaryKey: "HeroOOSRoot") as? String ?? StateRuntime.defaultRoot), transport: ((String, String, JSON?, Data?) async throws -> JSON)? = nil) { self.base = base; self.transport = transport }
    var runtime: StateRuntime { StateRuntime(root: base) }
    var draftIdentity: String {
        base.standardizedFileURL.absoluteString
    }
    func request(_ path: String, method: String = "GET", body: JSON? = nil, raw: Data? = nil, contentType: String = "application/json") async throws -> JSON {
        if let transport { return try await transport(path, method, body, raw) }
        let runtime = runtime
        do {
            return try await Task.detached(priority: .userInitiated) {
                try runtime.request(path, method: method, body: body, raw: raw, contentType: contentType)
            }.value
        } catch let error as RuntimeError { throw APIError(code: error.code, payload: error.payload) }
    }
    func assetData(_ filename: String) async throws -> Data {
        let runtime = runtime
        return try await Task.detached(priority: .userInitiated) { try Data(contentsOf: runtime.assetURL(filename)) }.value
    }
    func startRuntimeIfNeeded() async throws {
        if transport == nil {
            let runtime = runtime
            try await Task.detached { try runtime.initializeIfNeeded() }.value
        }
        _ = try await request("/api/health")
    }
}

@MainActor final class OOSStore: ObservableObject {
    @Published var state: JSON = .object([:]) { didSet { taskSnapshot = nil } }
    @Published var connected = false
    @Published var busy = false
    @Published var error: String?
    @Published var saveMessage = "正在读取本机"
    @Published var pending: [String: [String: JSON]] = [:] { didSet { taskSnapshot = nil } }
    @Published var codexStatuses: [String: JSON] = [:]
    @Published var conflictTaskID: String?
    let api: OOSAPI
    private var bases: [String: Record] = [:]
    private var debounce: Task<Void, Never>?
    private var poll: Task<Void, Never>?
    private var uncertain: JSON?
    private var taskSnapshot: (records: [Record], byID: [String: Record])?
    private let draftsEnabled: Bool
    private var draftKey: String { "HeroOOS.taskDrafts.\(api.draftIdentity)" }
    var version: Int { Int(state["meta"]["version"].number) }
    var tasks: [Record] {
        resolvedTasks().records
    }
    private func resolvedTasks() -> (records: [Record], byID: [String: Record]) {
        if let taskSnapshot { return taskSnapshot }
        let records = state["tasks"].records.map { record in
            var r = record
            for (key, value) in pending[r.id] ?? [:] { r[key] = value }
            return r
        }
        let snapshot = (records, Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
        taskSnapshot = snapshot
        return snapshot
    }
    var tracks: [Record] { state["tracks"].records }
    var taskPages: [Record] { state["taskPages"].records }
    var taskSpaces: [TaskSpace] { TaskSpace.allCases + taskPages.compactMap { TaskSpace(rawValue: $0.id) } }
    func title(for space: TaskSpace) -> String { taskPages.first { $0.id == space.rawValue }?.title ?? space.title }
    var schedules: [Record] { state["scheduleBlocks"].records.sorted { $0.text("start") < $1.text("start") } }
    var hasUnsavedChanges: Bool { !pending.isEmpty || uncertain != nil || busy }
    init(api: OOSAPI = OOSAPI(), recoverDrafts: Bool = true) {
        self.api = api; draftsEnabled = recoverDrafts
        if recoverDrafts, let data = UserDefaults.standard.data(forKey: draftKey), let saved = try? JSONDecoder().decode(JSON.self, from: data) {
            pending = saved["pending"].object.mapValues(\.object)
            bases = saved["bases"].object.mapValues { Record($0.object) }
            if saved["uncertain"] == .null { uncertain = Optional<JSON>.none }
            else { uncertain = saved["uncertain"] }
            state = saved["state"]
            saveMessage = "草稿已保留 · 等待本机保存"
        }
    }
    deinit { debounce?.cancel(); poll?.cancel() }
    func stop() {
        poll?.cancel(); poll = nil
        debounce?.cancel(); debounce = nil
    }
    private func persistDrafts() {
        guard draftsEnabled else { return }
        let value: JSON = .object(["pending": .object(pending.mapValues(JSON.object)), "bases": .object(bases.mapValues(\.json)), "uncertain": uncertain ?? .null, "state": state])
        UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: draftKey)
    }
    func start() async {
        do { try await api.startRuntimeIfNeeded(); await refresh(); if !pending.isEmpty || uncertain != nil { _ = await flush() } }
        catch { self.error = error.localizedDescription; saveMessage = "本机读取失败" }
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }
    func refresh() async {
        guard !busy else { return }
        let reconnecting = !connected
        do {
            let response = try await api.request("/api/state")
            if acceptState(response["state"]) { persistDrafts() }
            if !connected { connected = true }
            let message = "已保存 · v\(version)"
            if pending.isEmpty && uncertain == nil && !busy && saveMessage != message { saveMessage = message }
            if reconnecting && (!pending.isEmpty || uncertain != nil) && !busy { _ = await flush() }
        } catch { connected = false; saveMessage = "本机读取失败 · 草稿保留中" }
    }
    @discardableResult func acceptState(_ incoming: JSON) -> Bool {
        guard incoming["meta"]["version"] != .null,
              incoming["meta"]["version"].number >= Double(version), incoming != state else { return false }
        state = incoming
        return true
    }
    func task(_ id: String) -> Record? { resolvedTasks().byID[id] }
    func edit(_ id: String, _ key: String, _ value: JSON) {
        do {
            let fields = try TaskPeopleWaits.normalized(.object([key: value]), current: task(id))
            for (field, next) in fields.object { editField(id, field, next) }
        } catch { self.error = error.localizedDescription }
    }
    private func editField(_ id: String, _ key: String, _ value: JSON) {
        guard let original = state["tasks"].records.first(where: { $0.id == id }) else { return }
        guard task(id)?[key] != value else { return }
        if original[key] == value && uncertain == nil && !busy {
            pending[id]?.removeValue(forKey: key)
            if pending[id]?.isEmpty == true { pending.removeValue(forKey: id); bases.removeValue(forKey: id) }
            if pending.isEmpty { error = nil; conflictTaskID = nil }
            persistDrafts(); saveMessage = pending.isEmpty ? "已保存 · v\(version)" : "尚未保存"
            return
        }
        if key == "parentId", !Relations.canParent(id, under: value.string, tasks: tasks) { error = "父任务必须在同一分区内，且不能形成循环。"; return }
        if key == "dependsOn", value.array.contains(where: { !Relations.canDepend(id, on: $0.string, tasks: tasks) }) { error = "不能依赖自己、形成循环，或让子任务等待父任务完成。"; return }
        if key == "status", value == "active", task(id)?.status != "active", let current = task(id), let reason = blocked(current) { error = "还不能开始。\(reason)"; return }
        if key == "taskSpace" {
            guard let space = TaskSpace(rawValue: value.string), taskSpaces.contains(space) else { error = "任务页不存在。"; return }
            guard Relations.canMove(id, to: space, tasks: tasks) else { error = "请先解除跨页父子关系，再更改任务分区。"; return }
        }
        if key == "status", ["completed", "cancelled"].contains(value.string), tasks.contains(where: { $0.text("parentId") == id && !$0.isClosed }) { error = "仍有未关闭的子任务，请先处理子任务。"; return }
        if ["effortHours", "amountTaxInclusive"].contains(key), value != .null {
            guard case .number(let number) = value, number.isFinite, number >= 0 else { error = "工时或金额必须是非负数字。"; return }
        }
        if bases[id] == nil { bases[id] = original }
        pending[id, default: [:]][key] = value
        persistDrafts()
        saveMessage = "尚未保存"
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            self?.debounce = nil
            _ = await self?.flush()
        }
    }
    private func mutation(_ operations: [JSON], confirmed: Bool = false) -> JSON {
        .object(["expectedVersion": .number(Double(version)), "clientMutationId": .string("native-\(UUID().uuidString)"), "operations": .array(operations), "confirmedMajor": .bool(confirmed)])
    }
    private func send(_ payload: JSON) async throws -> JSON {
        do { return try await api.request("/api/state-ops", method: "POST", body: payload) }
        catch let e as APIError { throw e }
        catch {
            // A lost response may follow a committed mutation. Reuse its id on retry.
            uncertain = payload
            persistDrafts()
            throw error
        }
    }
    @discardableResult func flush() async -> Bool {
        debounce?.cancel()
        while busy { do { try await Task.sleep(for: .milliseconds(50)) } catch { return false } }
        busy = true
        defer { busy = false; persistDrafts() }
        do {
            if let payload = uncertain {
                let response = try await send(payload)
                acceptState(response["state"]); uncertain = nil
                for operation in payload["operations"].array where operation["type"].string == "task.update" {
                    let id = operation["id"].string
                    for (key, value) in operation["changes"].object where pending[id]?[key] == value { pending[id]?.removeValue(forKey: key) }
                    if pending[id]?.isEmpty == true { pending.removeValue(forKey: id); bases.removeValue(forKey: id) }
                    else if pending[id] != nil { bases[id] = state["tasks"].records.first { $0.id == id } }
                }
            }
            while !pending.isEmpty {
                let batch = pending
                let remote = try await api.request("/api/state")
                acceptState(remote["state"])
                var operations: [JSON] = []
                for (id, changes) in batch {
                    guard let record = state["tasks"].records.first(where: { $0.id == id }), let base = bases[id] else {
                        throw NativeError.message("任务已在另一端移除；输入仍保留在本窗口。")
                    }
                    if let title = changes["title"], title.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        throw NativeError.message("任务名称不能为空。")
                    }
                    if let status = changes["status"], ["completed", "cancelled"].contains(status.string),
                       tasks.contains(where: { $0.text("parentId") == id && !$0.isClosed }) {
                        throw NativeError.message("「\(record.title)」仍有未关闭的子任务，请先处理子任务。")
                    }
                    let patch: [String: JSON]
                    do { patch = try Merge.patch(base: base, remote: record, changes: changes) }
                    catch { conflictTaskID = id; throw error }
                    operations.append(.object(["type": .string("task.update"), "id": .string(id), "changes": .object(patch)]))
                }
                var payload = mutation(operations)
                var response: JSON
                do { response = try await send(payload) }
                catch let e as APIError where e.code == "state_conflict" {
                    acceptState(try await api.request("/api/state")["state"])
                    for (id, changes) in batch {
                        guard let r = state["tasks"].records.first(where: { $0.id == id }), let b = bases[id] else { throw e }
                        do { _ = try Merge.patch(base: b, remote: r, changes: changes) }
                        catch { conflictTaskID = id; throw error }
                    }
                    payload["expectedVersion"] = .number(Double(version))
                    response = try await send(payload)
                }
                acceptState(response["state"]); uncertain = nil
                for (id, changes) in batch {
                    for (key, value) in changes where pending[id]?[key] == value { pending[id]?.removeValue(forKey: key) }
                    if pending[id]?.isEmpty == true { pending.removeValue(forKey: id); bases.removeValue(forKey: id) }
                    else { bases[id] = state["tasks"].records.first(where: { $0.id == id }) }
                }
            }
            error = nil; conflictTaskID = nil; connected = true; saveMessage = "已保存 · v\(version)"; return true
        } catch { self.error = error.localizedDescription; saveMessage = "未保存 · 需要处理"; return false }
    }
    @discardableResult func perform(_ operations: [JSON], confirmed: Bool = false) async -> Bool {
        if uncertain != nil { _ = await flush(); return false }
        guard await flush() else { return false }
        while busy { do { try await Task.sleep(for: .milliseconds(50)) } catch { return false } }
        busy = true; defer { busy = false; persistDrafts() }
        do {
            acceptState(try await api.request("/api/state")["state"])
            for operation in operations where operation["type"].string == "receipt.undo" {
                guard let receipt = state["receipts"].records.first(where: { $0.id == operation["receiptId"].string }), undoBlock(receipt) == nil else {
                    throw NativeError.message("相关内容在这次操作后又发生了修改，不能直接撤销旧记录。请在详情中核对当前版本。")
                }
            }
            let payload = mutation(operations, confirmed: confirmed)
            let result = try await send(payload)
            acceptState(result["state"]); uncertain = nil; error = nil
            saveMessage = "已保存 · v\(version)"; return true
        } catch let e as APIError where e.code == "confirmation_required" {
            let alert = NSAlert(); alert.messageText = "确认这次更改？"
            alert.informativeText = e.payload["risk"]["reasons"].array.map(\.string).joined(separator: "\n")
            alert.addButton(withTitle: "确认"); alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn {
                busy = false
                return await perform(operations, confirmed: true)
            }
            return false
        } catch { self.error = error.localizedDescription; saveMessage = "操作未完成"; return false }
    }
    func createTask(title: String, parent: String? = nil, space: TaskSpace = .work, fields: [String: JSON] = [:]) async -> String? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { error = "任务名称不能为空。"; return nil }
        let id = "task-\(UUID().uuidString)"
        let resolvedSpace = parent.flatMap { task($0)?.taskSpace } ?? space
        let value: JSON = .object(fields.merging(["id": .string(id), "title": .string(title), "taskSpace": .string(resolvedSpace.rawValue), "status": .string("ready"), "priority": .number(5), "parentId": parent.map(JSON.string) ?? .null]) { _, required in required })
        return await perform([.object(["type": .string("task.create"), "task": value])]) ? id : nil
    }
    func discardDraft(_ id: String) {
        guard uncertain == nil && !busy else { error = "上次提交的结果尚未确认，请先重试保存。"; return }
        pending.removeValue(forKey: id); bases.removeValue(forKey: id)
        if conflictTaskID == id { conflictTaskID = nil }
        error = nil; saveMessage = pending.isEmpty ? "已撤销未保存修改" : "尚未保存"; persistDrafts()
    }
    func deferTask(_ id: String, days: Int) {
        guard days > 0, let task = task(id) else { return }
        let start = Dates.parse(task.text("due")) ?? Date()
        guard let due = Calendar.current.date(byAdding: .day, value: days, to: start) else { return }
        edit(id, "due", .string(Dates.day(due)))
        edit(id, "deferCount", .number(task.number("deferCount") + 1))
        edit(id, "priority", .number(min(10, task.number("priority", 5) + 1)))
    }
    func undoBlock(_ receipt: Record) -> String? {
        if receipt["undoneAt"] != .null { return "已撤销" }
        let affected = Set(receipt["affected"].array.map { $0["entity"].string + ":" + $0["id"].string })
        for later in state["receipts"].records where later.number("version") > receipt.number("version") {
            if later["affected"].array.contains(where: { affected.contains($0["entity"].string + ":" + $0["id"].string) }) { return "后续已有修改" }
        }
        return nil
    }
    func resolveConflict() {
        guard let id = conflictTaskID, let remote = state["tasks"].records.first(where: { $0.id == id }), let changes = pending[id] else { return }
        let alert = NSAlert(); alert.messageText = "核对「\(remote.title)」的修改"
        alert.informativeText = changes.map { key, value in
            "\(key)\n本地：\(value.string.isEmpty ? String(describing: value) : value.string)\n另一端：\(remote[key].string.isEmpty ? String(describing: remote[key]) : remote[key].string)"
        }.joined(separator: "\n\n")
        alert.addButton(withTitle: "保存我的修改"); alert.addButton(withTitle: "采用另一端版本"); alert.addButton(withTitle: "暂不处理")
        switch alert.runModal() {
        case .alertFirstButtonReturn: bases[id] = remote; conflictTaskID = nil; Task { await flush() }
        case .alertSecondButtonReturn: pending.removeValue(forKey: id); bases.removeValue(forKey: id); conflictTaskID = nil; error = nil; saveMessage = "已采用另一端版本"; persistDrafts()
        default: break
        }
    }
    func blocked(_ task: Record) -> String? {
        TaskDependencies(tasks).blocked(task)
    }
    func ranked(_ items: [Record]) -> [Record] {
        let now = Date()
        let today = Dates.day(now), tomorrow = Dates.day(now.addingTimeInterval(86400)), nextWeek = Dates.day(now.addingTimeInterval(604800))
        func tier(_ t: Record) -> Int {
            if ["backlog", "blocked", "information", "paused"].contains(t.status) { return 7 }
            if blocked(t) != nil || t.status == "waiting" { return 6 }
            if !t.text("due").isEmpty && String(t.text("due").prefix(10)) <= tomorrow { return 0 }
            if t.status == "active" { return 1 }
            if !t.text("due").isEmpty && String(t.text("due").prefix(10)) <= nextWeek { return 2 }
            if !t.text("reviewDate").isEmpty && String(t.text("reviewDate").prefix(10)) <= today { return 3 }
            return 4
        }
        return items.map { (record: $0, tier: tier($0)) }.sorted { left, right in
            if left.tier != right.tier { return left.tier < right.tier }
            let a = left.record, b = right.record
            let ad = a.text("due").isEmpty ? "9999" : a.text("due")
            let bd = b.text("due").isEmpty ? "9999" : b.text("due")
            if ad != bd { return ad < bd }
            if a.number("priority", 5) != b.number("priority", 5) { return a.number("priority", 5) > b.number("priority", 5) }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }.map(\.record)
    }
}
