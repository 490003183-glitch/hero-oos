import XCTest
@testable import HeroOOSNative

final class CoreTests: XCTestCase {
    func testUnknownFieldsRoundTrip() throws {
        let source = Data(#"{"id":"one","title":"任务","futureField":{"x":[1,true,null]}}"#.utf8)
        let record = try JSONDecoder().decode(Record.self, from: source)
        let restored = try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(restored, try JSONDecoder().decode(JSON.self, from: source))
    }
    func testIndependentTaskEditsMerge() throws {
        let base = Record(["id": .string("a"), "title": .string("旧名称"), "priority": .number(5)])
        var remote = base; remote["priority"] = .number(9)
        XCTAssertEqual(try Merge.patch(base: base, remote: remote, changes: ["title": .string("新名称")]), ["title": .string("新名称")])
    }
    func testSameFieldConflictIsNotSilentlyOverwritten() {
        let base = Record(["title": .string("原始")]); let remote = Record(["title": .string("外部修改")])
        XCTAssertThrowsError(try Merge.patch(base: base, remote: remote, changes: ["title": .string("本地修改")]))
    }
    func testCollageMergePreservesExternalItemsAndLocalGeometry() throws {
        let base: JSON = .array([.object(["id": .string("a"), "x": .number(10)])])
        let local: JSON = .array([.object(["id": .string("a"), "x": .number(30)])])
        let remote: JSON = .array([.object(["id": .string("a"), "x": .number(10)]), .object(["id": .string("b"), "x": .number(50)])])
        let result = try CollageMerge.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(result.array.count, 2); XCTAssertEqual(result.array[0]["x"].number, 30)
    }
    func testCollageDeleteVersusEditConflicts() {
        let base: JSON = .array([.object(["id": .string("a"), "x": .number(10)])])
        let remote: JSON = .array([.object(["id": .string("a"), "x": .number(30)])])
        XCTAssertThrowsError(try CollageMerge.merge(base: base, local: .array([]), remote: remote))
    }
    func testRotatedCoordinatesRoundTrip() {
        let item = Record(["x": .number(120), "y": .number(240), "width": .number(500), "height": .number(300), "rotation": .number(37)])
        let point = CGPoint(x: 35, y: 87)
        let result = CanvasGeometry.local(CanvasGeometry.world(point, item: item), item: item)
        XCTAssertEqual(result.x, point.x, accuracy: 0.0001); XCTAssertEqual(result.y, point.y, accuracy: 0.0001)
    }
    @MainActor func testCancelledDependencyRemainsBlocked() {
        let store = OOSStore(recoverDrafts: false)
        store.state = .object(["tasks": .array([
            .object(["id": .string("up"), "title": .string("前置"), "status": .string("cancelled")]),
            .object(["id": .string("down"), "dependsOn": .array([.string("up")])])
        ])])
        XCTAssertEqual(store.blocked(store.tasks[1]), "等任务：前置已放弃：前置")
    }
}

final class IntegrationTests: SwiftIntegrationCase {
    @MainActor func testCreateAutosaveExternalEditAndRecovery() async throws {
        let store = OOSStore(api: api, recoverDrafts: false); await store.refresh()
        let created = await store.createTask(title: "原生自动保存验证")
        let id = try XCTUnwrap(created)
        store.edit(id, "statusNote", .string("已输入的详情"))
        try await Task.sleep(for: .seconds(1.2))
        let fresh = try await api.request("/api/state")["state"]
        XCTAssertEqual(fresh["tasks"].records.first { $0.id == id }?.text("statusNote"), "已输入的详情")
        XCTAssertTrue(store.pending.isEmpty)
        store.edit(id, "title", .string("本地名称"))
        let payload: JSON = .object([
            "expectedVersion": fresh["meta"]["version"],
            "clientMutationId": .string("test-\(UUID().uuidString)"),
            "operations": .array([.object(["type": .string("task.update"), "id": .string(id), "changes": .object(["priority": .number(8)])])])
        ])
        _ = try await api.request("/api/state-ops", method: "POST", body: payload)
        let saved = await store.flush(); XCTAssertTrue(saved)
        XCTAssertEqual(store.task(id)?.number("priority"), 8)
        XCTAssertEqual(store.task(id)?.title, "本地名称")
        store.edit(id, "status", .string("completed")); let completed = await store.flush(); XCTAssertTrue(completed)
        XCTAssertEqual(store.task(id)?.status, "completed")
        store.edit(id, "status", .string("ready")); let recovered = await store.flush(); XCTAssertTrue(recovered)
        XCTAssertEqual(store.task(id)?.status, "ready")
    }
    @MainActor func testSameFieldExternalConflictRetainsInput() async throws {
        let store = OOSStore(api: api, recoverDrafts: false); await store.refresh()
        let created = await store.createTask(title: "冲突测试")
        let id = try XCTUnwrap(created)
        store.edit(id, "title", .string("我的修改"))
        _ = try await api.request("/api/state-ops", method: "POST", body: .object([
            "expectedVersion": .number(Double(store.version)),
            "clientMutationId": .string("test-\(UUID().uuidString)"),
            "operations": .array([.object(["type": .string("task.update"), "id": .string(id), "changes": .object(["title": .string("其他 AI 修改")])])])
        ]))
        let saved = await store.flush(); XCTAssertFalse(saved)
        XCTAssertEqual(store.task(id)?.title, "我的修改")
        let remote = try await api.request("/api/state")["state"]["tasks"].records.first { $0.id == id }
        XCTAssertEqual(remote?.title, "其他 AI 修改")
    }
    func testStaleCanvasWriteRejected() async throws {
        let original = try await api.request("/api/collages")["collages"]
        var changed = original
        var canvases = changed["canvases"].array; canvases[0]["name"] = .string("画布-\(UUID().uuidString)"); changed["canvases"] = .array(canvases)
        _ = try await api.request("/api/collages", method: "PUT", body: .object(["collages": changed, "expectedCollages": original]))
        do {
            _ = try await api.request("/api/collages", method: "PUT", body: .object(["collages": original, "expectedCollages": original]))
            XCTFail("Stale write must fail")
        } catch let error as APIError { XCTAssertEqual(error.code, "collage_conflict") }
    }
}
