import Foundation
import Combine

enum CloudConflictChoice: String, Codable { case local, remote }
struct CloudConflictDifference: Identifiable {
    let path: String
    let local: JSON?
    let remote: JSON?
    var id: String { path }
    static func text(_ value: JSON?) -> String {
        guard let value else { return "（不存在或已删除）" }
        if case .string(let text) = value { return text }
        return (try? String(data: value.encoded(pretty: true), encoding: .utf8)) ?? "（无法显示）"
    }
}
struct CloudSyncConflict: Codable, Equatable, Identifiable {
    let id: String
    let serverRevision: Int
    let baseDocument: JSON
    let localDocument: JSON
    let remoteDocument: JSON
    let recordedAt: String
    var differences: [CloudConflictDifference] {
        var result: [CloudConflictDifference] = []
        func visit(_ local: JSON?, _ remote: JSON?, path: String, depth: Int) {
            guard result.count < 201, local != remote else { return }
            if depth < 32, case .some(.object(let left)) = local, case .some(.object(let right)) = remote {
                for key in Set(left.keys).union(right.keys).sorted() { visit(left[key], right[key], path: path.isEmpty ? key : "\(path).\(key)", depth: depth + 1) }
            } else if depth < 32, case .some(.array(let left)) = local, case .some(.array(let right)) = remote,
                      (left + right).allSatisfy({ !$0["id"].string.isEmpty }),
                      Set(left.map { $0["id"].string }).count == left.count, Set(right.map { $0["id"].string }).count == right.count {
                let a = Dictionary(uniqueKeysWithValues: left.map { ($0["id"].string, $0) })
                let b = Dictionary(uniqueKeysWithValues: right.map { ($0["id"].string, $0) })
                for id in Set(a.keys).union(b.keys).sorted() {
                    let title = a[id]?["title"].string ?? b[id]?["title"].string ?? ""
                    visit(a[id], b[id], path: "\(path)[\(title.isEmpty ? id : title + " · " + id)]", depth: depth + 1)
                }
            } else { result.append(CloudConflictDifference(path: path, local: local, remote: remote)) }
        }
        visit(localDocument["state"], remoteDocument["state"], path: "", depth: 0)
        return result
    }
}
struct CloudSyncConflictBackup: Codable {
    let conflict: CloudSyncConflict
    let choice: CloudConflictChoice
    let journalBefore: CloudSyncJournal
}

struct CloudSyncPending: Codable, Equatable {
    let mutationID: String
    let expectedRevision: Int
    let document: JSON
    let localBefore: JSON
    var acknowledgedRevision: Int?
    var requestBody: JSON {
        ["mutationId": .string(mutationID), "expectedRevision": .number(Double(expectedRevision)), "document": document]
    }
}
struct CloudSyncJournal: Codable, Equatable {
    let serverID: String
    let userID: String
    var organizationID: String? = nil
    var serverRevision: Int
    var baseDocument: JSON
    var pending: CloudSyncPending?
    // Optional fields keep pre-status journals readable without changing their synchronization baseline.
    var paused: Bool? = nil
    var lastSyncedAt: Date? = nil
    var lastCheckedAt: Date? = nil
}

enum CloudSyncPhase: String {
    case notChecked, pending, upToDate, syncing, paused, offline, conflict, authenticationRequired, error
}
protocol CloudSyncJournalStorage {
    func read() throws -> CloudSyncJournal?
    func write(_ journal: CloudSyncJournal) throws
    func archive(_ backup: CloudSyncConflictBackup) throws -> String
}
struct CloudSyncJournalFile: CloudSyncJournalStorage {
    let url: URL
    func read() throws -> CloudSyncJournal? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(CloudSyncJournal.self, from: Data(contentsOf: url))
    }
    func write(_ journal: CloudSyncJournal) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(journal).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func archive(_ backup: CloudSyncConflictBackup) throws -> String {
        let folder = url.deletingLastPathComponent().appendingPathComponent("cloud-conflicts", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("\(UUID().uuidString)-\(backup.choice.rawValue).json")
        try JSONEncoder().encode(backup).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let handle = try FileHandle(forWritingTo: file)
        try handle.synchronize(); try handle.close()
        return file.path
    }
}
protocol CloudSyncLocalStorage {
    func snapshot() async throws -> JSON
    func validate(_ state: JSON) throws
    func apply(_ incoming: JSON, expected: JSON) async throws
    func normalize(_ state: JSON) -> JSON
    func validateUpload(_ state: JSON) async throws
}
extension CloudSyncLocalStorage {
    func normalize(_ state: JSON) -> JSON { state }
    func validateUpload(_ state: JSON) async throws {}
}
enum CloudTaskScope: String {
    case organization = "organization-tasks", personal = "personal-tasks"
    var endpoint: String { self == .organization ? "/v1/organization/state" : "/v1/personal/state" }
    var title: String { self == .organization ? "组织任务" : "私人任务" }
}
struct CloudSyncRuntime: CloudSyncLocalStorage {
    let runtime: StateRuntime
    var scope: CloudTaskScope = .organization
    func normalize(_ state: JSON) -> JSON {
        scope == .organization ? StateRuntime.organizationProjection(state) : StateRuntime.personalTaskProjection(state)
    }
    func validateUpload(_ state: JSON) async throws {
        let current = try await Task.detached { try runtime.readState() }.value
        let oppositeIDs = Set(current["tasks"].array.filter {
            ($0["taskSpace"].string == TaskSpace.personal.rawValue) != (scope == .personal)
        }.map { $0["id"].string })
        guard !state["tasks"].array.contains(where: { oppositeIDs.contains($0["id"].string) }) else {
            throw CloudAccountError(code: "task_scope_changed", message: "待发送任务已切换私人／组织归属，已暂停旧记录上传。请核对云端冲突，避免向错误范围发送内容。")
        }
    }
    func validate(_ state: JSON) throws {
        if scope == .organization { try runtime.validateOrganizationState(state) }
        else { try runtime.validatePersonalTaskState(state) }
    }
    func snapshot() async throws -> JSON {
        try await Task.detached(priority: .utility) {
            try scope == .organization ? runtime.organizationState() : runtime.personalTaskState()
        }.value
    }
    func apply(_ incoming: JSON, expected: JSON) async throws {
        _ = try await Task.detached(priority: .utility) {
            try scope == .organization ? runtime.applyOrganizationState(incoming, expected: expected)
                : runtime.applyPersonalTaskState(incoming, expected: expected)
        }.value
    }
}

/// Only the allowlisted non-private task projection crosses the network.
@MainActor final class CloudSync: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var hasConflict = false
    @Published private(set) var error: String?
    @Published private(set) var message = "正在连接组织任务"
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var nextRetryAt: Date?
    @Published private(set) var phase: CloudSyncPhase = .notChecked
    @Published private(set) var pendingCount = 0
    @Published private(set) var paused = false
    @Published private(set) var conflict: CloudSyncConflict?
    @Published private(set) var recoveryFile: String?
    private let account: CloudAccount
    private let identity: String
    private let serverID: String
    private let userID: String
    private let organizationID: String
    let scope: CloudTaskScope
    private let local: any CloudSyncLocalStorage
    private let journalStorage: any CloudSyncJournalStorage
    private let saveLocal: () async -> Bool
    private let refreshLocal: () async -> Void
    private let initialBase: JSON?
    private var journal: CloudSyncJournal?
    private var timer: Task<Void, Never>?
    private var requestedRemoteRevision = 0
    private var forceReconcile = false
    private var localWorkRequested = false
    private var pushConnected: Bool?
    private var stopped = false
    private var transientPhase: CloudSyncPhase?
    private var consecutiveFailures = 0
    private let now: () -> Date

    var statusLabel: String {
        switch phase {
        case .notChecked: return pushConnected == false ? "推送连接重试中" : "服务端待核对"
        case .pending: return "\(pendingCount) 项待同步"
        case .upToDate: return "服务端已同步"
        case .syncing: return "正在同步服务端"
        case .paused: return pendingCount > 0 ? "已暂停 · \(pendingCount) 项待同步" : "自动同步已暂停"
        case .offline: return pendingCount > 0 ? "离线 · \(pendingCount) 项待同步" : "离线 · 本机可用"
        case .conflict: return "同步冲突 · 需核对"
        case .authenticationRequired: return "需要重新登录"
        case .error: return pendingCount > 0 ? "同步失败 · \(pendingCount) 项待同步" : "服务端暂不可用"
        }
    }

    init(account: CloudAccount, local: any CloudSyncLocalStorage, journalStorage: any CloudSyncJournalStorage,
         initialBase: JSON?, scope: CloudTaskScope = .organization,
         saveLocal: @escaping () async -> Bool, refreshLocal: @escaping () async -> Void,
         now: @escaping () -> Date = Date.init) {
        self.account = account; identity = account.identityKey ?? ""; serverID = account.api.serverID; userID = account.userID ?? ""
        organizationID = account.organizationID ?? ""
        self.scope = scope; message = "正在连接\(scope.title)"
        self.local = local; self.journalStorage = journalStorage; self.initialBase = initialBase
        self.saveLocal = saveLocal; self.refreshLocal = refreshLocal
        self.now = now
    }
    deinit { timer?.cancel() }
    func stop() { stopped = true; timer?.cancel(); timer = nil }
    func start() async {
        stopped = false
        await synchronize()
    }
    /// 10, 20, 40, 80, 160, 300 seconds; a manual retry need not wait for this timer.
    static func retryDelay(afterFailures failures: Int) -> TimeInterval {
        min(300, 10 * pow(2, Double(min(5, max(0, failures - 1)))))
    }
    func automaticTick() async {
        await refreshLocalStatus()
        if pendingCount == 0 { localWorkRequested = false }
        guard !paused, !hasConflict, transientPhase != .authenticationRequired,
              nextRetryAt.map({ now() >= $0 }) ?? true else { return }
        guard pendingCount > 0 || journal?.pending != nil || forceReconcile ||
              requestedRemoteRevision > (journal?.serverRevision ?? 0) || lastCheckedAt == nil || nextRetryAt != nil else { return }
        await synchronize()
    }
    /// Saves trigger uploads; remote-applied saves with no local changes do not issue another GET.
    func localDidChange() async {
        await refreshLocalStatus()
        guard pendingCount > 0 else { return }
        localWorkRequested = true
        guard !busy else { return }
        await automaticTick()
    }
    /// Notifications are hints. Existing revision/CAS/three-way merge still validates all contents.
    func serverChanged(revision: Int, reconnected: Bool = false) async {
        guard revision >= 0, !stopped, account.identityKey == identity else { return }
        requestedRemoteRevision = max(requestedRemoteRevision, revision)
        if reconnected { forceReconcile = true }
        guard !busy else { return }
        await automaticTick()
    }
    func pushConnectionChanged(connected: Bool, error: Error? = nil) {
        guard !stopped, account.identityKey == identity else { return }
        pushConnected = connected
        if !connected {
            if let code = (error as? CloudAccountError)?.code, ["unauthorized", "forbidden"].contains(code), let error {
                recordFailure(error)
            } else {
                message = "服务端通知连接中断，正在自动重连；本机编辑照常保存，待发送内容继续排队。"
            }
        }
        updateStatus()
    }
    /// Only pending local work or a known missed remote revision gets a retry timer.
    /// An idle, acknowledged workspace never periodically downloads task documents.
    private func scheduleWork() {
        timer?.cancel(); timer = nil
        guard !stopped, !paused, !hasConflict, transientPhase != .authenticationRequired,
              pendingCount > 0 || journal?.pending != nil || forceReconcile ||
              requestedRemoteRevision > (journal?.serverRevision ?? 0) || localWorkRequested || nextRetryAt != nil else { return }
        let delay = max(0, nextRetryAt?.timeIntervalSince(now()) ?? 0)
        timer = Task { [weak self] in
            do { if delay > 0 { try await Task.sleep(for: .seconds(delay)) } }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.timer = nil
            await self?.automaticTick()
        }
    }
    private func updateStatus() {
        if transientPhase == .authenticationRequired { phase = .authenticationRequired }
        else if paused { phase = .paused }
        else if busy { phase = .syncing }
        else if hasConflict { phase = .conflict }
        else if let transientPhase { phase = transientPhase }
        else if pendingCount > 0 { phase = .pending }
        else { phase = lastCheckedAt == nil || pushConnected == false ? .notChecked : .upToDate }
    }
    /// Count changed entities, not keystrokes or network requests. Deletions count too.
    static func pendingEntityCount(base: JSON, current: JSON) -> Int {
        guard base != current else { return 0 }
        var count = 0
        for key in Set(base.object.keys).union(current.object.keys) {
            guard base[key] != current[key] else { continue }
            let before = base[key].array, after = current[key].array
            if case .array = base[key], case .array = current[key],
               (before + after).allSatisfy({ !$0["id"].string.isEmpty }),
               Set(before.map { $0["id"].string }).count == before.count,
               Set(after.map { $0["id"].string }).count == after.count {
                let a = Dictionary(uniqueKeysWithValues: before.map { ($0["id"].string, $0) })
                let b = Dictionary(uniqueKeysWithValues: after.map { ($0["id"].string, $0) })
                count += Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }.count
            } else { count += 1 }
        }
        return max(1, count)
    }
    private func updateLocalStatus() async throws {
        guard journal != nil else { return }
        let snapshot = try await local.snapshot()
        try checkIdentity()
        // A network acknowledgement may advance the journal while the file snapshot is being read.
        guard let journal else { return }
        pendingCount = max(journal.pending == nil ? 0 : 1,
                           Self.pendingEntityCount(base: try wireState(journal.baseDocument), current: snapshot))
    }
    /// Called after a local save. This never contacts the server or blocks local work on connectivity.
    func refreshLocalStatus() async {
        guard !stopped, account.identityKey == identity else { return }
        do { try loadJournal(); try await updateLocalStatus() }
        catch { recordFailure(error) }
        updateStatus()
    }
    func pause() async {
        guard !stopped, account.identityKey == identity else { return }
        do {
            try loadJournal()
            let previouslyPaused = paused
            paused = true
            do { if let journal { try persist(journal) } }
            catch { paused = previouslyPaused; throw error }
            nextRetryAt = nil
            timer?.cancel(); timer = nil
            updateStatus()
            _ = await saveLocal()
            try await updateLocalStatus()
            message = "\(scope.title)自动同步已暂停；本机编辑照常保存，待同步内容不会丢弃。"
        } catch { recordFailure(error) }
        updateStatus()
    }
    func resume() async {
        guard !stopped, account.identityKey == identity else { return }
        do {
            try loadJournal()
            let previouslyPaused = paused
            paused = false
            do { if let journal { try persist(journal) } }
            catch { paused = previouslyPaused; throw error }
            consecutiveFailures = 0; nextRetryAt = nil
        } catch { recordFailure(error); updateStatus(); return }
        await retry()
    }
    private func checkNetworkAllowed() throws {
        try checkIdentity()
        guard !paused else { throw CloudAccountError(code: "sync_paused", message: "自动同步已暂停，本机编辑照常保存。") }
    }
    private func recordFailure(_ failure: Error) {
        let code = (failure as? CloudAccountError)?.code ?? (failure as? RuntimeError)?.code ?? ""
        if code == "sync_paused" { message = "自动同步已暂停，本机编辑照常保存。"; return }
        error = failure.localizedDescription
        if ["unauthorized", "http_401", "invalid_session", "forbidden", "http_403"].contains(code) {
            transientPhase = .authenticationRequired; hasConflict = false; nextRetryAt = nil
            message = "服务端授权需要重新确认；本机内容已保留。"
        } else {
            let retryable = ["local_unsaved", "cloud_local_conflict", "state_busy", "revision_conflict", "session_changed"]
            let unavailable = failure is URLError || code.hasPrefix("http_5") || code == "rate_limited" || code == "http_429"
            hasConflict = !unavailable && !retryable.contains(code)
            transientPhase = hasConflict ? nil : (failure is URLError ? .offline : .error)
            if !hasConflict {
                consecutiveFailures += 1
                nextRetryAt = now().addingTimeInterval(Self.retryDelay(afterFailures: consecutiveFailures))
            } else { nextRetryAt = nil }
            message = hasConflict ? "同步需核对 · 本机内容已保留" : "服务端暂未同步 · 本机可继续编辑，联网后自动重试"
        }
    }
    private func checkIdentity() throws {
        guard !stopped, !identity.isEmpty, !userID.isEmpty, account.identityKey == identity else {
            throw CloudAccountError(code: "session_changed", message: "账号已切换，旧工作区同步已停止。")
        }
    }
    static func document(_ state: JSON, scope: CloudTaskScope = .organization) -> JSON { ["schemaVersion": 2, "scope": .string(scope.rawValue), "state": state] }
    static func state(_ document: JSON, scope: CloudTaskScope = .organization) throws -> JSON {
        guard document["schemaVersion"] == .number(2), document["scope"] == .string(scope.rawValue),
              Set(document.object.keys) == ["schemaVersion", "scope", "state"], case .object = document["state"] else {
            throw CloudAccountError(code: "unsupported_schema", message: "云端数据版本不兼容，已停止同步以保护内容。")
        }
        return document["state"]
    }
    private func wireDocument(_ state: JSON) -> JSON { Self.document(state, scope: scope) }
    private func wireState(_ document: JSON) throws -> JSON { try Self.state(document, scope: scope) }
    private func persist(_ next: CloudSyncJournal) throws {
        try checkIdentity()
        var next = next
        next.paused = paused; next.lastSyncedAt = lastSyncedAt; next.lastCheckedAt = lastCheckedAt
        try journalStorage.write(next); journal = next
    }
    private func loadJournal() throws {
        guard journal == nil else { return }
        if let saved = try journalStorage.read() {
            guard saved.serverID == serverID, saved.userID == userID,
                  saved.organizationID == (scope == .organization ? organizationID : nil), saved.serverRevision >= 0 else {
                throw CloudAccountError(code: "sync_identity_mismatch", message: "本机同步记录与账号不符，已停止同步。")
            }
            _ = try wireState(saved.baseDocument)
            if let pending = saved.pending { _ = try wireState(pending.document) }
            journal = saved
            paused = saved.paused ?? false
            lastSyncedAt = saved.lastSyncedAt; lastCheckedAt = saved.lastCheckedAt
        } else if let initialBase {
            try persist(CloudSyncJournal(serverID: serverID, userID: userID, organizationID: scope == .organization ? organizationID : nil, serverRevision: 0,
                                         baseDocument: wireDocument(initialBase), pending: nil))
        } else {
            throw CloudAccountError(code: "sync_baseline_missing", message: "此账号的本机同步基线缺失，已保留本地数据并暂停同步。请先核对，不能直接覆盖。")
        }
    }
    func synchronize() async {
        guard !busy, !hasConflict, !stopped, account.identityKey == identity else { return }
        busy = true; error = nil; forceReconcile = false; localWorkRequested = false
        updateStatus()
        defer { busy = false; updateStatus(); scheduleWork() }
        do {
            try checkIdentity(); try loadJournal()
            guard await saveLocal() else { throw CloudAccountError(code: "local_unsaved", message: "本机仍有未保存的编辑，云端同步已暂停。") }
            try await updateLocalStatus()
            try checkNetworkAllowed()
            if journal?.pending != nil {
                do { try await sendPending() }
                catch let error as CloudAccountError where error.code == "revision_conflict" {
                    // The server checks mutation receipts first. A revision conflict proves this write was not accepted.
                    guard var next = journal, next.pending?.acknowledgedRevision == nil else { throw error }
                    next.pending = nil; try persist(next)
                }
            }
            try checkNetworkAllowed()
            let remote = try await account.authorizedAPI(scope.endpoint)
            try checkIdentity()
            guard case .number(let revisionNumber) = remote["revision"], revisionNumber >= 0,
                  revisionNumber.isFinite, revisionNumber.rounded() == revisionNumber,
                  revisionNumber <= Double(Int.max), var next = journal else {
                throw CloudAccountError(code: "invalid_response", message: "云端同步版本无效。")
            }
            let revision = Int(revisionNumber)
            guard revision >= next.serverRevision else {
                throw CloudAccountError(code: "revision_regressed", message: "云端版本发生倒退，已暂停同步以保护数据。")
            }
            lastCheckedAt = now()
            let base = try wireState(next.baseDocument)
            let localSnapshot = try await local.snapshot()
            try checkIdentity()
            let remoteState: JSON
            if remote["document"] == .null {
                guard revision == 0, next.serverRevision == 0 else {
                    throw CloudAccountError(code: "revision_regressed", message: "云端原有数据意外缺失，已暂停同步。")
                }
                remoteState = base
            } else { remoteState = try wireState(remote["document"]) }
            try local.validate(base); try local.validate(localSnapshot); try local.validate(remoteState)
            let merged = local.normalize(try CloudStateMerge.merge(base: base, local: localSnapshot, remote: remoteState))
            try local.validate(merged)
            if merged != remoteState {
                next.pending = CloudSyncPending(mutationID: UUID().uuidString.lowercased(), expectedRevision: revision,
                                                document: wireDocument(merged), localBefore: localSnapshot, acknowledgedRevision: nil)
                try persist(next) // Must reach disk before a request can be sent.
                try await sendPending()
            } else {
                if localSnapshot != merged { try await local.apply(merged, expected: localSnapshot) }
                try checkIdentity()
                next.serverRevision = revision; next.baseDocument = wireDocument(remoteState); next.pending = nil
                try persist(next)
            }
            try checkIdentity(); await refreshLocal(); try checkIdentity()
            try await updateLocalStatus()
            if pendingCount == 0 { lastSyncedAt = now() }
            if let journal { try persist(journal) }
            consecutiveFailures = 0; nextRetryAt = nil; transientPhase = nil
            message = pendingCount == 0 ? "\(scope.title)已获服务端确认" : "\(scope.title)有新的本机修改，等待下次同步"
            error = nil; conflict = nil
        } catch {
            let code = (error as? CloudAccountError)?.code ?? (error as? RuntimeError)?.code ?? ""
            if stopped || (account.identityKey != identity && !["unauthorized", "http_401", "invalid_session"].contains(code)) { return }
            recordFailure(error)
            try? await updateLocalStatus()
        }
    }
    private func sendPending() async throws {
        guard var next = journal, var pending = next.pending else { return }
        try local.validate(wireState(pending.document))
        if pending.acknowledgedRevision == nil {
            try await local.validateUpload(wireState(pending.document))
            try checkNetworkAllowed()
            let response = try await account.authorizedAPI(scope.endpoint, method: "PUT", body: pending.requestBody)
            try checkIdentity()
            guard case .number(let revision) = response["revision"], revision.isFinite,
                  revision > Double(pending.expectedRevision), revision.rounded() == revision, revision <= Double(Int.max) else {
                throw CloudAccountError(code: "invalid_response", message: "云端未返回有效保存回执；下次将重试同一操作。")
            }
            lastCheckedAt = now()
            pending.acknowledgedRevision = Int(revision); next.pending = pending; try persist(next)
        }
        let current = try await local.snapshot()
        try checkIdentity()
        let cloudState = try wireState(pending.document)
        let merged = local.normalize(try CloudStateMerge.merge(base: pending.localBefore, local: current, remote: cloudState))
        try local.validate(merged)
        if merged != current { try await local.apply(merged, expected: current) }
        try checkIdentity()
        next.serverRevision = pending.acknowledgedRevision!; next.baseDocument = pending.document; next.pending = nil
        try persist(next)
    }
    private func reviewedConflict(remote: JSON, localState: JSON) throws -> CloudSyncConflict {
        guard let journal, case .number(let revision) = remote["revision"], revision >= 0,
              revision.isFinite, revision.rounded() == revision, revision <= Double(Int.max),
              Int(revision) >= journal.serverRevision, remote["document"] != .null else {
            throw CloudAccountError(code: "invalid_response", message: "云端核对版本无效，未修改任何内容。")
        }
        let remoteState = try wireState(remote["document"])
        try local.validate(localState); try local.validate(remoteState)
        return CloudSyncConflict(id: UUID().uuidString, serverRevision: Int(revision), baseDocument: journal.baseDocument,
                                 localDocument: wireDocument(localState), remoteDocument: remote["document"], recordedAt: RuntimeDate.iso())
    }
    /// Refresh both sides for a review; never decides which side wins.
    func reviewConflict() async {
        guard !busy else { return }
        busy = true; error = nil
        updateStatus()
        defer { busy = false; updateStatus() }
        do {
            try checkIdentity(); try loadJournal()
            guard await saveLocal() else { throw CloudAccountError(code: "local_unsaved", message: "请先处理本机未保存编辑，再核对云端冲突。") }
            try checkIdentity()
            // Resolve uncertain delivery before allowing a user choice to replace that outbox.
            if let pending = journal?.pending, pending.acknowledgedRevision == nil {
                do { try await sendPending() }
                catch let error as CloudAccountError where error.code == "revision_conflict" {
                    guard var next = journal, next.pending?.acknowledgedRevision == nil else { throw error }
                    next.pending = nil; try persist(next)
                } catch let error as RuntimeError where error.code == "cloud_merge_conflict" && journal?.pending?.acknowledgedRevision != nil {
                    // The accepted receipt is now durable; both current sides can be reviewed safely.
                }
            }
            let remote = try await account.authorizedAPI(scope.endpoint)
            let snapshot = try await local.snapshot(); try checkIdentity()
            conflict = try reviewedConflict(remote: remote, localState: snapshot)
            hasConflict = true; message = "请核对本机与云端差异，再明确选择保留哪一份任务文档"
        } catch { recordFailure(error) }
    }
    @discardableResult func resolveConflict(id: String, choice: CloudConflictChoice) async -> Bool {
        guard !busy, let reviewed = conflict, reviewed.id == id else { return false }
        busy = true; error = nil
        updateStatus()
        defer { busy = false; updateStatus() }
        do {
            try checkIdentity()
            guard await saveLocal() else { throw CloudAccountError(code: "local_unsaved", message: "本机还有未保存编辑，请保存后重新核对。") }
            let latestRemote = try await account.authorizedAPI(scope.endpoint)
            let currentLocal = try await local.snapshot(); try checkIdentity()
            let latest = try reviewedConflict(remote: latestRemote, localState: currentLocal)
            guard latest.serverRevision == reviewed.serverRevision, latest.remoteDocument == reviewed.remoteDocument,
                  latest.localDocument == reviewed.localDocument else {
                conflict = latest; hasConflict = true
                error = "核对期间数据又有变化，已更新两侧内容。请重新核对后选择；尚未覆盖任何一端。"
                return false
            }
            guard var next = journal else { return false }
            let selected = choice == .local ? reviewed.localDocument : reviewed.remoteDocument
            try local.validate(wireState(selected))
            let chosen = wireDocument(local.normalize(try wireState(selected)))
            recoveryFile = try journalStorage.archive(CloudSyncConflictBackup(conflict: reviewed, choice: choice, journalBefore: next))
            try checkIdentity()
            next.pending = CloudSyncPending(mutationID: UUID().uuidString.lowercased(), expectedRevision: reviewed.serverRevision,
                                            document: chosen, localBefore: currentLocal, acknowledgedRevision: nil)
            try persist(next)
            do { try await sendPending() }
            catch let error as CloudAccountError where error.code == "revision_conflict" {
                guard var current = journal, current.pending?.acknowledgedRevision == nil else { throw error }
                current.pending = nil; try persist(current)
                let remote = try await account.authorizedAPI(scope.endpoint)
                let snapshot = try await local.snapshot(); try checkIdentity()
                conflict = try reviewedConflict(remote: remote, localState: snapshot)
                self.error = "保存时云端又有新版本，未覆盖云端。请重新核对最新差异。"
                hasConflict = true; return false
            }
            try checkIdentity(); await refreshLocal(); try checkIdentity()
            conflict = nil; hasConflict = false; error = nil
            try await updateLocalStatus()
            if pendingCount == 0 { lastSyncedAt = now() }
            if let journal { try persist(journal) }
            consecutiveFailures = 0; nextRetryAt = nil; transientPhase = nil
            message = "冲突已按你的选择解决；双方恢复副本已保存在本机"
            return true
        } catch {
            if !stopped { recordFailure(error) }
            return false
        }
    }
    /// Retrying never chooses local or remote automatically; the same three-way conflict must be resolved first.
    func retry() async {
        hasConflict = false; transientPhase = nil; nextRetryAt = nil; consecutiveFailures = 0
        await synchronize()
    }
}
