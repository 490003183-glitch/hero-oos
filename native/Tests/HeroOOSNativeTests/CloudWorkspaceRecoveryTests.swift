import XCTest
@testable import HeroOOSNative

@MainActor final class CloudWorkspaceRecoveryTests: XCTestCase {
    func testWorkspaceIsolationIncludesOrganizationAndMigrationRequiresExactIdentity() {
        let root = URL(fileURLWithPath: "/test-only/accounts", isDirectory: true)
        let a = CloudWorkspace.accountDirectory(serverID: "server", userID: "user", organizationID: "org-a", under: root)
        let b = CloudWorkspace.accountDirectory(serverID: "server", userID: "user", organizationID: "org-b", under: root)
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(CloudWorkspace.requestedLocalImport(identity: "server|org-a|user", arguments: ["app", "--import-local-workspace-for", "server|org-a|user"]))
        XCTAssertFalse(CloudWorkspace.requestedLocalImport(identity: "server|org-b|user", arguments: ["app", "--import-local-workspace-for", "server|org-a|user"]))
        XCTAssertFalse(CloudWorkspace.requestedLocalImport(identity: "server|org-a|user", arguments: ["app"]))
    }
    func testGraphRecoveryCopiesOnlyIntoEmptyLayoutAndPreservesOriginal() throws {
        let suite = "hero-import-layout-test-\(UUID().uuidString)", defaults = UserDefaults(suiteName: "hero-import-layout-test")!
        defer { defaults.removeObject(forKey: "HeroOOS.taskGraph.v1." + suite); defaults.removeObject(forKey: "HeroOOS.taskGraph.v1." + suite + "-copy"); defaults.removeObject(forKey: "HeroOOS.taskGraph.v1." + suite + "-copy.unfinishedDefault") }
        var layout = GraphLayout(); layout.positions["task"] = GraphPoint(CGPoint(x: 300, y: -50)); layout.zoom = 0.59
        let original = try JSONEncoder().encode(layout)
        defaults.set(original, forKey: "HeroOOS.taskGraph.v1." + suite)
        CloudWorkspace.restoreGraphLayout(from: suite, to: suite + "-copy", defaults: defaults)
        XCTAssertEqual(defaults.data(forKey: "HeroOOS.taskGraph.v1." + suite + "-copy"), original)
        layout.zoom = 2
        let edited = try JSONEncoder().encode(layout)
        defaults.set(edited, forKey: "HeroOOS.taskGraph.v1." + suite + "-copy")
        CloudWorkspace.restoreGraphLayout(from: suite, to: suite + "-copy", defaults: defaults)
        XCTAssertEqual(defaults.data(forKey: "HeroOOS.taskGraph.v1." + suite + "-copy"), edited)
        XCTAssertEqual(defaults.data(forKey: "HeroOOS.taskGraph.v1." + suite), original)
    }
    private var state: JSON { ["meta": ["version": 1], "tasks": [["id": "task-one", "title": "必须保留", "status": "ready"]]] }
    private func factory(_ root: URL) -> (OOSStore, CollageStore) {
        let fixture = state
        let api = OOSAPI(base: root, transport: { path, _, _, _ in
            if path == "/api/state" { return ["state": fixture] }
            if path == "/api/collages" { return ["collages": ["canvases": [], "activeCanvasId": ""]] }
            if path == "/api/state-ops" { throw APIError(code: "validation_failed", payload: ["message": "测试：标题必须修正后才能保存"]) }
            return ["ok": true]
        })
        return (OOSStore(api: api, recoverDrafts: false), CollageStore(api: api, recoverDrafts: false))
    }
    private func login(_ account: CloudAccount, transport: TestCloudTransport, user: String) async {
        transport.reply(["token": .string("test-token-" + user), "user": ["id": .string(user), "username": .string(user)],
                         "organization": ["id": "org-one", "name": "Example Org", "role": "owner"],
                         "memberships": [["id": "org-one", "name": "Example Org", "role": "owner", "status": "approved"]], "expiresAt": "2026-12-01T00:00:00Z"])
        let ok = await account.login(organization: "Example Org", username: user, password: "test-only-password-123")
        XCTAssertTrue(ok)
    }
    func testFailedSwitchFromLocalRecoversDraftByLogoutWithoutSuccessfulFlush() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hero-workspace-recovery-\(UUID().uuidString)")
        let workspace = CloudWorkspace(localRoot: root, accountsRoot: root.appendingPathComponent("accounts"), makeStores: factory)
        let transport = TestCloudTransport()
        let account = CloudAccount(api: CloudAPI(baseURL: URL(string: "https://cloud.example.invalid")!, transport: transport), credentials: TestCloudCredentials(), bootstrap: TestCloudBootstrap())
        XCTAssertFalse(workspace.matches(account: account)) // Never expose an uninitialized empty store.
        await workspace.activate(account: account)
        let original = workspace.store
        defer { workspace.store.stop(); workspace.sync?.stop() }
        XCTAssertTrue(workspace.matches(account: account))
        original.edit("task-one", "title", "")
        await login(account, transport: transport, user: "different-user")
        XCTAssertFalse(workspace.matches(account: account)) // Hide old identity immediately, before activate runs.
        await workspace.activate(account: account)
        XCTAssertFalse(workspace.ready); XCTAssertTrue(workspace.store === original)
        transport.reply(["ok": true]); await account.logout(); await workspace.activate(account: account)
        XCTAssertTrue(workspace.ready); XCTAssertTrue(workspace.matches(account: account)); XCTAssertTrue(workspace.store === original)
        XCTAssertEqual(workspace.store.pending["task-one"]?["title"], "")
        XCTAssertTrue(workspace.error?.contains("已返回原工作区") == true)
    }
    func testCloudDraftRecoveryRequiresReauthenticationOfOriginalIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hero-cloud-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = CloudWorkspace(localRoot: root, accountsRoot: root.appendingPathComponent("accounts"), makeStores: factory)
        let transport = TestCloudTransport()
        let account = CloudAccount(api: CloudAPI(baseURL: URL(string: "https://cloud.example.invalid")!, transport: transport), credentials: TestCloudCredentials(), bootstrap: TestCloudBootstrap())
        await login(account, transport: transport, user: "original-user")
        transport.reply(["revision": 0, "document": nil])
        await workspace.activate(account: account)
        let original = workspace.store
        defer { workspace.store.stop(); workspace.sync?.stop() }
        XCTAssertTrue(workspace.matches(account: account))
        original.edit("task-one", "title", "")
        transport.reply(["ok": true]); await account.logout(); await workspace.activate(account: account)
        XCTAssertFalse(workspace.ready); XCTAssertFalse(workspace.matches(account: account))
        await login(account, transport: transport, user: "other-user"); await workspace.activate(account: account)
        XCTAssertFalse(workspace.ready); XCTAssertFalse(workspace.matches(account: account))
        XCTAssertTrue(workspace.store === original)
        transport.reply(["ok": true]); await account.logout()
        await login(account, transport: transport, user: "original-user"); await workspace.activate(account: account)
        XCTAssertTrue(workspace.ready); XCTAssertTrue(workspace.matches(account: account)); XCTAssertTrue(workspace.store === original)
        XCTAssertEqual(workspace.store.pending["task-one"]?["title"], "")
    }
}
