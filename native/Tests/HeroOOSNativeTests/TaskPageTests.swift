import XCTest
@testable import HeroOOSNative

final class TaskPageTests: SwiftIntegrationCase {
    private let first = "page-11111111-1111-4111-8111-111111111111"
    private let second = "page-22222222-2222-4222-8222-222222222222"
    private func addPages() throws {
        _ = try mutate([
            ["type": "taskPage.create", "taskPage": ["id": .string(first), "title": "创作", "future": ["keep": true]]],
            ["type": "taskPage.create", "taskPage": ["id": .string(second), "title": "生活"]]
        ])
    }
    func testCreateRenameAndReopenPreserveStableIdentityAndUnknownFields() throws {
        try addPages()
        _ = try mutate([["type": "task.create", "task": ["id": "a", "title": "写作", "taskSpace": .string(first), "note": "保留"]]])
        _ = try mutate([["type": "taskPage.update", "id": .string(first), "changes": ["title": "  小说创作  "]]])
        let reopened = try StateRuntime(root: root).readState()
        XCTAssertEqual(reopened["taskPages"].records.first?.title, "小说创作")
        XCTAssertEqual(reopened["taskPages"].array.first?["future"], ["keep": true])
        XCTAssertEqual(reopened["tasks"].records.first?.text("taskSpace"), first)
        XCTAssertEqual(reopened["tasks"].records.first?.text("note"), "保留")
    }
    func testInvalidDuplicateReservedNamesAndMissingPageAreAtomic() throws {
        try addPages()
        let before = try runtime.readState()
        for title in ["", "   ", "任务", "今日", "创作", String(repeating: "a", count: 61)] {
            XCTAssertThrowsError(try mutate([["type": "taskPage.create", "taskPage": ["title": .string(title)]]]))
            XCTAssertEqual(try runtime.readState(), before)
        }
        XCTAssertThrowsError(try mutate([["type": "taskPage.create", "taskPage": ["id": "work", "title": "工作页"]]]))
        XCTAssertThrowsError(try mutate([["type": "taskPage.update", "id": .string(second), "changes": ["title": "创作"]]]))
        XCTAssertThrowsError(try mutate([["type": "task.create", "task": ["title": "孤立任务", "taskSpace": "page-33333333-3333-4333-8333-333333333333"]]]))
        XCTAssertEqual(try runtime.readState(), before)
    }
    func testNonemptyPageCannotBeDeletedEvenWithOnlyArchivedOrCompletedTasks() throws {
        try addPages()
        _ = try mutate([["type": "task.create", "task": ["id": "a", "title": "已归档", "taskSpace": .string(first), "status": "completed", "archived": true]]])
        let before = try runtime.readState()
        XCTAssertThrowsError(try mutate([["type": "taskPage.delete", "id": .string(first)]], confirmed: true))
        XCTAssertEqual(try runtime.readState(), before)
        let deleted = try mutate([["type": "taskPage.delete", "id": .string(second)]], confirmed: true)
        XCTAssertEqual(try runtime.readState()["taskPages"].array.count, 1)
        _ = try mutate([["type": "receipt.undo", "receiptId": deleted["receipt"]["id"]]])
        XCTAssertEqual(try runtime.readState()["taskPages"].array.count, 2)
    }
    func testCustomPageRelationshipsInheritanceAndOrderingStayIsolated() throws {
        try addPages()
        _ = try mutate([
            ["type": "task.create", "task": ["id": "a", "title": "父任务", "taskSpace": .string(first)]],
            ["type": "task.create", "task": ["id": "child", "title": "子任务", "parentId": "a"]],
            ["type": "task.create", "task": ["id": "peer", "title": "同页任务", "taskSpace": .string(first), "dependsOn": ["child"]]],
            ["type": "task.create", "task": ["id": "b", "title": "另一页", "taskSpace": .string(second)]]
        ])
        let before = try runtime.readState()
        XCTAssertEqual(before["tasks"].records.first { $0.id == "child" }?.text("taskSpace"), first)
        for changes: JSON in [["parentId": "b"], ["taskSpace": .string(second)]] {
            XCTAssertThrowsError(try mutate([["type": "task.update", "id": "child", "changes": changes]]))
        }
        XCTAssertThrowsError(try mutate([["type": "task.reorder", "id": "a", "mode": "board", "placement": "before", "anchorId": "b"]]))
        XCTAssertEqual(try runtime.readState(), before)
        _ = try mutate([["type": "task.reorder", "id": "peer", "mode": "board", "placement": "first"]])
        let records = try runtime.readState()["tasks"].records
        XCTAssertEqual(records.first { $0.id == "b" }?["boardOrder"], .null)
        XCTAssertEqual(records.first { $0.id == "peer" }?["boardOrder"], 0)
    }
    func testPageMutationsRespectVersionAndIdempotencyAndUndoRename() throws {
        try addPages()
        let payload: JSON = ["expectedVersion": try runtime.readState()["meta"]["version"], "clientMutationId": "rename-once",
                             "operations": [["type": "taskPage.update", "id": .string(first), "changes": ["title": "新名字"]]]]
        let renamed = try runtime.mutate(payload)
        XCTAssertTrue(try runtime.mutate(payload)["duplicate"].bool)
        var stale = payload; stale["clientMutationId"] = "different"
        XCTAssertThrowsError(try runtime.mutate(stale))
        _ = try mutate([["type": "receipt.undo", "receiptId": renamed["receipt"]["id"]]])
        XCTAssertEqual(try runtime.readState()["taskPages"].records.first?.title, "创作")
    }
    @MainActor func testStoreCreatesTaskInPageAutosavesAndKeepsOtherPagesOut() async throws {
        let store = OOSStore(api: api, recoverDrafts: false); await store.refresh()
        let created = await store.createTaskPage(title: "个人学习")
        let id = try XCTUnwrap(created), space = try XCTUnwrap(TaskSpace(rawValue: id))
        let taskID = try await createTask(store, space: space)
        store.edit(taskID, "note", "自动保存内容")
        var saved = await store.flush(); XCTAssertTrue(saved)
        let renamed = await store.renameTaskPage(id, title: "学习计划"); XCTAssertTrue(renamed)
        let reopened = OOSStore(api: api, recoverDrafts: false); await reopened.refresh()
        XCTAssertEqual(reopened.title(for: space), "学习计划")
        XCTAssertEqual(reopened.task(taskID)?.text("note"), "自动保存内容")
        XCTAssertEqual(reopened.tasks.filter { space.matches($0, status: "open", track: "all", query: "") }.count, 1)
        XCTAssertTrue(reopened.tasks.filter(TaskSpace.work.contains).isEmpty)
        XCTAssertTrue(reopened.tasks.filter(TaskSpace.personal.contains).isEmpty)
        reopened.edit(taskID, "taskSpace", "work")
        saved = await reopened.flush(); XCTAssertTrue(saved)
        let deleted = await reopened.deleteEmptyTaskPage(id); XCTAssertTrue(deleted)
        XCTAssertEqual(reopened.task(taskID)?.text("note"), "自动保存内容")
    }
    @MainActor private func createTask(_ store: OOSStore, space: TaskSpace) async throws -> String {
        let created = await store.createTask(title: "学习任务", space: space)
        return try XCTUnwrap(created)
    }
    func testViewPreferencesAndNavigationAreIndependentPerPage() throws {
        let suite = "HeroOOS.pages.test.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = try XCTUnwrap(TaskSpace(rawValue: first)), b = try XCTUnwrap(TaskSpace(rawValue: second))
        XCTAssertEqual(TaskViewPreferences.mode(for: a, defaults: defaults), .board)
        defaults.set(TaskViewMode.list.rawValue, forKey: TaskViewPreferences.key(for: a))
        XCTAssertEqual(TaskViewPreferences.mode(for: a, defaults: defaults), .list)
        XCTAssertEqual(TaskViewPreferences.mode(for: b, defaults: defaults), .board)
        XCTAssertEqual(TaskViewPreferences.mode(for: .work, defaults: defaults), .board)
        XCTAssertEqual(Page.tasks(in: a).taskSpace, a)
        XCTAssertNotEqual(Page.tasks(in: a), Page.tasks(in: b))
    }
}
