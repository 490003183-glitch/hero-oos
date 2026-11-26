import Foundation
import XCTest
@testable import HeroOOSNative

@MainActor final class TestIdleServerEventTransport: ServerEventTransport {
    var request: URLRequest?
    var handler: ((ServerSentEvent) throws -> Void)?
    func receive(request: URLRequest, handler: @escaping (ServerSentEvent) throws -> Void) async throws {
        self.request = request; self.handler = handler
        defer { self.handler = nil }
        try await Task.sleep(for: .seconds(3600))
    }
}

private final class PushSyncJournal: CloudSyncJournalStorage {
    var value: CloudSyncJournal?
    func read() throws -> CloudSyncJournal? { value }
    func write(_ journal: CloudSyncJournal) throws { value = journal }
    func archive(_ backup: CloudSyncConflictBackup) throws -> String { "/test-only/recovery" }
}
private final class PushSyncLocal: CloudSyncLocalStorage {
    var state: JSON
    init(_ state: JSON) { self.state = state }
    func snapshot() async throws -> JSON { state }
    func validate(_ state: JSON) throws {}
    func apply(_ incoming: JSON, expected: JSON) async throws {
        guard state == expected else { throw RuntimeError("cloud_local_conflict", "测试并发变更") }
        state = incoming
    }
}
private final class PushAPITransport: CloudTransport {
    var requests: [URLRequest] = []
    var replies: [JSON] = []
    var beforeReply: ((URLRequest) async throws -> Void)?
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        try await beforeReply?(request)
        guard !replies.isEmpty else { throw CloudAccountError(code: "no_fixture", message: "没有测试响应") }
        return (try JSONEncoder().encode(replies.removeFirst()),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor final class CloudPushTests: XCTestCase {
    private func state(_ title: String) -> JSON {
        ["tasks": [["id": "task-one", "title": .string(title), "status": "ready"]], "tracks": [], "taskPages": []]
    }
    private func account(_ transport: PushAPITransport) async -> CloudAccount {
        transport.replies.append(["token": "test-only-server-events-token", "user": ["id": "owner", "username": "owner"],
            "organization": ["id": "org-one", "name": "Example Org", "role": "owner"], "memberships": [], "expiresAt": nil])
        let account = CloudAccount(api: CloudAPI(transport: transport), credentials: TestCloudCredentials(), bootstrap: TestCloudBootstrap())
        let ok = await account.login(organization: "Example Org", username: "owner", password: "test-only-password")
        XCTAssertTrue(ok)
        return account
    }
    private func engine(_ account: CloudAccount, _ local: PushSyncLocal, scope: CloudTaskScope = .organization) -> (CloudSync, PushSyncJournal) {
        let journal = PushSyncJournal()
        journal.value = CloudSyncJournal(serverID: account.api.serverID, userID: "owner", organizationID: scope == .organization ? "org-one" : nil,
            serverRevision: 1, baseDocument: CloudSync.document(state("原始"), scope: scope), pending: nil)
        return (CloudSync(account: account, local: local, journalStorage: journal, initialBase: nil, scope: scope,
                          saveLocal: { true }, refreshLocal: {}), journal)
    }
    private func settle() async { for _ in 0..<40 { await Task.yield() } }

    func testAcknowledgedIdleWorkspaceAndDuplicateEventsNeverPollTaskDocuments() async {
        let transport = PushAPITransport(), account = await account(transport), local = PushSyncLocal(state("原始"))
        let (sync, _) = engine(account, local); defer { sync.stop() }
        transport.replies.append(["revision": 1, "document": CloudSync.document(local.state)])
        await sync.start()
        let requests = transport.requests.count
        for _ in 0..<12 { await sync.automaticTick(); await sync.serverChanged(revision: 1) }
        await settle()
        XCTAssertEqual(transport.requests.count, requests)
        XCTAssertEqual(sync.phase, .upToDate)
    }

    func testRevisionNotificationsFetchOnlyTheirOwnTaskScopeAndReconnectReconcilesOnce() async {
        let transport = PushAPITransport(), account = await account(transport)
        let orgLocal = PushSyncLocal(state("原始")), personalLocal = PushSyncLocal(state("原始"))
        let (organization, _) = engine(account, orgLocal), (personal, _) = engine(account, personalLocal, scope: .personal)
        defer { organization.stop(); personal.stop() }
        transport.replies += [["revision": 1, "document": CloudSync.document(orgLocal.state)],
                              ["revision": 1, "document": CloudSync.document(personalLocal.state, scope: .personal)]]
        await organization.start(); await personal.start()
        let count = transport.requests.count
        transport.replies.append(["revision": 2, "document": CloudSync.document(state("组织修改"))])
        await organization.serverChanged(revision: 2); await personal.serverChanged(revision: 1)
        XCTAssertEqual(transport.requests.count, count + 1)
        XCTAssertEqual(transport.requests.last?.url?.path, "/v1/organization/state")
        XCTAssertEqual(personalLocal.state, state("原始")); XCTAssertEqual(orgLocal.state, state("组织修改"))
        transport.replies.append(["revision": 1, "document": CloudSync.document(personalLocal.state, scope: .personal)])
        await personal.serverChanged(revision: 1, reconnected: true)
        XCTAssertEqual(transport.requests.count, count + 2)
        XCTAssertEqual(transport.requests.last?.url?.path, "/v1/personal/state")
        await personal.serverChanged(revision: 1)
        XCTAssertEqual(transport.requests.count, count + 2)
    }

    func testLocalSaveUploadsImmediatelyAndOwnPushDuringPutDoesNotCreateGetLoop() async {
        let transport = PushAPITransport(), account = await account(transport), local = PushSyncLocal(state("本机修改"))
        let (sync, journal) = engine(account, local); defer { sync.stop() }
        transport.replies += [["revision": 1, "document": CloudSync.document(state("原始"))], ["ok": true, "revision": 2]]
        transport.beforeReply = { request in
            if request.httpMethod == "PUT" { await sync.serverChanged(revision: 2) }
        }
        await sync.localDidChange(); await settle()
        XCTAssertEqual(journal.value?.serverRevision, 2); XCTAssertEqual(sync.pendingCount, 0)
        XCTAssertEqual(transport.requests.filter { $0.httpMethod == "PUT" }.count, 1)
        XCTAssertEqual(transport.requests.count, 3, "Fixture login, one GET, one PUT; own notification must not poll")
    }

    func testNewerRemoteRevisionDuringBusyRequestIsNotLost() async {
        let transport = PushAPITransport(), account = await account(transport), local = PushSyncLocal(state("原始"))
        let (sync, journal) = engine(account, local); defer { sync.stop() }
        transport.replies += [["revision": 1, "document": CloudSync.document(state("原始"))],
                              ["revision": 3, "document": CloudSync.document(state("云端第三版"))]]
        var notified = false
        transport.beforeReply = { request in
            if request.httpMethod == "GET", !notified { notified = true; await sync.serverChanged(revision: 3) }
        }
        await sync.start(); await settle()
        XCTAssertEqual(journal.value?.serverRevision, 3)
        XCTAssertEqual(local.state, state("云端第三版")); XCTAssertEqual(transport.requests.count, 3)
    }

    func testFurtherLocalSaveDuringBusyPutIsQueuedWithoutOverwritingIt() async {
        let transport = PushAPITransport(), account = await account(transport), local = PushSyncLocal(state("第一次编辑"))
        let (sync, journal) = engine(account, local); defer { sync.stop() }
        transport.replies += [["revision": 1, "document": CloudSync.document(state("原始"))], ["ok": true, "revision": 2],
                              ["revision": 2, "document": CloudSync.document(state("第一次编辑"))], ["ok": true, "revision": 3]]
        var edited = false
        transport.beforeReply = { request in
            if request.httpMethod == "PUT", !edited {
                edited = true; local.state = self.state("第二次编辑")
                await sync.localDidChange()
            }
        }
        await sync.localDidChange(); await settle()
        XCTAssertEqual(local.state, state("第二次编辑")); XCTAssertEqual(journal.value?.serverRevision, 3)
        XCTAssertEqual(sync.pendingCount, 0); XCTAssertEqual(transport.requests.filter { $0.httpMethod == "PUT" }.count, 2)
    }

    func testPausedAndStoppedEnginesIgnoreEventsAndPushDisconnectIsVisibleWithoutPolling() async {
        let transport = PushAPITransport(), account = await account(transport), local = PushSyncLocal(state("原始"))
        let (sync, _) = engine(account, local)
        transport.replies.append(["revision": 1, "document": CloudSync.document(local.state)])
        await sync.start()
        let count = transport.requests.count
        sync.pushConnectionChanged(connected: false)
        XCTAssertEqual(sync.statusLabel, "推送连接重试中"); XCTAssertNotNil(sync.lastSyncedAt)
        await sync.automaticTick()
        XCTAssertEqual(transport.requests.count, count)
        await sync.pause(); await sync.serverChanged(revision: 3)
        XCTAssertEqual(transport.requests.count, count)
        sync.stop(); await sync.serverChanged(revision: 4, reconnected: true)
        XCTAssertEqual(transport.requests.count, count)
    }

    func testSSEParserHandlesChunkedUTF8MultilineCRLFAndHeartbeatWithoutEvents() throws {
        var decoder = ServerSentEventDecoder(), events: [ServerSentEvent] = []
        for byte in Data(": heartbeat\r\n\r\nevent: state\r\ndata: 第一行\r\ndata: 第二行\r\n\r\n".utf8) {
            if let event = try decoder.consume(byte) { events.append(event) }
        }
        XCTAssertEqual(events, [ServerSentEvent(event: "state", data: "第一行\n第二行")])
        XCTAssertNil(try CloudServerStateEvent.decode(ServerSentEvent(event: "release", data: "{}")))
        XCTAssertThrowsError(try CloudServerStateEvent.decode(ServerSentEvent(event: "state", data: "{\"organizationRevision\":-1,\"personalRevision\":1,\"releaseBuild\":1}")))
    }

    func testSSEParserBoundsBothUnterminatedLinesAndFrames() throws {
        var line = ServerSentEventDecoder()
        for _ in 0..<ServerSentEventDecoder.maximumLineBytes { _ = try line.consume(97) }
        XCTAssertThrowsError(try line.consume(97))
        var frame = ServerSentEventDecoder()
        XCTAssertThrowsError(try Data(String(repeating: "data: payload\n", count: 4000).utf8).forEach { _ = try frame.consume($0) })
    }

    func testSharedStreamDropsOldSessionEventsAndKeepsCredentialsOutOfURL() async throws {
        let transport = PushAPITransport(), account = await account(transport), events = TestIdleServerEventTransport()
        var updates: [CloudServerStateEvent] = []
        let stream = CloudTaskEventStream(account: account, transport: events,
            onState: { update, _ in updates.append(update) }, onConnection: { _, _ in })
        stream.start(); await settle()
        let request = try XCTUnwrap(events.request)
        XCTAssertEqual(request.url?.path, "/v1/events"); XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
        let event = ServerSentEvent(event: "state", data: "{\"organizationRevision\":2,\"personalRevision\":1,\"releaseBuild\":36}")
        try events.handler?(event)
        XCTAssertEqual(updates.count, 1)
        transport.replies.append(["ok": true]); await account.logout()
        XCTAssertFalse(account.eventRequestIsCurrent(request, identity: "https://cloud.example.invalid:443|org-one|owner"))
        try events.handler?(event)
        XCTAssertEqual(updates.count, 1)
        stream.stop(); await settle()
        XCTAssertEqual([1, 2, 3, 4, 8, Int.max].map(CloudTaskEventStream.retryDelay), [1, 2, 4, 8, 60, 60])
    }
}
