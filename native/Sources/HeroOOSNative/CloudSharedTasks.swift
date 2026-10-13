import Foundation
import SwiftUI
import Combine

struct CloudSharedTask: Identifiable, Equatable {
    let id: String
    let revision: Int
    let ownerID: String
    let task: JSON
    var title: String { task["title"].string }
    static func parse(_ value: JSON) throws -> CloudSharedTask {
        let id = value["id"].string, revision = value["revision"].number
        guard CloudSharedDraft.safeID(id), revision >= 1, revision.rounded() == revision, revision < 9e15,
              !value["ownerId"].string.isEmpty, value["task"]["id"].string == id,
              case .object = value["task"] else {
            throw CloudAccountError(code: "invalid_response", message: "共享任务格式不完整，已停止加载。")
        }
        return CloudSharedTask(id: id, revision: Int(revision), ownerID: value["ownerId"].string, task: value["task"])
    }
    func canEdit(userID: String?, isAdmin: Bool) -> Bool { userID != nil && (ownerID == userID || isAdmin) }
}

struct CloudSharedDraft: Identifiable {
    let id: String
    let identity: String
    let expectedRevision: Int
    var task: JSON
    var isNew: Bool { expectedRevision == 0 }

    static func safeID(_ id: String) -> Bool {
        id.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$", options: .regularExpression) != nil
    }
    static func copy(_ source: Record, identity: String, id: String = "shared-" + UUID().uuidString.lowercased()) -> CloudSharedDraft {
        // No catch-all fields, local IDs, project financials, paths, thread IDs,
        // children or dependency edges can escape through this projection.
        let waits: [JSON] = TaskPeopleWaits.entries(source).enumerated().map { index, wait in
            ["id": .string("person-\(index + 1)"), "person": .string(wait.text("person")),
             "outcome": .string(wait.text("outcome")), "resolved": .bool(wait["resolved"].bool)]
        }
        let task: JSON = ["id": .string(id), "title": .string(source.title),
                          "status": .string(TaskStatus(rawValue: source.status)?.rawValue ?? "ready"),
                          "notes": .string(source.text("notes").isEmpty ? source.text("note") : source.text("notes")),
                          "peopleWaits": .array(waits), "availableAt": .string(source.text("availableAt")),
                          "due": .string(source.text("due"))]
        return CloudSharedDraft(id: id, identity: identity, expectedRevision: 0, task: task)
    }
    static func edit(_ shared: CloudSharedTask, identity: String) -> CloudSharedDraft {
        var task = copy(Record(shared.task.object), identity: identity, id: shared.id).task
        task["notes"] = .string(shared.task["notes"].string)
        return CloudSharedDraft(id: shared.id, identity: identity, expectedRevision: shared.revision, task: task)
    }
    func validatedTask() throws -> JSON {
        let title = task["title"].trimmed
        guard Self.safeID(id), !title.isEmpty, title.count <= 400,
              TaskStatus(rawValue: task["status"].string) != nil, task["notes"].string.count <= 16_000,
              task["peopleWaits"].array.count <= 100 else {
            throw CloudAccountError(code: "invalid_input", message: "请填写任务标题（最多 400 字），备注最多 16000 字。")
        }
        // Project once more at the write boundary; even an edited or injected
        // draft cannot accidentally submit extra fields.
        let allowed = task.object.filter { ["title", "status", "notes", "peopleWaits", "availableAt", "due"].contains($0.key) }
        var projected = Self.copy(Record(allowed), identity: identity, id: id).task
        projected["title"] = .string(title)
        return projected
    }
}

@MainActor final class CloudSharedTasksModel: ObservableObject {
    @Published private(set) var tasks: [CloudSharedTask] = []
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var message: String?
    @Published private(set) var needsRefresh = false
    private(set) var identity: String?
    private var generation = 0

    func bind(_ identity: String?) {
        guard self.identity != identity else { return }
        self.identity = identity; generation += 1
        tasks = []; error = nil; message = nil; needsRefresh = false; busy = false
    }
    private func current(_ account: CloudAccount, identity: String, generation: Int) -> Bool {
        self.identity == identity && account.identityKey == identity && self.generation == generation
    }
    private func report(_ failure: Error) {
        if let cloud = failure as? CloudAccountError, ["revision_conflict", "http_409"].contains(cloud.code) {
            needsRefresh = true
            error = "共享任务已被他人更新。本次没有覆盖服务器内容；请取消编辑并刷新，再基于最新版本修改。"
        } else { error = failure.localizedDescription }
    }
    private func reportWrite(_ failure: Error) {
        report(failure)
        let code = (failure as? CloudAccountError)?.code
        if !["revision_conflict", "http_409", "forbidden", "invalid_input", "unauthorized", "http_401"].contains(code ?? "") {
            needsRefresh = true
            error = "未能确认服务器是否已保存：\(failure.localizedDescription)。请取消编辑并刷新确认，避免重复发布或覆盖。"
        }
    }
    func load(account: CloudAccount) async {
        bind(account.identityKey)
        guard let identity, !busy else { return }
        let generation = generation
        busy = true; error = nil
        defer { if current(account, identity: identity, generation: generation) { busy = false } }
        do {
            let result = try await account.authorizedAPI("/v1/shared/tasks")
            guard current(account, identity: identity, generation: generation) else { return }
            guard case .array(let entries) = result["tasks"], entries.count <= 10_000 else {
                throw CloudAccountError(code: "invalid_response", message: "共享任务列表格式无效。")
            }
            let parsed = try entries.map(CloudSharedTask.parse)
            guard Set(parsed.map(\.id)).count == parsed.count else {
                throw CloudAccountError(code: "invalid_response", message: "共享任务存在重复 ID。")
            }
            tasks = parsed; needsRefresh = false
            message = "已读取 \(parsed.count) 项组织共享任务。"
        } catch {
            if current(account, identity: identity, generation: generation) { report(error) }
        }
    }
    @discardableResult func save(_ draft: CloudSharedDraft, account: CloudAccount) async -> Bool {
        guard let identity, identity == draft.identity, account.identityKey == identity, !busy, !needsRefresh else { return false }
        if !draft.isNew {
            guard let existing = tasks.first(where: { $0.id == draft.id }), existing.revision == draft.expectedRevision,
                  existing.canEdit(userID: account.userID, isAdmin: account.canManageMembers) else { return false }
        }
        let generation = generation
        var requestSent = false
        busy = true; error = nil
        defer { if current(account, identity: identity, generation: generation) { busy = false } }
        do {
            let task = try draft.validatedTask()
            let payload: JSON = ["expectedRevision": .number(Double(draft.expectedRevision)),
                                 "mutationId": .string(UUID().uuidString.lowercased()), "task": task]
            requestSent = true
            let result = try await account.authorizedAPI("/v1/shared/tasks/\(draft.id)", method: "PUT", body: payload)
            guard current(account, identity: identity, generation: generation) else { return false }
            let revision = result["revision"].number
            guard result["id"].string == draft.id, revision == Double(draft.expectedRevision + 1), result["ok"].bool else {
                needsRefresh = true
                throw CloudAccountError(code: "invalid_response", message: "保存响应不完整，请刷新确认；不要重复创建共享副本。")
            }
            let oldOwner = tasks.first(where: { $0.id == draft.id })?.ownerID
            let saved = CloudSharedTask(id: draft.id, revision: Int(revision), ownerID: oldOwner ?? account.userID!, task: task)
            tasks.removeAll { $0.id == draft.id }; tasks.append(saved)
            message = draft.isNew ? "已向组织发布共享副本；私人原件未改变，也不会自动跟随共享副本修改。" : "组织共享任务已保存；私人原件未改变。"
            return true
        } catch {
            if current(account, identity: identity, generation: generation) {
                if requestSent { reportWrite(error) } else { report(error) }
            }
            return false
        }
    }
    @discardableResult func withdraw(_ task: CloudSharedTask, account: CloudAccount) async -> Bool {
        guard let identity, account.identityKey == identity, !busy, !needsRefresh,
              task.canEdit(userID: account.userID, isAdmin: account.canManageMembers), CloudSharedDraft.safeID(task.id),
              tasks.contains(task) else { return false }
        let generation = generation
        busy = true; error = nil
        defer { if current(account, identity: identity, generation: generation) { busy = false } }
        do {
            let result = try await account.authorizedAPI("/v1/shared/tasks/\(task.id)?expectedRevision=\(task.revision)", method: "DELETE")
            guard current(account, identity: identity, generation: generation) else { return false }
            guard result["ok"].bool, result["id"].string == task.id, result["revision"].number == Double(task.revision + 1) else {
                throw CloudAccountError(code: "invalid_response", message: "撤回响应不完整，请刷新确认。")
            }
            tasks.removeAll { $0.id == task.id }
            message = "已撤回组织共享；私人原件未删除。"
            return true
        } catch {
            if current(account, identity: identity, generation: generation) { reportWrite(error) }
            return false
        }
    }
}

struct CloudSharedTasksView: View {
    @EnvironmentObject var account: CloudAccount
    @EnvironmentObject var store: OOSStore
    @StateObject private var model = CloudSharedTasksModel()
    @State private var choosing = false
    @State private var search = ""
    @State private var draft: CloudSharedDraft?
    @State private var pendingDraft: CloudSharedDraft?
    @State private var withdrawing: CloudSharedTask?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("组织共享任务").font(.largeTitle.bold())
                        Text(account.session?.organization.name ?? "请先在账号与组织页面登录").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                    Button("刷新") { Task { await model.load(account: account) } }.disabled(account.session == nil || model.busy)
                    Button("从我的任务共享") { choosing = true }.disabled(account.session == nil || model.busy || model.needsRefresh)
                }
                Text("这里是组织成员可见的协作副本。只在你预览并确认后发布；不自动共享本地任务、不回写私人原件，也不会自动同步原件后续修改。")
                    .font(.callout).foregroundStyle(.secondary)
                if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                if account.session != nil, model.tasks.isEmpty, !model.busy { Text("组织还没有共享任务。").padding(.vertical, 24).foregroundStyle(.secondary) }
                ForEach(model.tasks) { task in sharedCard(task) }
            }.padding(28).frame(maxWidth: 1050, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task(id: account.identityKey) {
            choosing = false; draft = nil; pendingDraft = nil; withdrawing = nil; search = ""
            model.bind(account.identityKey)
            await model.load(account: account)
        }
        .sheet(isPresented: $choosing, onDismiss: {
            if pendingDraft?.identity == account.identityKey { draft = pendingDraft }
            pendingDraft = nil
        }) { chooser }
        .sheet(item: $draft) { value in
            CloudSharedTaskEditor(draft: value, model: model, account: account) { draft = nil }
        }
        .alert("撤回组织共享？", isPresented: Binding(get: { withdrawing != nil }, set: { if !$0 { withdrawing = nil } })) {
            Button("取消", role: .cancel) { withdrawing = nil }
            Button("撤回共享", role: .destructive) {
                if let task = withdrawing { Task { _ = await model.withdraw(task, account: account) } }
                withdrawing = nil
            }
        } message: { Text("组织成员将不再看到这个共享副本；私人原件不会被删除。") }
    }
    private var chooser: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("选择要共享的任务").font(.title2.bold())
            Text("下一步将预览内容，尚未向服务器发布。").foregroundStyle(.secondary)
            TextField("搜索任务名称", text: $search).textFieldStyle(.roundedBorder)
            List(store.tasks.filter { !$0.isArchived && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }) { task in
                Button {
                    guard let identity = account.identityKey else { return }
                    pendingDraft = CloudSharedDraft.copy(task, identity: identity)
                    choosing = false
                } label: { Text(task.title).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
            }.frame(height: 320)
            HStack { Spacer(); Button("取消") { choosing = false }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 560)
    }
    private func sharedCard(_ shared: CloudSharedTask) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Text(shared.title).font(.headline).textSelection(.enabled)
                    Spacer()
                    Text(TaskStatus(rawValue: shared.task["status"].string)?.title ?? shared.task["status"].string).foregroundStyle(.secondary)
                }
                if !shared.task["notes"].string.isEmpty { Text(shared.task["notes"].string).textSelection(.enabled) }
                SharedTaskConditionsPreview(task: shared.task)
                HStack {
                    Text(shared.ownerID == account.userID ? "我发布的 · 版本 \(shared.revision)" : "组织共享 · 版本 \(shared.revision)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if shared.canEdit(userID: account.userID, isAdmin: account.canManageMembers) {
                        Button("编辑共享副本") {
                            guard let identity = account.identityKey else { return }
                            draft = .edit(shared, identity: identity)
                        }
                        Button("撤回共享") { withdrawing = shared }
                    }
                }.disabled(model.busy || model.needsRefresh)
            }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SharedTaskConditionsPreview: View {
    let task: JSON
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(task["peopleWaits"].array.enumerated()), id: \.offset) { _, wait in
                Text("\(wait["resolved"].bool ? "已解除等人" : "等人")：\(wait["person"].string)\(wait["outcome"].string.isEmpty ? "" : " · " + wait["outcome"].string)")
            }
            if !task["availableAt"].string.isEmpty { Text("可开始时间：\(task["availableAt"].string)") }
            if !task["due"].string.isEmpty { Text("截止时间：\(task["due"].string)") }
        }.font(.caption).foregroundStyle(.secondary)
    }
}

private struct CloudSharedTaskEditor: View {
    @State var draft: CloudSharedDraft
    @ObservedObject var model: CloudSharedTasksModel
    @ObservedObject var account: CloudAccount
    let dismiss: () -> Void
    private func text(_ key: String) -> Binding<String> {
        Binding(get: { draft.task[key].string }, set: { draft.task[key] = .string($0) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.isNew ? "确认共享内容" : "编辑组织共享副本").font(.title2.bold())
            Text("目标组织：\(account.session?.organization.name ?? "未登录") · 所有已获准的组织成员可见").foregroundStyle(.secondary)
            TextField("任务标题", text: text("title")).textFieldStyle(.roundedBorder)
            Picker("状态", selection: text("status")) { ForEach(TaskStatus.allCases) { status in Text(status.title).tag(status.rawValue) } }
            Text("备注 / 说明").font(.caption)
            TextEditor(text: text("notes")).frame(height: 140).border(.secondary.opacity(0.3))
            SharedTaskConditionsPreview(task: draft.task)
            Text("只发布上面这些基本内容，不包含子任务、依赖线、账款字段、本机路径字段或 Codex 对话字段。请同时检查标题和备注中是否写有不想共享的隐私。私人原件保持独立。").font(.caption).foregroundStyle(.secondary)
            if let error = model.error { Text(error).foregroundStyle(.orange).font(.callout) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy)
                Spacer()
                Button(draft.isNew ? "确认发布到组织" : "保存共享副本") {
                    Task { if await model.save(draft, account: account) { dismiss() } }
                }.buttonStyle(.borderedProminent)
                    .disabled(model.busy || model.needsRefresh || draft.identity != account.identityKey || draft.task["title"].trimmed.isEmpty)
            }
        }.padding(24).frame(width: 600)
            .interactiveDismissDisabled(model.busy)
    }
}
