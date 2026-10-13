import XCTest
@testable import HeroOOSNative

private final class TestSyncJournal: CloudSyncJournalStorage {
    var value: CloudSyncJournal?
    var writes: [CloudSyncJournal] = []
    var backups: [CloudSyncConflictBackup] = []
    var failArchive = false
    func read() throws -> CloudSyncJournal? { value }
    func write(_ journal: CloudSyncJournal) throws { value = journal; writes.append(journal) }
    func archive(_ backup: CloudSyncConflictBackup) throws -> String {
        if failArchive { throw CocoaError(.fileWriteNoPermission) }
        backups.append(backup); return "/test-only/recovery.json"
    }
}
private final class TestSyncLocal: CloudSyncLocalStorage {
    var state: JSON
    var applications: [JSON] = []
    var failNextApply = false
    var validationFailure: Error?
    var uploadFailure: Error?
    init(_ state: JSON) { self.state = state }
    func snapshot() async throws -> JSON { state }
    func validate(_ state: JSON) throws { if let validationFailure { throw validationFailure } }
    func validateUpload(_ state: JSON) async throws { if let uploadFailure { throw uploadFailure } }
    func apply(_ incoming: JSON, expected: JSON) async throws {
        if failNextApply { failNextApply = false; throw RuntimeError("cloud_local_conflict", "测试并发编辑") }
        guard state == expected else { throw RuntimeError("cloud_local_conflict", "测试CAS冲突") }
        applications.append(incoming); state = incoming
    }
}

@MainActor final class CloudSyncTests: XCTestCase {
    private var seed: JSON { ["tasks": [], "tracks": [], "taskPages": []] }
    private func taskState(_ title: String, status: String = "ready", extraID: String? = nil) -> JSON {
        var tasks: [JSON] = [["id": "task-one", "title": .string(title), "status": .string(status)]]
        if let extraID { tasks.append(["id": .string(extraID), "title": "新增", "status": "ready"]) }
        return ["tasks": .array(tasks), "tracks": [], "taskPages": []]
    }
    private func account(_ transport: TestCloudTransport) async -> CloudAccount {
        transport.reply(["token": "test-token", "user": ["id": "user-one", "username": "owner"],
                         "organization": ["id": "org-one", "name": "Example Org", "role": "owner"],
                         "memberships": [["id": "org-one", "name": "Example Org", "role": "owner", "status": "approved"]],
                         "expiresAt": "2026-12-01T00:00:00Z"])
        let account = CloudAccount(api: CloudAPI(baseURL: URL(string: "https://cloud.example.invalid")!, transport: transport), credentials: TestCloudCredentials(), bootstrap: TestCloudBootstrap())
        let logged = await account.login(organization: "Example Org", username: "owner", password: "test-only-password-123")
        XCTAssertTrue(logged)
        return account
    }
    private func journal(_ account: CloudAccount, base: JSON, revision: Int = 1) -> TestSyncJournal {
        let store = TestSyncJournal()
        store.value = CloudSyncJournal(serverID: account.api.serverID, userID: "user-one", organizationID: "org-one", serverRevision: revision,
                                       baseDocument: CloudSync.document(base), pending: nil)
        return store
    }
    private func engine(_ account: CloudAccount, _ local: TestSyncLocal, _ journal: TestSyncJournal, seed: JSON? = nil,
                        now: @escaping () -> Date = Date.init) -> CloudSync {
        CloudSync(account: account, local: local, journalStorage: journal, initialBase: seed, saveLocal: { true }, refreshLocal: {}, now: now)
    }
    private func payload(_ request: URLRequest) throws -> JSON { try JSONDecoder().decode(JSON.self, from: request.httpBody!) }

    func testFirstEmptyWorkspaceSeedsBaselineWithoutUploadingAnything() async {
        let transport = TestCloudTransport(), journal = TestSyncJournal(), local = TestSyncLocal(seed)
        let account = await account(transport)
        transport.reply(["revision": 0, "document": nil])
        let sync = engine(account, local, journal, seed: seed)
        await sync.synchronize()
        XCTAssertNil(sync.error); XCTAssertFalse(sync.hasConflict)
        XCTAssertEqual(journal.value?.serverRevision, 0)
        XCTAssertEqual(journal.value?.baseDocument, CloudSync.document(seed))
        XCTAssertTrue(local.applications.isEmpty)
        XCTAssertFalse(transport.requests.contains { $0.httpMethod == "PUT" })
    }

    func testPrivateEngineUsesOnlyUserEndpointAndPrivateScope() async throws {
        let transport = TestCloudTransport(), account = await account(transport)
        let local = TestSyncLocal(taskState("仅我自己")), saved = TestSyncJournal()
        saved.value = CloudSyncJournal(serverID: account.api.serverID, userID: "user-one", serverRevision: 0,
            baseDocument: CloudSync.document(seed, scope: .personal), pending: nil)
        transport.reply(["revision": 0, "document": nil]); transport.reply(["ok": true, "revision": 1])
        let sync = CloudSync(account: account, local: local, journalStorage: saved, initialBase: nil, scope: .personal,
                             saveLocal: { true }, refreshLocal: {})
        await sync.synchronize()
        XCTAssertNil(sync.error)
        let requests = transport.requests.dropFirst()
        XCTAssertTrue(requests.allSatisfy { $0.url?.path == "/v1/personal/state" })
        XCTAssertEqual(try payload(requests.last!)["document"]["scope"], "personal-tasks")
        XCTAssertNil(saved.value?.organizationID)
    }

    func testPrivateJournalAndDifferentOrganizationJournalCannotPublishToOrganization() async {
        let transport = TestCloudTransport(), account = await account(transport), local = TestSyncLocal(seed)
        let privateJournal = TestSyncJournal()
        privateJournal.value = CloudSyncJournal(serverID: account.api.serverID, userID: "user-one", serverRevision: 1,
            baseDocument: CloudSync.document(taskState("私人内容"), scope: .personal), pending: nil)
        let before = transport.requests.count
        let privateEngine = engine(account, local, privateJournal)
        await privateEngine.synchronize()
        XCTAssertNotNil(privateEngine.error); XCTAssertEqual(transport.requests.count, before)
        let otherOrg = journal(account, base: seed)
        otherOrg.value?.organizationID = "another-organization"
        let otherEngine = engine(account, local, otherOrg)
        await otherEngine.synchronize()
        XCTAssertNotNil(otherEngine.error); XCTAssertEqual(transport.requests.count, before)
    }

    func testLegacyBroadCloudEnvelopeCannotBeReadAsTaskScope() {
        XCTAssertThrowsError(try CloudSync.state(["schemaVersion": 1, "state": seed]))
        XCTAssertThrowsError(try CloudSync.state(CloudSync.document(seed, scope: .personal)))
        XCTAssertThrowsError(try CloudSync.state(["schemaVersion": 2, "scope": "organization-tasks", "state": seed, "collages": []]))
    }

    func testStaleOutboxMovedToPrivateStopsBeforeAnyNetworkRequest() async {
        let transport = TestCloudTransport(), account = await account(transport), local = TestSyncLocal(seed)
        let saved = journal(account, base: seed, revision: 0)
        saved.value?.pending = CloudSyncPending(mutationID: "unsent-work", expectedRevision: 0,
            document: CloudSync.document(taskState("后来已改为私人")), localBefore: seed, acknowledgedRevision: nil)
        local.uploadFailure = CloudAccountError(code: "task_scope_changed", message: "私人任务不得通过旧组织队列上传")
        let count = transport.requests.count, sync = engine(account, local, saved)
        await sync.synchronize()
        XCTAssertTrue(sync.hasConflict); XCTAssertNotNil(saved.value?.pending)
        XCTAssertEqual(transport.requests.count, count)
    }

    func testRuntimeUploadGuardInspectsCurrentOppositeScope() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hero-upload-privacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = StateRuntime(root: root)
        try runtime.initializeIfNeeded()
        _ = try runtime.mutate(["expectedVersion": 1, "clientMutationId": "private-fixture",
            "operations": [["type": "task.create", "task": ["id": "private-one", "title": "仅本人", "taskSpace": "personal", "status": "ready"]]]])
        let local = CloudSyncRuntime(runtime: runtime)
        do {
            try await local.validateUpload(["tasks": [["id": "private-one", "title": "旧的组织副本", "taskSpace": "work"]], "tracks": [], "taskPages": []])
            XCTFail("Should block stale organization outbox")
        } catch { XCTAssertEqual((error as? CloudAccountError)?.code, "task_scope_changed") }
        let snapshot = try await local.snapshot()
        XCTAssertTrue(snapshot["tasks"].array.isEmpty)
    }

    func testFirstRemoteStateDownloadsIntoFreshAccountOnly() async {
        let transport = TestCloudTransport(), journal = TestSyncJournal(), local = TestSyncLocal(seed)
        let account = await account(transport), remote = taskState("云端任务")
        transport.reply(["revision": 8, "document": CloudSync.document(remote)])
        let sync = engine(account, local, journal, seed: seed)
        await sync.synchronize()
        XCTAssertNil(sync.error); XCTAssertEqual(local.state, remote)
        XCTAssertEqual(journal.value?.serverRevision, 8)
        XCTAssertFalse(transport.requests.contains { $0.httpMethod == "PUT" })
    }

    func testLocalWritePersistsOutboxBeforeSendingAndThenClearsIt() async throws {
        let transport = TestCloudTransport(), account = await account(transport)
        let local = TestSyncLocal(taskState("新任务")), saved = journal(account, base: seed, revision: 0)
        transport.reply(["revision": 0, "document": nil]); transport.reply(["ok": true, "revision": 1])
        transport.onSend = { request in
            if request.httpMethod == "PUT" { XCTAssertNotNil(saved.value?.pending) }
        }
        let sync = engine(account, local, saved)
        await sync.synchronize()
        XCTAssertNil(sync.error); XCTAssertNil(saved.value?.pending)
        XCTAssertEqual(saved.value?.baseDocument, CloudSync.document(local.state))
        XCTAssertEqual(saved.value?.serverRevision, 1)
        let body = try payload(transport.requests.last!)
        XCTAssertEqual(body["expectedRevision"], 0)
        XCTAssertFalse(body["mutationId"].string.isEmpty)
        XCTAssertEqual(body["document"], CloudSync.document(local.state))
    }

    func testLostPUTResponseRetriesIdenticalMutationWithoutDiscardingLocalChanges() async throws {
        let transport = TestCloudTransport(), account = await account(transport)
        let local = TestSyncLocal(taskState("新任务")), saved = journal(account, base: seed, revision: 0)
        transport.reply(["revision": 0, "document": nil]); transport.reply(["ok": true, "revision": 1])
        var lost = false
        transport.onSend = { request in
            if request.httpMethod == "PUT" && !lost { lost = true; throw URLError(.networkConnectionLost) }
        }
        let sync = engine(account, local, saved)
        await sync.synchronize()
        XCTAssertNotNil(saved.value?.pending); XCTAssertFalse(sync.hasConflict)
        let first = transport.requests.last!
        transport.reply(["revision": 1, "document": CloudSync.document(local.state)])
        await sync.synchronize()
        let puts = transport.requests.filter { $0.httpMethod == "PUT" }
        XCTAssertEqual(puts.count, 2)
        XCTAssertEqual(try payload(first), try payload(puts[1]))
        XCTAssertNil(saved.value?.pending); XCTAssertNil(sync.error)
    }

    func testAcknowledgedPendingSurvivesLocalCASFailureWithoutSecondPUT() async {
        let transport = TestCloudTransport(), account = await account(transport)
        let base = taskState("原始"), localState = taskState("本机新标题"), remoteState = taskState("原始", status: "active")
        let merged = taskState("本机新标题", status: "active")
        let local = TestSyncLocal(localState), saved = journal(account, base: base)
        local.failNextApply = true
        transport.reply(["revision": 2, "document": CloudSync.document(remoteState)]); transport.reply(["ok": true, "revision": 3])
        let sync = engine(account, local, saved)
        await sync.synchronize()
        XCTAssertEqual(saved.value?.pending?.acknowledgedRevision, 3)
        XCTAssertFalse(sync.hasConflict); XCTAssertEqual(local.state, localState)
        transport.reply(["revision": 3, "document": CloudSync.document(merged)])
        await sync.synchronize()
        XCTAssertEqual(transport.requests.filter { $0.httpMethod == "PUT" }.count, 1)
        XCTAssertEqual(local.state, merged); XCTAssertNil(saved.value?.pending)
    }

    func testSameFieldConflictStopsWithoutPUTOrLocalOverwrite() async {
        let transport = TestCloudTransport(), account = await account(transport)
        let base = taskState("原始"), localState = taskState("本机新标题"), remote = taskState("另一台标题")
        let local = TestSyncLocal(localState), saved = journal(account, base: base)
        transport.reply(["revision": 2, "document": CloudSync.document(remote)])
        let sync = engine(account, local, saved)
        await sync.synchronize()
        XCTAssertTrue(sync.hasConflict); XCTAssertEqual(local.state, localState)
        XCTAssertEqual(saved.value?.baseDocument, CloudSync.document(base))
        XCTAssertTrue(local.applications.isEmpty); XCTAssertFalse(transport.requests.contains { $0.httpMethod == "PUT" })
    }

    func testSchemaAndIdentityMismatchNeverOverwriteLocalOrContactWrongAccount() async {
        let transport = TestCloudTransport(), account = await account(transport)
        let local = TestSyncLocal(seed), saved = journal(account, base: seed)
        transport.reply(["revision": 2, "document": ["schemaVersion": 99, "state": taskState("未来版本")]])
        let sync = engine(account, local, saved)
        await sync.synchronize()
        XCTAssertTrue(sync.hasConflict); XCTAssertEqual(local.state, seed)
        let wrong = TestSyncJournal()
        wrong.value = CloudSyncJournal(serverID: "another-server", userID: "another-user", organizationID: "org-one", serverRevision: 1, baseDocument: CloudSync.document(seed), pending: nil)
        let count = transport.requests.count
        await engine(account, local, wrong).synchronize()
        XCTAssertEqual(count, transport.requests.count)
    }

    func testValidationFailureIsCaughtBeforeUpload() async {
        let transport = TestCloudTransport(), account = await account(transport)
        let local = TestSyncLocal(taskState("会构成环")), saved = journal(account, base: seed)
        local.validationFailure = RuntimeError("relationship_cycle", "测试循环依赖")
        transport.reply(["revision": 1, "document": CloudSync.document(seed)])
        let sync = engine(account, local, saved)
        await sync.synchronize()
        XCTAssertTrue(sync.hasConflict); XCTAssertNil(saved.value?.pending)
        XCTAssertFalse(transport.requests.contains { $0.httpMethod == "PUT" })
    }

    func testMissingBaselineOnExistingWorkspaceStopsRatherThanGuessing() async {
        let transport = TestCloudTransport(), account = await account(transport)
        let local = TestSyncLocal(taskState("必须保留")), saved = TestSyncJournal()
        let sync = engine(account, local, saved)
        await sync.synchronize()
        XCTAssertTrue(sync.hasConflict); XCTAssertTrue(local.applications.isEmpty)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testLogoutStopsOldWorkspaceNetworkAndLocalWrites() async {
        let transport = TestCloudTransport(), account = await account(transport)
        let local = TestSyncLocal(seed), saved = journal(account, base: seed)
        let sync = engine(account, local, saved)
        transport.reply(["ok": true]); await account.logout()
        let count = transport.requests.count
        await sync.synchronize()
        XCTAssertEqual(transport.requests.count, count); XCTAssertTrue(local.applications.isEmpty)
    }

    func testAccountDirectorySeparatesServerAndUserButNeverUsesOrganizationNameOrPathInput() {
        let root = URL(fileURLWithPath: "/tmp/test-only-accounts", isDirectory: true)
        let one = CloudWorkspace.accountDirectory(serverID: "https://server:443", userID: "../user-a", under: root)
        let same = CloudWorkspace.accountDirectory(serverID: "https://server:443", userID: "../user-a", under: root)
        let otherUser = CloudWorkspace.accountDirectory(serverID: "https://server:443", userID: "user-b", under: root)
        let otherServer = CloudWorkspace.accountDirectory(serverID: "https://elsewhere:443", userID: "../user-a", under: root)
        XCTAssertEqual(one, same); XCTAssertNotEqual(one, otherUser); XCTAssertNotEqual(one, otherServer)
        XCTAssertEqual(one.deletingLastPathComponent(), root); XCTAssertEqual(one.lastPathComponent.count, 64)
    }

    func testExplicitImportAddsUniqueEntitiesAndRejectsSameIDDifferentContents() throws {
        let source = taskState("源任务"), empty = seed
        XCTAssertEqual(try CloudWorkspace.mergeImport(existing: empty, source: source), source)
        XCTAssertThrowsError(try CloudWorkspace.mergeImport(existing: taskState("目标已有任务"), source: source))
        let merged = try CloudWorkspace.mergeImport(existing: source, source: taskState("源任务", extraID: "another-task"))
        XCTAssertEqual(merged["tasks"].array.count, 2)
        XCTAssertEqual(source["tasks"].array.count, 1)
    }

    func testExplicitConflictChoiceArchivesBothSidesBeforeCASAndAppliesChosenDocument() async {
        for choice in [CloudConflictChoice.local, .remote] {
            let transport = TestCloudTransport(), account = await account(transport)
            let base = taskState("原始"), mine = taskState("本机标题"), theirs = taskState("云端标题")
            let local = TestSyncLocal(mine), saved = journal(account, base: base)
            let sync = engine(account, local, saved)
            transport.reply(["revision": 2, "document": CloudSync.document(theirs)])
            await sync.reviewConflict()
            XCTAssertNotNil(sync.conflict)
            XCTAssertTrue(sync.conflict!.differences.contains { $0.path.hasSuffix(".title") })
            transport.reply(["revision": 2, "document": CloudSync.document(theirs)])
            transport.reply(["ok": true, "revision": 3])
            transport.onSend = { request in
                if request.httpMethod == "PUT" { XCTAssertEqual(saved.backups.count, 1, "Both sides must reach recovery storage before overwrite") }
            }
            let result = await sync.resolveConflict(id: sync.conflict!.id, choice: choice)
            XCTAssertTrue(result); XCTAssertNil(sync.conflict); XCTAssertFalse(sync.hasConflict)
            XCTAssertEqual(local.state, choice == .local ? mine : theirs)
            XCTAssertEqual(saved.backups.first?.conflict.localDocument, CloudSync.document(mine))
            XCTAssertEqual(saved.backups.first?.conflict.remoteDocument, CloudSync.document(theirs))
            XCTAssertEqual(saved.value?.serverRevision, 3)
            XCTAssertEqual(saved.backups.first?.choice, choice)
        }
    }

    func testConflictReviewStalenessRequiresNewConsentWithoutAnyOverwrite() async {
        for changeLocal in [false, true] {
            let transport = TestCloudTransport(), account = await account(transport)
            let mine = taskState("本机"), theirs = taskState("云端")
            let local = TestSyncLocal(mine), saved = journal(account, base: taskState("原始"))
            let sync = engine(account, local, saved)
            transport.reply(["revision": 2, "document": CloudSync.document(theirs)]); await sync.reviewConflict()
            let oldID = sync.conflict!.id
            if changeLocal { local.state = taskState("核对时又改了本机") }
            transport.reply(["revision": .number(changeLocal ? 2 : 3), "document": CloudSync.document(changeLocal ? theirs : taskState("核对时又改了云端"))])
            let resolved = await sync.resolveConflict(id: oldID, choice: .remote)
            XCTAssertFalse(resolved); XCTAssertNotEqual(sync.conflict?.id, oldID)
            XCTAssertTrue(sync.error?.contains("重新核对") == true)
            XCTAssertTrue(saved.backups.isEmpty); XCTAssertTrue(local.applications.isEmpty)
            XCTAssertFalse(transport.requests.contains { $0.httpMethod == "PUT" })
        }
    }

    func testConflictCASRaceRefreshesReviewInsteadOfOverwritingNewCloudVersion() async {
        let transport = TestCloudTransport(), account = await account(transport)
        let mine = taskState("本机"), theirs = taskState("云端"), newer = taskState("更晚云端")
        let local = TestSyncLocal(mine), saved = journal(account, base: taskState("原始"))
        let sync = engine(account, local, saved)
        transport.reply(["revision": 2, "document": CloudSync.document(theirs)]); await sync.reviewConflict()
        transport.reply(["revision": 2, "document": CloudSync.document(theirs)])
        transport.reply(["ok": false, "error": "revision_conflict", "message": "版本已更新"], status: 409)
        transport.reply(["revision": 3, "document": CloudSync.document(newer)])
        let result = await sync.resolveConflict(id: sync.conflict!.id, choice: .local)
        XCTAssertFalse(result); XCTAssertEqual(sync.conflict?.serverRevision, 3)
        XCTAssertEqual(local.state, mine); XCTAssertTrue(local.applications.isEmpty)
        XCTAssertNil(saved.value?.pending); XCTAssertEqual(saved.backups.count, 1)
        XCTAssertEqual(sync.conflict?.remoteDocument, CloudSync.document(newer))
    }

    func testRecoveryCopyFailurePreventsEveryOverwrite() async {
        let transport = TestCloudTransport(), account = await account(transport)
        let mine = taskState("本机"), theirs = taskState("云端")
        let local = TestSyncLocal(mine), saved = journal(account, base: taskState("原始")); saved.failArchive = true
        let sync = engine(account, local, saved)
        transport.reply(["revision": 2, "document": CloudSync.document(theirs)]); await sync.reviewConflict()
        transport.reply(["revision": 2, "document": CloudSync.document(theirs)])
        let result = await sync.resolveConflict(id: sync.conflict!.id, choice: .remote)
        XCTAssertFalse(result); XCTAssertTrue(local.applications.isEmpty)
        XCTAssertFalse(transport.requests.contains { $0.httpMethod == "PUT" })
        XCTAssertNil(saved.value?.pending)
    }

    func testLocalChangeImmediatelyStopsClaimingServerIsSyncedWithoutNetwork() async {
        let transport = TestCloudTransport(), account = await account(transport)
        let local = TestSyncLocal(taskState("原始")), saved = journal(account, base: local.state)
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let sync = engine(account, local, saved, now: { time })
        transport.reply(["revision": 1, "document": CloudSync.document(local.state)])
        await sync.synchronize()
        XCTAssertEqual(sync.phase, .upToDate); XCTAssertEqual(sync.lastSyncedAt, time)
        XCTAssertEqual(saved.value?.lastSyncedAt, time)
        let requests = transport.requests.count
        local.state = taskState("离线也可编辑", status: "active", extraID: "second")
        await sync.refreshLocalStatus()
        XCTAssertEqual(sync.phase, .pending); XCTAssertEqual(sync.pendingCount, 2)
        XCTAssertEqual(sync.lastSyncedAt, time, "Keep the actual last acknowledgement, not a fictitious new save time")
        XCTAssertEqual(transport.requests.count, requests)
    }

    func testOfflineEditsSurviveRestartThenUploadAfterConnectionReturns() async {
        let transport = TestCloudTransport(), account = await account(transport)
        let local = TestSyncLocal(taskState("离线新任务")), saved = journal(account, base: seed, revision: 0)
        transport.failure = URLError(.notConnectedToInternet)
        let first = engine(account, local, saved)
        await first.synchronize()
        XCTAssertEqual(first.phase, .offline); XCTAssertEqual(first.pendingCount, 1)
        XCTAssertFalse(first.hasConflict); XCTAssertNil(first.lastSyncedAt)
        XCTAssertEqual(local.state, taskState("离线新任务")); XCTAssertTrue(local.applications.isEmpty)
        first.stop()
        transport.failure = nil
        transport.reply(["revision": 0, "document": nil]); transport.reply(["revision": 1, "ok": true])
        let restored = engine(account, local, saved)
        await restored.synchronize()
        XCTAssertEqual(restored.phase, .upToDate); XCTAssertEqual(restored.pendingCount, 0)
        XCTAssertEqual(saved.value?.baseDocument, CloudSync.document(local.state))
    }

    func testLostAcknowledgementSurvivesEngineRestartAndReusesSameMutation() async throws {
        let transport = TestCloudTransport(), account = await account(transport)
        let local = TestSyncLocal(taskState("离线排队")), saved = journal(account, base: seed, revision: 0)
        transport.reply(["revision": 0, "document": nil])
        transport.onSend = { if $0.httpMethod == "PUT" { throw URLError(.networkConnectionLost) } }
        let first = engine(account, local, saved)
        await first.synchronize()
        let body = try payload(transport.requests.last!)
        XCTAssertNotNil(saved.value?.pending); first.stop()
        transport.onSend = nil
        transport.reply(["revision": 1, "ok": true])
        transport.reply(["revision": 1, "document": CloudSync.document(local.state)])
        let restored = engine(account, local, saved)
        await restored.synchronize()
        let puts = transport.requests.filter { $0.httpMethod == "PUT" }
        XCTAssertEqual(try payload(puts.last!), body)
        XCTAssertEqual(restored.phase, .upToDate); XCTAssertNil(saved.value?.pending)
    }

    func testPausedSyncPersistsAcrossRestartWhileLocalSavesContinue() async {
        let transport = TestCloudTransport(), account = await account(transport)
        let local = TestSyncLocal(taskState("暂停期间新增")), saved = journal(account, base: seed, revision: 0)
        let first = engine(account, local, saved)
        await first.pause()
        XCTAssertEqual(saved.value?.paused, true); XCTAssertEqual(first.phase, .paused)
        first.stop()
        var saves = 0
        let restored = CloudSync(account: account, local: local, journalStorage: saved, initialBase: nil,
                                 saveLocal: { saves += 1; return true }, refreshLocal: {})
        let requests = transport.requests.count
        await restored.synchronize()
        XCTAssertTrue(restored.paused); XCTAssertEqual(restored.pendingCount, 1)
        XCTAssertEqual(restored.phase, .paused); XCTAssertEqual(saves, 1)
        XCTAssertEqual(transport.requests.count, requests)
        transport.reply(["revision": 0, "document": nil]); transport.reply(["revision": 1, "ok": true])
        await restored.resume()
        XCTAssertFalse(restored.paused); XCTAssertEqual(saved.value?.paused, false)
        XCTAssertEqual(restored.phase, .upToDate); XCTAssertEqual(saves, 2)
    }

    func testPausePreservesDurablePendingMutation() async {
        let transport = TestCloudTransport(), account = await account(transport)
        let local = TestSyncLocal(taskState("未确认发送")), saved = journal(account, base: seed, revision: 0)
        let pending = CloudSyncPending(mutationID: "unchanged-mutation", expectedRevision: 0,
            document: CloudSync.document(local.state), localBefore: local.state, acknowledgedRevision: nil)
        saved.value?.pending = pending
        let sync = engine(account, local, saved)
        await sync.pause(); await sync.synchronize()
        XCTAssertEqual(saved.value?.pending, pending)
        XCTAssertEqual(transport.requests.count, 1, "Only fixture login was sent")
    }

    func testAutomaticRetryBackoffIsBoundedAndManualRetryIsImmediate() async {
        let transport = TestCloudTransport(), account = await account(transport)
        let local = TestSyncLocal(taskState("待发送")), saved = journal(account, base: seed, revision: 0)
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let sync = engine(account, local, saved, now: { clock })
        transport.failure = URLError(.timedOut)
        await sync.automaticTick()
        XCTAssertEqual(sync.nextRetryAt, clock.addingTimeInterval(10))
        let firstCount = transport.requests.count
        clock = clock.addingTimeInterval(9); await sync.automaticTick()
        XCTAssertEqual(transport.requests.count, firstCount)
        clock = clock.addingTimeInterval(1); await sync.automaticTick()
        XCTAssertEqual(transport.requests.count, firstCount + 1)
        XCTAssertEqual(sync.nextRetryAt, clock.addingTimeInterval(20))
        await sync.retry()
        XCTAssertEqual(transport.requests.count, firstCount + 2)
        XCTAssertEqual(sync.nextRetryAt, clock.addingTimeInterval(10))
        XCTAssertEqual([1, 2, 3, 4, 5, 6, 20, Int.max].map(CloudSync.retryDelay), [10, 20, 40, 80, 160, 300, 300, 300])
    }

    func testUnauthorizedIsNotMisreportedAsOfflineOrMergeConflict() async {
        let transport = TestCloudTransport(), account = await account(transport)
        let local = TestSyncLocal(taskState("本机保留")), saved = journal(account, base: seed, revision: 0)
        let sync = engine(account, local, saved)
        transport.reply(["error": "unauthorized", "message": "会话已失效"], status: 401)
        await sync.synchronize()
        XCTAssertEqual(sync.phase, .authenticationRequired); XCTAssertFalse(sync.hasConflict)
        XCTAssertNil(sync.nextRetryAt); XCTAssertNil(sync.lastSyncedAt)
        XCTAssertEqual(local.state, taskState("本机保留")); XCTAssertTrue(local.applications.isEmpty)
    }

    func testEditDuringFinalRefreshCannotBeReportedAsServerAcknowledged() async {
        let transport = TestCloudTransport(), account = await account(transport)
        let local = TestSyncLocal(taskState("已发送")), saved = journal(account, base: seed, revision: 0)
        let sync = CloudSync(account: account, local: local, journalStorage: saved, initialBase: nil,
                             saveLocal: { true }, refreshLocal: { local.state = self.taskState("发送期间的新编辑") })
        transport.reply(["revision": 0, "document": nil]); transport.reply(["revision": 1, "ok": true])
        await sync.synchronize()
        XCTAssertEqual(sync.phase, .pending); XCTAssertEqual(sync.pendingCount, 1)
        XCTAssertNil(sync.lastSyncedAt); XCTAssertNotNil(sync.lastCheckedAt)
        XCTAssertEqual(saved.value?.baseDocument, CloudSync.document(taskState("已发送")))
    }

    func testOldJournalDecodesWithoutStatusFields() throws {
        let data = try JSONEncoder().encode(JSON.object([
            "serverID": "https://example.invalid:443", "userID": "one", "organizationID": "org",
            "serverRevision": 2, "baseDocument": CloudSync.document(seed)
        ]))
        let journal = try JSONDecoder().decode(CloudSyncJournal.self, from: data)
        XCTAssertNil(journal.paused); XCTAssertNil(journal.lastSyncedAt); XCTAssertNil(journal.lastCheckedAt)
    }
}
