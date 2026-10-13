import Foundation
import XCTest
@testable import HeroOOSNative

private final class SharedTaskTransport: CloudTransport {
    var requests: [URLRequest] = []
    var replies: [(Int, JSON)] = []
    var suspendSharedRead: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    var suspending = false
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if suspending && request.url?.path == "/v1/shared/tasks" {
            return try await withCheckedThrowingContinuation { suspendSharedRead = $0 }
        }
        guard !replies.isEmpty else { throw URLError(.notConnectedToInternet) }
        let (status, json) = replies.removeFirst()
        return (try JSONEncoder().encode(json), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    func reply(_ json: JSON, status: Int = 200) { replies.append((status, json)) }
}
private final class SharedTaskCredentials: CloudCredentialStore {
    var credential: CloudCredential?
    func read(serverID: String) throws -> CloudCredential? { credential }
    func write(_ credential: CloudCredential, serverID: String) throws { self.credential = credential }
    func remove(serverID: String) throws { credential = nil }
}
private struct SharedTaskNoBootstrap: CloudBootstrapSource {
    var isAvailable: Bool { false }
    func read() throws -> String { "unused-test-fixture" }
    func consume(_ token: String) throws {}
}

@MainActor final class CloudSharedTasksTests: XCTestCase {
    private func session(user: String = "me", org: String = "org", role: String = "member") -> JSON {
        ["token": .string("test-token-" + user), "user": ["id": .string(user), "username": .string(user)],
         "organization": ["id": .string(org), "name": "Example Org", "role": .string(role)], "memberships": [], "expiresAt": .null]
    }
    private func account(_ transport: SharedTaskTransport, user: String = "me", role: String = "member") async -> CloudAccount {
        let account = CloudAccount(api: CloudAPI(baseURL: URL(string: "https://cloud.example.invalid")!, transport: transport), credentials: SharedTaskCredentials(), bootstrap: SharedTaskNoBootstrap())
        transport.reply(session(user: user, role: role))
        let loggedIn = await account.login(organization: "Example Org", username: "test-user", password: "test-only-long-password")
        XCTAssertTrue(loggedIn)
        return account
    }
    private func shared(id: String = "shared-one", revision: Int = 1, owner: String = "me") -> JSON {
        ["id": .string(id), "revision": .number(Double(revision)), "ownerId": .string(owner),
         "task": ["id": .string(id), "title": "共同任务", "status": "ready", "notes": "基本说明", "peopleWaits": [], "availableAt": "", "due": ""]]
    }

    func testCopyIsStrictProjectionWithNoPrivateTaskIDsOrNestedExtraFields() throws {
        let privateRecord = Record(["id": "secret-private-id", "title": "共享标题", "status": "waiting", "note": "允许共享的说明",
                                    "codexThreadId": "private-thread", "amount": 6000, "localPath": "/private/asset",
                                    "parentId": "secret-parent", "dependencies": ["secret-before"], "history": ["private-log"],
                                    "peopleWaits": [["id": "private-person-id", "person": "alice", "outcome": "交付", "resolved": false, "private": "hidden"]],
                                    "availableAt": "2026-10-20T10:00:00+08:00", "due": "2026-10-30"])
        let draft = CloudSharedDraft.copy(privateRecord, identity: "identity", id: "shared-safe")
        let payload = try draft.validatedTask()
        XCTAssertEqual(Set(payload.object.keys), ["id", "title", "status", "notes", "peopleWaits", "availableAt", "due"])
        XCTAssertEqual(payload["notes"], "允许共享的说明")
        let serialized = String(decoding: try payload.encoded(), as: UTF8.self)
        for secret in ["secret-private-id", "private-thread", "6000", "/private/asset", "secret-parent", "secret-before", "private-log", "private-person-id", "hidden"] {
            XCTAssertFalse(serialized.contains(secret), secret)
        }
    }

    func testPeopleProjectionAndWriteBoundaryDropInjectedPrivateFields() throws {
        var draft = CloudSharedDraft.copy(Record(["title": "标题", "status": "ready", "blockedBy": "alice"]), identity: "me", id: "shared-one")
        draft.task["codexThreadId"] = "private-thread"
        let payload = try draft.validatedTask()
        XCTAssertEqual(payload["peopleWaits"].array.first?["person"], "alice")
        XCTAssertEqual(Set(payload["peopleWaits"].array[0].object.keys), ["id", "person", "outcome", "resolved"])
        XCTAssertEqual(payload["codexThreadId"], .null)
        XCTAssertFalse(String(decoding: try payload.encoded(), as: UTF8.self).contains("private-thread"))
    }

    func testPublishUsesNewIDRevisionZeroAndNeverWritesLocalStore() async throws {
        let transport = SharedTaskTransport(), model = CloudSharedTasksModel()
        let account = await account(transport)
        model.bind(account.identityKey)
        let source = Record(["id": "private-one", "title": "副本", "status": "ready"])
        let draft = CloudSharedDraft.copy(source, identity: account.identityKey!, id: "shared-new")
        transport.reply(["ok": true, "id": "shared-new", "revision": 1])
        let saved = await model.save(draft, account: account)
        XCTAssertTrue(saved)
        let request = transport.requests.last!
        XCTAssertEqual(request.httpMethod, "PUT"); XCTAssertEqual(request.url?.path, "/v1/shared/tasks/shared-new")
        let body = try JSONDecoder().decode(JSON.self, from: request.httpBody!)
        XCTAssertEqual(body["expectedRevision"], 0); XCTAssertFalse(body["mutationId"].string.isEmpty)
        XCTAssertEqual(body["task"]["id"], "shared-new"); XCTAssertEqual(source.id, "private-one")
        XCTAssertEqual(model.tasks.first?.ownerID, "me")
    }

    func testConflictStopsRepeatedWritesUntilRefresh() async throws {
        let transport = SharedTaskTransport(), model = CloudSharedTasksModel()
        let user = await self.account(transport)
        transport.reply(["tasks": [shared(revision: 4)]])
        await model.load(account: user)
        let draft = CloudSharedDraft.edit(model.tasks[0], identity: user.identityKey!)
        transport.reply(["error": "revision_conflict", "message": "已有更新"], status: 409)
        let failed = await model.save(draft, account: user)
        XCTAssertFalse(failed); XCTAssertTrue(model.needsRefresh); XCTAssertEqual(model.tasks[0].revision, 4)
        let count = transport.requests.count
        let retry = await model.save(draft, account: user)
        XCTAssertFalse(retry); XCTAssertEqual(transport.requests.count, count)
        transport.reply(["tasks": [shared(revision: 5)]])
        await model.load(account: user)
        XCTAssertFalse(model.needsRefresh); XCTAssertEqual(model.tasks[0].revision, 5)
        let stale = await model.save(draft, account: user)
        XCTAssertFalse(stale)
    }

    func testMemberCannotEditOrWithdrawOthersButAdminCan() async throws {
        let transport = SharedTaskTransport(), model = CloudSharedTasksModel()
        let user = await account(transport)
        transport.reply(["tasks": [shared(owner: "other")]])
        await model.load(account: user)
        let task = model.tasks[0], draft = CloudSharedDraft.edit(task, identity: user.identityKey!)
        let before = transport.requests.count
        let saved = await model.save(draft, account: user)
        let withdrawn = await model.withdraw(task, account: user)
        XCTAssertFalse(saved); XCTAssertFalse(withdrawn); XCTAssertEqual(transport.requests.count, before)
        XCTAssertTrue(task.canEdit(userID: "admin", isAdmin: true))
        XCTAssertFalse(task.canEdit(userID: nil, isAdmin: true))
    }

    func testWithdrawUsesExpectedRevisionAndRemovesOnlySharedCopy() async throws {
        let transport = SharedTaskTransport(), model = CloudSharedTasksModel()
        let user = await account(transport)
        transport.reply(["tasks": [shared(revision: 3)]])
        await model.load(account: user)
        transport.reply(["ok": true, "id": "shared-one", "revision": 4])
        let removed = await model.withdraw(model.tasks[0], account: user)
        XCTAssertTrue(removed); XCTAssertTrue(model.tasks.isEmpty)
        XCTAssertEqual(transport.requests.last?.httpMethod, "DELETE")
        XCTAssertEqual(transport.requests.last?.url?.query, "expectedRevision=3")
    }

    func testIdentitySwitchClearsStateAndDiscardsLateResponse() async throws {
        let transport = SharedTaskTransport(), model = CloudSharedTasksModel()
        let user = await account(transport)
        model.bind(user.identityKey)
        transport.suspending = true
        let loading = Task { await model.load(account: user) }
        while transport.suspendSharedRead == nil { await Task.yield() }
        model.bind("other-identity")
        XCTAssertTrue(model.tasks.isEmpty); XCTAssertFalse(model.busy)
        let response = HTTPURLResponse(url: URL(string: "https://cloud.example.invalid/v1/shared/tasks")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let result: JSON = ["tasks": .array([shared()])]
        transport.suspendSharedRead?.resume(returning: (try JSONEncoder().encode(result), response))
        await loading.value
        XCTAssertTrue(model.tasks.isEmpty); XCTAssertNil(model.error); XCTAssertNil(model.message)
    }

    func testInvalidIdentifiersAndEmptyTitleAreRejected() throws {
        for id in ["../me", "a?x=1", "a/b", "", String(repeating: "x", count: 161)] { XCTAssertFalse(CloudSharedDraft.safeID(id)) }
        let draft = CloudSharedDraft.copy(Record(["title": " ", "status": "ready"]), identity: "me")
        XCTAssertThrowsError(try draft.validatedTask())
        XCTAssertThrowsError(try CloudSharedTask.parse(["id": "a/b", "revision": 1, "ownerId": "me", "task": ["id": "a/b"]]))
    }
}
