import XCTest
@testable import HeroOOSNative

final class TestCloudTransport: CloudTransport {
    var requests: [URLRequest] = []
    var replies: [(Int, JSON, URL?)] = []
    var failure: Error?
    var onSend: ((URLRequest) throws -> Void)?
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        try onSend?(request)
        if let failure { throw failure }
        guard !replies.isEmpty else { throw CloudAccountError(code: "no_fixture", message: "没有测试响应") }
        let (status, value, destination) = replies.removeFirst()
        return (try JSONEncoder().encode(value), HTTPURLResponse(url: destination ?? request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    func reply(_ json: JSON, status: Int = 200, destination: URL? = nil) { replies.append((status, json, destination)) }
}
final class TestCloudCredentials: CloudCredentialStore {
    var values: [String: CloudCredential] = [:]
    var removals: [String] = []
    var failWrite = false
    func read(serverID: String) throws -> CloudCredential? { values[serverID] }
    func write(_ credential: CloudCredential, serverID: String) throws {
        if failWrite { throw CloudAccountError(code: "keychain", message: "钥匙串测试失败") }
        values[serverID] = credential
    }
    func remove(serverID: String) throws { values.removeValue(forKey: serverID); removals.append(serverID) }
}

final class GatedRestoreTransport: CloudTransport {
    var waiting: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    var request: URLRequest?
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.path == "/v1/auth/logout" {
            return (try JSONEncoder().encode(JSON.object(["ok": .bool(true)])), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        self.request = request
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }
    func finish(_ value: JSON, status: Int = 200) throws {
        let continuation = waiting; waiting = nil
        continuation?.resume(returning: (try JSONEncoder().encode(value), HTTPURLResponse(url: request!.url!, statusCode: status, httpVersion: nil, headerFields: nil)!))
    }
}
final class TestCloudBootstrap: CloudBootstrapSource {
    var isAvailable = true
    var consumed = false
    func read() throws -> String { "test-only-bootstrap-token" }
    func consume(_ token: String) throws { consumed = token == "test-only-bootstrap-token"; isAvailable = false }
}

@MainActor final class CloudAccountTests: XCTestCase {
    private let password = "test-only-password-123"
    private func session(token: Bool = true, user: String = "user-one", organization: String = "org-one", role: String = "owner") -> JSON {
        var value: JSON = ["user": ["id": .string(user), "username": "owner"],
                           "organization": ["id": .string(organization), "name": "Example Org", "role": .string(role)],
                           "memberships": [["id": .string(organization), "name": "Example Org", "role": .string(role), "status": "approved"]],
                           "expiresAt": "2026-12-01T00:00:00Z"]
        if token { value["token"] = "test-only-opaque-token" }
        return value
    }
    private func make(_ transport: TestCloudTransport, credentials: TestCloudCredentials = TestCloudCredentials(), bootstrap: TestCloudBootstrap = TestCloudBootstrap()) -> CloudAccount {
        CloudAccount(api: CloudAPI(baseURL: URL(string: "https://cloud.example.invalid")!, transport: transport), credentials: credentials, bootstrap: bootstrap)
    }

    func testUnconfiguredLiveTransportFailsWithoutNetwork() async {
        let api = CloudAPI(baseURL: URL(string: "https://cloud.example.invalid")!)
        do { _ = try await api.request("/v1/me"); XCTFail("Unconfigured cloud must stay offline") }
        catch let error as CloudAccountError { XCTAssertEqual(error.code, "not_configured") }
        catch { XCTFail("Unexpected error: \(error)") }
    }
    func testHTTPSAndSameOriginAreRequiredBeforeTransport() async throws {
        let transport = TestCloudTransport()
        let api = CloudAPI(baseURL: URL(string: "https://cloud.example.invalid")!, transport: transport)
        for path in ["https://elsewhere.invalid/v1/me", "//elsewhere.invalid/v1/me", "/api/state", "/v1/me#fragment", "/v1/../secrets", "/v1/%2e%2e/secrets", "/v1/\\evil"] {
            XCTAssertThrowsError(try api.requestURL(path), path)
        }
        XCTAssertThrowsError(try CloudAPI(baseURL: URL(string: "http://cloud.example.invalid")!, transport: transport).requestURL("/v1/me"))
        XCTAssertThrowsError(try CloudAPI(baseURL: URL(string: "https://user:pass@cloud.example.invalid")!, transport: transport).requestURL("/v1/me"))
        XCTAssertEqual(try api.requestURL("/v1/me").absoluteString, "https://cloud.example.invalid/v1/me")
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testRedirectAndUnexpectedCrossOriginResponseAreRejected() async throws {
        let transport = TestCloudTransport()
        let checked = CloudAPI(baseURL: URL(string: "https://cloud.example.invalid")!, transport: transport)
        for (status, destination) in [(302, URL(string: "https://cloud.example.invalid/v1/else")), (200, URL(string: "https://other.invalid/v1/me"))] {
            transport.reply(["ok": true], status: status, destination: destination)
            do { _ = try await checked.request("/v1/me", token: "opaque-token"); XCTFail("Must reject redirects") }
            catch let error as CloudAccountError { XCTAssertEqual(error.code, "redirect_blocked") }
        }
    }

    func testLoginStoresOpaqueSessionInCredentialStoreWithoutPassword() async throws {
        let transport = TestCloudTransport(), credentials = TestCloudCredentials()
        transport.reply(session())
        let account = make(transport, credentials: credentials)
        let ok = await account.login(organization: " Example Org ", username: " owner ", password: password)
        XCTAssertTrue(ok)
        XCTAssertEqual(account.userID, "user-one"); XCTAssertEqual(account.organizationID, "org-one")
        XCTAssertEqual(account.identityKey, "https://cloud.example.invalid:443|org-one|user-one")
        XCTAssertEqual(credentials.values[account.api.serverID]?.token, "test-only-opaque-token")
        XCTAssertEqual(credentials.values[account.api.serverID]?.userID, "user-one")
        XCTAssertNil(transport.requests[0].value(forHTTPHeaderField: "Authorization"))
        let body = try JSONDecoder().decode(JSON.self, from: transport.requests[0].httpBody!)
        XCTAssertEqual(body["organization"], "Example Org"); XCTAssertEqual(body["username"], "owner")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(credentials.values), as: UTF8.self).contains(password))
    }

    func testRegistrationIsPendingAndNeverEstablishesSession() async {
        let transport = TestCloudTransport(), credentials = TestCloudCredentials()
        transport.reply(["ok": true, "status": "pending"])
        let account = make(transport, credentials: credentials)
        let ok = await account.register(organization: "Example Org", username: "new-user", password: password)
        XCTAssertTrue(ok); XCTAssertNil(account.session); XCTAssertTrue(credentials.values.isEmpty)
        XCTAssertTrue(account.message?.contains("等待组织管理员审批") == true)
    }

    func testBootstrapRequiresMatchingPasswordAndConsumesOnlyAfterSuccess() async {
        let transport = TestCloudTransport(), bootstrap = TestCloudBootstrap()
        let account = make(transport, bootstrap: bootstrap)
        let mismatch = await account.bootstrapAdministrator(username: "owner", password: password, confirmation: "different")
        XCTAssertFalse(mismatch); XCTAssertTrue(transport.requests.isEmpty); XCTAssertFalse(bootstrap.consumed)
        transport.reply(["ok": false, "error": "forbidden", "message": "不可初始化"], status: 403)
        let denied = await account.bootstrapAdministrator(username: "owner", password: password, confirmation: password)
        XCTAssertFalse(denied); XCTAssertFalse(bootstrap.consumed); XCTAssertNil(account.session)
        transport.reply(session())
        let success = await account.bootstrapAdministrator(username: "owner", password: password, confirmation: password)
        XCTAssertTrue(success); XCTAssertTrue(bootstrap.consumed); XCTAssertFalse(account.bootstrapAvailable)
    }

    func testRestoreRejectsIdentityMismatchAndNeverLoadsAnotherServerCredential() async throws {
        let transport = TestCloudTransport(), credentials = TestCloudCredentials()
        let account = make(transport, credentials: credentials)
        credentials.values["https://elsewhere.invalid:443"] = CloudCredential(token: "elsewhere-token", userID: "other", organizationID: "other")
        await account.restoreSession()
        XCTAssertTrue(transport.requests.isEmpty)
        credentials.values[account.api.serverID] = CloudCredential(token: "saved-token", userID: "user-one", organizationID: "org-one")
        transport.reply(session(token: false, user: "wrong-user"))
        await account.restoreSession()
        XCTAssertNil(account.session); XCTAssertNil(credentials.values[account.api.serverID])
        XCTAssertNotNil(credentials.values["https://elsewhere.invalid:443"])
    }

    func testRestorePreservesKeychainOnNetworkFailureAndCanRetry() async {
        let transport = TestCloudTransport(), credentials = TestCloudCredentials()
        let account = make(transport, credentials: credentials)
        credentials.values[account.api.serverID] = CloudCredential(token: "saved-token", userID: "user-one", organizationID: "org-one")
        transport.failure = URLError(.notConnectedToInternet)
        await account.restoreSession()
        XCTAssertNil(account.session); XCTAssertNotNil(credentials.values[account.api.serverID]); XCTAssertFalse(account.busy)
        transport.failure = nil; transport.reply(session(token: false))
        await account.restoreSession()
        XCTAssertEqual(account.userID, "user-one")
        XCTAssertEqual(transport.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer saved-token")
    }

    func testUnauthorizedRevokesCachedSessionAndSurfacesServerMessage() async throws {
        let transport = TestCloudTransport(), credentials = TestCloudCredentials()
        transport.reply(session()); let account = make(transport, credentials: credentials)
        _ = await account.login(organization: "Example Org", username: "owner", password: password)
        transport.reply(["ok": false, "error": "unauthorized", "message": "成员资格已停用"], status: 401)
        do { _ = try await account.authorizedAPI("/v1/me"); XCTFail("Expected unauthorized") }
        catch let error as CloudAccountError { XCTAssertEqual(error.message, "成员资格已停用") }
        XCTAssertNil(account.session); XCTAssertNil(account.identityKey); XCTAssertTrue(credentials.values.isEmpty)
    }

    func testBackgroundRestoreOpensOwnCacheBeforeNetworkReturnsThenRevokesOn401() async throws {
        let transport = GatedRestoreTransport(), credentials = TestCloudCredentials()
        let account = CloudAccount(api: CloudAPI(baseURL: URL(string: "https://cloud.example.invalid")!, transport: transport), credentials: credentials, bootstrap: TestCloudBootstrap())
        let cached = try JSONDecoder().decode(CloudSession.self, from: JSONEncoder().encode(session(token: false)))
        credentials.values[account.api.serverID] = CloudCredential(token: "cached-test-token", userID: "user-one", organizationID: "org-one", cachedSession: cached)
        await account.restoreSession(validateInBackground: true)
        XCTAssertEqual(account.userID, "user-one")
        XCTAssertFalse(account.busy, "Offline local startup must not wait for a network timeout")
        for _ in 0..<100 where transport.waiting == nil { await Task.yield() }
        XCTAssertNotNil(transport.waiting)
        try transport.finish(["ok": false, "error": "unauthorized", "message": "登录已过期"], status: 401)
        for _ in 0..<100 where account.session != nil { await Task.yield() }
        XCTAssertNil(account.session)
        XCTAssertNil(credentials.values[account.api.serverID])
    }

    func testBackgroundRestoreNetworkFailureKeepsCacheAvailable() async throws {
        let transport = GatedRestoreTransport(), credentials = TestCloudCredentials()
        let account = CloudAccount(api: CloudAPI(baseURL: URL(string: "https://cloud.example.invalid")!, transport: transport), credentials: credentials, bootstrap: TestCloudBootstrap())
        let cached = try JSONDecoder().decode(CloudSession.self, from: JSONEncoder().encode(session(token: false)))
        credentials.values[account.api.serverID] = CloudCredential(token: "cached-test-token", userID: "user-one", organizationID: "org-one", cachedSession: cached)
        await account.restoreSession(validateInBackground: true)
        for _ in 0..<100 where transport.waiting == nil { await Task.yield() }
        XCTAssertNotNil(transport.waiting)
        transport.waiting?.resume(throwing: URLError(.notConnectedToInternet)); transport.waiting = nil
        for _ in 0..<100 where account.error == nil { await Task.yield() }
        XCTAssertEqual(account.userID, "user-one")
        XCTAssertNotNil(credentials.values[account.api.serverID])
        XCTAssertTrue(account.message?.contains("离线") == true)
    }

    func testLateBackgroundVerificationCannotRestoreLoggedOutIdentity() async throws {
        let transport = GatedRestoreTransport(), credentials = TestCloudCredentials()
        let account = CloudAccount(api: CloudAPI(baseURL: URL(string: "https://cloud.example.invalid")!, transport: transport), credentials: credentials, bootstrap: TestCloudBootstrap())
        let cached = try JSONDecoder().decode(CloudSession.self, from: JSONEncoder().encode(session(token: false)))
        credentials.values[account.api.serverID] = CloudCredential(token: "cached-test-token", userID: "user-one", organizationID: "org-one", cachedSession: cached)
        await account.restoreSession(validateInBackground: true)
        for _ in 0..<100 where transport.waiting == nil { await Task.yield() }
        XCTAssertNotNil(transport.waiting)
        await account.logout()
        XCTAssertNil(account.session)
        try transport.finish(session(token: false))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(account.session)
        XCTAssertNil(credentials.values[account.api.serverID])
    }

    func testKeychainFailureRevokesUnstoredTokenAndDoesNotLogin() async {
        let transport = TestCloudTransport(), credentials = TestCloudCredentials()
        credentials.failWrite = true; transport.reply(session()); transport.reply(["ok": true])
        let account = make(transport, credentials: credentials)
        let ok = await account.login(organization: "Example Org", username: "owner", password: password)
        XCTAssertFalse(ok); XCTAssertNil(account.session)
        XCTAssertEqual(transport.requests.last?.url?.path, "/v1/auth/logout")
        XCTAssertEqual(transport.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer test-only-opaque-token")
    }

    func testJoinAndAdminApprovalUseAuthorizedMembershipIdentifiers() async {
        let transport = TestCloudTransport(); transport.reply(session())
        let account = make(transport)
        _ = await account.login(organization: "Example Org", username: "owner", password: password)
        transport.reply(["ok": true]); transport.reply(["memberships": [["id": "org-two", "name": "Other", "role": "member", "status": "pending"]]])
        let joined = await account.joinOrganization(" Other ")
        XCTAssertTrue(joined); XCTAssertEqual(account.session?.memberships.first?.id, "org-two")
        let member = CloudMember(id: "membership-123", userId: "second-user", username: "second", role: "member", status: "pending")
        transport.reply(["ok": true]); transport.reply(["members": [["id": "membership-123", "userId": "second-user", "username": "second", "role": "member", "status": "approved"]]])
        await account.updateMember(member, status: "approved", role: "member")
        XCTAssertEqual(transport.requests[3].url?.path, "/v1/members/membership-123")
        XCTAssertEqual(transport.requests[3].httpMethod, "PATCH")
        XCTAssertEqual(account.members.first?.status, "approved")
        XCTAssertTrue(transport.requests.dropFirst().allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-only-opaque-token" })
    }

    func testMemberCannotApproveAndLocalValidationDoesNotSendPasswords() async {
        let transport = TestCloudTransport(); transport.reply(session(role: "member"))
        let account = make(transport)
        _ = await account.login(organization: "Example Org", username: "owner", password: password)
        await account.updateMember(CloudMember(id: "m2", userId: "u2", username: "u2", role: "member", status: "pending"), status: "approved", role: "member")
        XCTAssertEqual(transport.requests.count, 1)
        let invalid = await account.register(organization: "Example Org", username: "a", password: "short")
        XCTAssertFalse(invalid); XCTAssertEqual(transport.requests.count, 1)
    }

    func testLogoutClearsOnlyThisServerCredentialEvenWhenOffline() async {
        let transport = TestCloudTransport(), credentials = TestCloudCredentials()
        transport.reply(session()); let account = make(transport, credentials: credentials)
        _ = await account.login(organization: "Example Org", username: "owner", password: password)
        credentials.values["another-server"] = CloudCredential(token: "other", userID: "other", organizationID: "other")
        transport.failure = URLError(.timedOut)
        await account.logout()
        XCTAssertNil(account.session); XCTAssertNil(credentials.values[account.api.serverID])
        XCTAssertNotNil(credentials.values["another-server"])
        XCTAssertTrue(account.message?.contains("已从本机退出") == true)
    }
}
