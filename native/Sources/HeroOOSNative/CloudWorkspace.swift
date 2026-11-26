import Foundation
import Combine
import CryptoKit
import SwiftUI

@MainActor final class CloudWorkspace: ObservableObject {
    @Published private(set) var store: OOSStore
    @Published private(set) var collage: CollageStore
    @Published private(set) var sync: CloudSync?
    @Published private(set) var personalSync: CloudSync?
    @Published private(set) var ready = false
    @Published private(set) var switching = false
    @Published private(set) var error: String?
    @Published private(set) var importing = false
    @Published private(set) var isCloudAccount = false
    @Published private(set) var accountLabel = "本机工作区"
    @Published private(set) var importedLocalTasks = false
    private let localStore: OOSStore
    private let localCollage: CollageStore
    private let localRoot: URL
    private let accountsRoot: URL
    private var activeIdentity: String?
    private var generation = 0
    private var initialized = false
    private var localChanges: AnyCancellable?
    private var events: CloudTaskEventStream?
    private let eventTransport: any ServerEventTransport
    private let makeStores: @MainActor (URL) -> (OOSStore, CollageStore)

    init(localRoot: URL = OOSAPI().base,
         accountsRoot: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hero OOS/accounts", isDirectory: true),
         makeStores: (@MainActor (URL) -> (OOSStore, CollageStore))? = nil,
         eventTransport: (any ServerEventTransport)? = nil) {
        self.localRoot = localRoot; self.accountsRoot = accountsRoot
        self.eventTransport = eventTransport ?? URLSessionServerEventTransport()
        self.makeStores = makeStores ?? { root in
            let api = OOSAPI(base: root); return (OOSStore(api: api), CollageStore(api: api))
        }
        let initialStores = self.makeStores(localRoot)
        localStore = initialStores.0; localCollage = initialStores.1
        store = localStore; collage = localCollage
    }
    func matches(account: CloudAccount) -> Bool { ready && initialized && activeIdentity == account.identityKey }
    static func accountDirectory(serverID: String, userID: String, organizationID: String? = nil, under root: URL) -> URL {
        let identity = JSON.array([.string(serverID), .string(userID)] + (organizationID.map { [.string($0)] } ?? []))
        let bytes = (try? JSONEncoder().encode(identity)) ?? Data()
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(digest, isDirectory: true)
    }
    private var importMarker: URL { store.api.base.appendingPathComponent("data/local-workspace-import.json") }

    /// The caller must hide the task UI while ready == false; stale account stores are never presented after failure.
    func activate(account: CloudAccount) async {
        let requested = account.identityKey
        if requested == activeIdentity && ready { return }
        generation += 1; let currentGeneration = generation
        if initialized, requested == activeIdentity {
            // An authenticated return to the original identity must allow editing the very drafts
            // that blocked leaving it. Never expose this store under the newly requested identity.
            ready = true; switching = false
            error = "已返回原工作区。未保存的编辑仍在，请先修正或核对冲突，再切换账号。"
            await store.start()
            observeLocalChanges()
            if currentGeneration == generation, account.identityKey == requested {
                await sync?.start(); await personalSync?.start()
                startEvents(account: account)
            }
            return
        }
        ready = false; switching = true; error = nil
        localChanges = nil
        events?.stop(); events = nil
        sync?.stop()
        personalSync?.stop()
        defer { if generation == currentGeneration { switching = false } }
        let previousStore = store, previousCollage = collage
        guard !previousCollage.importing else { error = "图片仍在导入，暂不能切换。请退出当前账号并返回原账号（原本机工作区直接退出即可），待导入结束后重试。"; return }
        NotificationCenter.default.post(name: .commitInlineTaskTitle, object: nil)
        guard await previousStore.flush(), await previousCollage.save() else {
            error = "原工作区仍有未保存编辑或冲突，已暂停切换。请退出当前登录，再登录原账号恢复编辑；原工作区是本机时，直接退出即可返回。"; return
        }
        guard currentGeneration == generation, account.identityKey == requested else { return }
        previousStore.stop()
        do {
            if let userID = account.userID, let organizationID = account.organizationID, let requested {
                let root = Self.accountDirectory(serverID: account.api.serverID, userID: userID, organizationID: organizationID, under: accountsRoot)
                let journalURL = root.appendingPathComponent("data/cloud-organization-sync-v2.json")
                let personalJournalURL = root.appendingPathComponent("data/cloud-personal-sync-v2.json")
                let stateExisted = FileManager.default.fileExists(atPath: root.appendingPathComponent("data/state.json").path)
                let runtime = StateRuntime(root: root)
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    try runtime.initializeIfNeeded()
                }.value
                guard currentGeneration == generation, account.identityKey == requested else { return }
                let initialBase: JSON? = !stateExisted ? try await Task.detached { try runtime.organizationState() }.value : nil
                let personalBase: JSON? = !stateExisted ? try await Task.detached { try runtime.personalTaskState() }.value : nil
                // Persist the seed before publishing a new editable workspace.
                if let initialBase, !FileManager.default.fileExists(atPath: journalURL.path) {
                    try CloudSyncJournalFile(url: journalURL).write(CloudSyncJournal(serverID: account.api.serverID, userID: userID, organizationID: organizationID,
                        serverRevision: 0, baseDocument: CloudSync.document(initialBase), pending: nil))
                }
                if let personalBase, !FileManager.default.fileExists(atPath: personalJournalURL.path) {
                    try CloudSyncJournalFile(url: personalJournalURL).write(CloudSyncJournal(serverID: account.api.serverID, userID: userID,
                        serverRevision: 0, baseDocument: CloudSync.document(personalBase, scope: .personal), pending: nil))
                }
                // An explicit launch request is bound to this exact server + organization + user.
                // Copy before exposing an editable store or starting either network engine.
                if Self.requestedLocalImport(identity: requested, arguments: ProcessInfo.processInfo.arguments),
                   !FileManager.default.fileExists(atPath: root.appendingPathComponent("data/" + LocalWorkspaceImport.markerName).path) {
                    importing = true
                    defer { importing = false }
                    let source = StateRuntime(root: localRoot)
                    _ = try await Task.detached(priority: .userInitiated) {
                        try LocalWorkspaceImport.perform(source: source, destination: runtime)
                    }.value
                    Self.restoreGraphLayout(from: localStore.api.draftIdentity, to: OOSAPI(base: root).draftIdentity)
                }
                let (nextStore, nextCollage) = makeStores(root)
                await nextStore.start(); await nextCollage.load()
                guard currentGeneration == generation, account.identityKey == requested else { nextStore.stop(); return }
                store = nextStore; collage = nextCollage; activeIdentity = requested
                isCloudAccount = true; accountLabel = "\(account.session?.organization.name ?? "") · 组织任务 / 私人云端"
                importedLocalTasks = FileManager.default.fileExists(atPath: importMarker.path)
                let nextSync = CloudSync(account: account, local: CloudSyncRuntime(runtime: runtime), journalStorage: CloudSyncJournalFile(url: journalURL),
                                        initialBase: initialBase, saveLocal: { [weak nextStore] in
                    guard let nextStore else { return false }
                    let saved = await nextStore.flush()
                    return saved && !nextStore.hasUnsavedChanges
                }, refreshLocal: { [weak nextStore] in await nextStore?.refresh() })
                let nextPersonalSync = CloudSync(account: account, local: CloudSyncRuntime(runtime: runtime, scope: .personal),
                    journalStorage: CloudSyncJournalFile(url: personalJournalURL), initialBase: personalBase, scope: .personal,
                    saveLocal: { [weak nextStore] in
                        guard let nextStore else { return false }
                        let saved = await nextStore.flush()
                        return saved && !nextStore.hasUnsavedChanges
                    }, refreshLocal: { [weak nextStore] in await nextStore?.refresh() })
                sync = nextSync; personalSync = nextPersonalSync; initialized = true; ready = true
                observeLocalChanges()
                async let organizationStart: Void = nextSync.start()
                async let personalStart: Void = nextPersonalSync.start()
                _ = await (organizationStart, personalStart)
                if currentGeneration == generation, account.identityKey == requested { startEvents(account: account) }
            } else {
                await localStore.start(); await localCollage.load()
                guard currentGeneration == generation, account.session == nil else { localStore.stop(); return }
                store = localStore; collage = localCollage; activeIdentity = nil
                sync = nil; personalSync = nil; isCloudAccount = false; accountLabel = "本机工作区"; importedLocalTasks = false; initialized = true; ready = true
            }
        } catch {
            if currentGeneration == generation { self.error = error.localizedDescription; ready = false }
        }
    }

    private func observeLocalChanges() {
        let organizationSync = sync, ownerSync = personalSync
        localChanges = store.$state.map { $0["meta"]["version"].number }
            .removeDuplicates().debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak organizationSync, weak ownerSync] _ in
                Task { await organizationSync?.localDidChange(); await ownerSync?.localDidChange() }
            }
    }

    private func startEvents(account: CloudAccount) {
        events?.stop()
        guard isCloudAccount, activeIdentity == account.identityKey, let sync, let personalSync else { events = nil; return }
        let stream = CloudTaskEventStream(account: account, transport: eventTransport,
            onState: { [weak sync, weak personalSync] state, first in
                Task {
                    await sync?.serverChanged(revision: state.organizationRevision, reconnected: first)
                    await personalSync?.serverChanged(revision: state.personalRevision, reconnected: first)
                }
            }, onConnection: { [weak sync, weak personalSync] connected, error in
                sync?.pushConnectionChanged(connected: connected, error: error)
                personalSync?.pushConnectionChanged(connected: connected, error: error)
            })
        events = stream; stream.start()
    }

    static func requestedLocalImport(identity: String, arguments: [String]) -> Bool {
        guard let index = arguments.firstIndex(of: "--import-local-workspace-for"), arguments.indices.contains(index + 1) else { return false }
        return !identity.isEmpty && arguments[index + 1] == identity
    }

    /// Explicit local copy; isolated organization and owner-only task projections sync afterwards.
    func importLocalTasks(account: CloudAccount) async {
        guard !importing, ready, isCloudAccount, activeIdentity == account.identityKey,
              !importedLocalTasks, sync?.busy != true, personalSync?.busy != true else { return }
        importing = true; error = nil
        let identity = activeIdentity, destination = store.api.runtime, source = StateRuntime(root: localRoot)
        let destinationDraftIdentity = store.api.draftIdentity
        let currentSync = sync
        let currentPersonalSync = personalSync
        currentSync?.stop()
        currentPersonalSync?.stop()
        events?.stop(); events = nil
        defer { importing = false }
        do {
            guard !collage.importing, !localCollage.importing,
                  await store.flush(), await localStore.flush(), await collage.save(), await localCollage.save() else {
                throw NativeError.message("仍有未保存编辑或图片正在导入，暂不能迁移。")
            }
            guard account.identityKey == identity, activeIdentity == identity else {
                throw NativeError.message("账号已切换，导入已取消。")
            }
            _ = try await Task.detached(priority: .userInitiated) {
                try LocalWorkspaceImport.perform(source: source, destination: destination)
            }.value
            Self.restoreGraphLayout(from: localStore.api.draftIdentity, to: destinationDraftIdentity)
            guard account.identityKey == identity, activeIdentity == identity else {
                throw NativeError.message("迁移已保存在原账号的本机目录，未对新账号操作。")
            }
            importedLocalTasks = true
            await store.refresh(); await collage.load()
        } catch { self.error = error.localizedDescription }
        if activeIdentity == identity, account.identityKey == identity {
            await currentSync?.start(); await currentPersonalSync?.start()
            startEvents(account: account)
        }
    }

    static func restoreGraphLayout(from sourceIdentity: String, to destinationIdentity: String,
                                   defaults: UserDefaults = .standard) {
        let prefix = "HeroOOS.taskGraph.v1."
        let sourceKey = prefix + sourceIdentity, destinationKey = prefix + destinationIdentity
        guard sourceKey != destinationKey, let data = defaults.data(forKey: sourceKey),
              let original = try? JSONDecoder().decode(GraphLayout.self, from: data), !original.positions.isEmpty else { return }
        if let existing = defaults.data(forKey: destinationKey) {
            guard let layout = try? JSONDecoder().decode(GraphLayout.self, from: existing), layout.positions.isEmpty else { return }
        }
        defaults.set(data, forKey: destinationKey)
        defaults.set(defaults.bool(forKey: sourceKey + ".unfinishedDefault"), forKey: destinationKey + ".unfinishedDefault")
    }
    static func mergeImport(existing: JSON, source: JSON) throws -> JSON {
        var result = existing
        // Only state content is imported, never camera positions, account information or image files.
        for (key, incoming) in source.object {
            if case .array(let incomingItems) = incoming {
                guard incomingItems.allSatisfy({ !$0["id"].string.isEmpty }) else {
                    if existing[key] == incoming || incomingItems.isEmpty { continue }
                    if existing[key] == .null || existing[key] == .array([]) { result[key] = incoming; continue }
                    throw NativeError.message("本机与云端的 \(key) 内容不同，已停止导入，未覆盖现有数据。")
                }
                var items = existing[key].array
                for item in incomingItems {
                    if let index = items.firstIndex(where: { $0["id"] == item["id"] }) {
                        guard items[index] == item else { throw NativeError.message("同名任务或板块已存在不同内容，已停止导入，未覆盖现有数据。") }
                    } else { items.append(item) }
                }
                result[key] = .array(items)
            } else if existing[key] == .null { result[key] = incoming }
        }
        return result
    }
}

struct CloudWorkspaceStatusView: View {
    @EnvironmentObject var account: CloudAccount
    @EnvironmentObject var workspace: CloudWorkspace
    @State private var confirmImport = false
    var body: some View {
        GroupBox("数据与同步") {
            VStack(alignment: .leading, spacing: 10) {
                if !workspace.matches(account: account) {
                    Text("工作区切换尚未完成，上一账号的数据和同步详情已隐藏。请按下方提示恢复原工作区，或重试加载。")
                        .foregroundStyle(.secondary)
                } else if workspace.isCloudAccount {
                    Text("非私人任务及依赖同步到当前组织，获准成员共同管理。私人任务同步到你自己的云端空间，仅本人可见。")
                    if let sync = workspace.sync { CloudSyncStatus(sync: sync) }
                    if let sync = workspace.personalSync { CloudSyncStatus(sync: sync) }
                    Text("拼图画布、文本及图片仅保存在本机，不上传也不共享。换电脑不会自动带过去。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !workspace.importedLocalTasks {
                        Button("迁入原本机任务和拼图…") { confirmImport = true }
                            .disabled(workspace.importing || !workspace.ready || workspace.sync?.busy == true || workspace.personalSync?.busy == true)
                    } else { Text("已迁入原本机任务和拼图；原文件仍保留。").font(.caption).foregroundStyle(.secondary) }
                } else {
                    Text("当前使用原本机工作区。登录后切换到账号与组织隔离的工作区；导入旧任务须确认，私人任务仅同步给自己，拼图不会上传。")
                }
                if workspace.importing { ProgressView("正在复制任务、拼图和本机图片…") }
                if let error = workspace.error { Text(error).foregroundStyle(.orange) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
        .confirmationDialog("迁入原本机任务和拼图？", isPresented: $confirmImport, titleVisibility: .visible) {
            Button("确认复制并同步") { Task { await workspace.importLocalTasks(account: account) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("全部任务、拼图与图片复制到当前账号的本机目录。只有非私人任务同步到当前组织，组织成员可管理；私人任务单独同步到本人云端，不向组织共享；拼图绝不上传。保留原文件，遇到冲突停止，不覆盖。")
        }
    }
}
struct CloudSyncStatus: View {
    @ObservedObject var sync: CloudSync
    @State private var reviewing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if sync.busy { ProgressView().controlSize(.small) }
                Label("\(sync.scope.title)：\(sync.statusLabel)", systemImage: sync.phase.symbol)
                    .foregroundStyle(sync.phase.tint)
                Spacer()
                if sync.hasConflict {
                    Button("核对冲突…") { Task { await sync.reviewConflict(); reviewing = sync.conflict != nil } }.disabled(sync.busy)
                }
                Button(sync.paused ? "恢复同步" : "立即同步") {
                    Task { if sync.paused { await sync.resume() } else { await sync.retry() } }
                }.disabled(sync.busy)
            }
            if let date = sync.lastSyncedAt { Text("上次服务端确认：\(date.formatted(date: .abbreviated, time: .standard))").font(.caption).foregroundStyle(.secondary) }
            if let error = sync.error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            if let path = sync.recoveryFile {
                Text("恢复副本：\(path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .sheet(isPresented: $reviewing) { CloudConflictReviewView(sync: sync) }
    }
}

struct CloudConflictReviewView: View {
    @ObservedObject var sync: CloudSync
    @Environment(\.dismiss) private var dismiss
    @State private var choice: CloudConflictChoice?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("核对云端冲突").font(.title2.bold())
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction).disabled(sync.busy)
            }
            if let conflict = sync.conflict {
                Text("云端版本 \(conflict.serverRevision) · 核对时间 \(conflict.recordedAt)").font(.caption).foregroundStyle(.secondary)
                Text("下面是两份文档的不同内容。选择将作用于整份任务文档（任务、板块、依赖等），不是仅当前字段。执行前会保存双方完整恢复副本；若任一端有新修改，必须重新核对。")
                    .font(.callout)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(conflict.differences.prefix(200))) { difference in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(difference.path).font(.caption.bold()).textSelection(.enabled)
                                HStack(alignment: .top, spacing: 16) {
                                    differenceValue("本机", difference.local)
                                    differenceValue("云端", difference.remote)
                                }
                            }.padding(10).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        }
                        if conflict.differences.isEmpty { Text("当前两侧内容相同，可以关闭后再次同步。").foregroundStyle(.secondary) }
                        if conflict.differences.count > 200 {
                            Text("差异较多，此处显示前 200 项。整份恢复副本会包含双方全部内容。").foregroundStyle(.orange)
                        }
                    }
                }.frame(minHeight: 220, maxHeight: 430)
                if let error = sync.error { Text(error).foregroundStyle(.orange).font(.callout) }
                HStack {
                    Button("重新读取两侧") { Task { await sync.reviewConflict() } }.disabled(sync.busy)
                    Spacer()
                    Button("使用本机内容…") { choice = .local }.disabled(sync.busy)
                    Button("使用云端内容…") { choice = .remote }.disabled(sync.busy)
                }
                if sync.busy { ProgressView("正在保存恢复副本并核验版本…") }
            } else { Text("当前没有待核对冲突。").foregroundStyle(.secondary) }
        }.padding(24).frame(width: 780)
        .confirmationDialog("确认使用整份\(choice == .local ? "本机" : "云端")任务文档？", isPresented: Binding(get: { choice != nil }, set: { if !$0 { choice = nil } }), titleVisibility: .visible, presenting: choice) { selected in
            Button("确认：保留恢复副本并应用整份文档", role: .destructive) {
                guard let id = sync.conflict?.id else { return }
                choice = nil
                Task { if await sync.resolveConflict(id: id, choice: selected) { dismiss() } }
            }
            Button("取消", role: .cancel) { choice = nil }
        } message: { _ in
            Text("另一侧的不同内容会被替换，但双方完整内容会先保存在本机恢复文件。未保存或核对后发生变化的内容不会被静默覆盖。")
        }
    }
    private func differenceValue(_ label: String, _ value: JSON?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(String(CloudConflictDifference.text(value).prefix(4000))).font(.callout).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
