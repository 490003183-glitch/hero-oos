import XCTest
@testable import HeroOOSNative

final class TaskSpaceTests: XCTestCase {
    func testExistingTasksStayInWorkRegardlessOfTrack() {
        let task = Record(["id": "old", "trackId": "track-personal", "status": "ready"])
        XCTAssertEqual(task.taskSpace, .work)
        XCTAssertTrue(TaskSpace.work.contains(task))
        XCTAssertFalse(TaskSpace.personal.contains(task))
        XCTAssertEqual(task["taskSpace"], .null)
    }
    func testAllFiltersAndSearchRemainPartitioned() {
        for status in TaskStatus.allCases {
            let task = Record(["taskSpace": "personal", "status": .string(status.rawValue), "title": "同名项目", "contact": "联系人", "trackId": "one"])
            XCTAssertTrue(TaskSpace.personal.matches(task, status: "all", track: "all", query: "联系人"))
            XCTAssertTrue(TaskSpace.personal.matches(task, status: status.rawValue, track: "one", query: "同名"))
            XCTAssertEqual(TaskSpace.personal.matches(task, status: "open", track: "all", query: ""), task.isOpen)
            XCTAssertFalse(TaskSpace.work.matches(task, status: "all", track: "all", query: ""))
            XCTAssertFalse(TaskSpace.personal.matches(task, status: "all", track: "two", query: ""))
        }
    }
    func testPrivateTasksNeverAppearInStudioLedger() {
        let task = Record(["taskSpace": "personal", "ledgerEnabled": true, "ledgerID": "项目-旧"])
        XCTAssertFalse(StudioLedger.contains(task))
    }
    func testOnlyDependenciesCanCrossSpaces() {
        let tasks = [Record(["id": "work"]), Record(["id": "private", "taskSpace": "personal"])]
        XCTAssertFalse(Relations.canParent("work", under: "private", tasks: tasks))
        XCTAssertTrue(Relations.canDepend("private", on: "work", tasks: tasks))
        XCTAssertTrue(Relations.canParent("private", under: "", tasks: tasks))
    }
}

final class TaskSpaceIntegrationTests: SwiftIntegrationCase {
    func testCLICreationDefaultsAndChildInheritance() throws {
        _ = try mutate([
            ["type": "task.create", "task": ["id": "work", "title": "工作"]],
            ["type": "task.create", "task": ["id": "private", "title": "私人", "taskSpace": "personal", "future": ["keep": true]]],
            ["type": "task.create", "task": ["id": "child", "title": "子任务", "parentId": "private"]]
        ])
        let records = try runtime.readState()["tasks"].records
        XCTAssertEqual(records.map(\.taskSpace), [.work, .personal, .personal])
        XCTAssertEqual(records[1]["future"], ["keep": true])
        XCTAssertFalse(Relations.canMove("private", to: .work, tasks: records))
    }
    func testCrossSpaceRelationsAndMovesFailWithoutWriting() throws {
        _ = try mutate([
            ["type": "task.create", "task": ["id": "work", "title": "工作"]],
            ["type": "task.create", "task": ["id": "private", "title": "私人", "taskSpace": "personal"]],
            ["type": "task.create", "task": ["id": "child", "title": "子任务", "parentId": "private"]]
        ])
        let before = try runtime.readState()
        for changes: JSON in [["parentId": "work"], ["taskSpace": "work"]] {
            XCTAssertThrowsError(try mutate([["type": "task.update", "id": "private", "changes": changes]]))
            XCTAssertEqual(try runtime.readState(), before)
        }
        XCTAssertThrowsError(try mutate([["type": "task.create", "task": ["title": "非法分区", "taskSpace": "unknown"]]]))
    }
    @MainActor func testPersonalAutosaveChildCreationCompletionAndRecovery() async throws {
        let store = OOSStore(api: api, recoverDrafts: false); await store.refresh()
        let created = await store.createTask(title: "私人测试", space: .personal)
        let id = try XCTUnwrap(created)
        let childCreated = await store.createTask(title: "私人子任务", parent: id)
        let childID = try XCTUnwrap(childCreated)
        XCTAssertEqual(store.task(childID)?.taskSpace, .personal)
        store.edit(childID, "note", "编辑自动保存")
        store.edit(childID, "status", "active")
        store.edit(childID, "priority", 8)
        try await Task.sleep(for: .seconds(1.2))
        let reopened = OOSStore(api: api, recoverDrafts: false); await reopened.refresh()
        XCTAssertEqual(reopened.task(childID)?.text("note"), "编辑自动保存")
        XCTAssertEqual(reopened.task(childID)?.status, "active")
        XCTAssertEqual(reopened.task(childID)?.number("priority"), 8)
        reopened.edit(id, "status", "completed")
        XCTAssertEqual(reopened.task(id)?.status, "ready")
        reopened.edit(childID, "status", "completed")
        var saved = await reopened.flush(); XCTAssertTrue(saved)
        reopened.edit(id, "status", "completed")
        saved = await reopened.flush(); XCTAssertTrue(saved)
        reopened.edit(id, "status", "ready")
        saved = await reopened.flush(); XCTAssertTrue(saved)
        XCTAssertEqual(reopened.task(id)?.taskSpace, .personal)
        XCTAssertTrue(reopened.tasks.filter(TaskSpace.work.contains).isEmpty)
    }
    @MainActor func testMovingAnUnlinkedTaskPreservesDetailsAndOriginalLedgerFields() async throws {
        let store = OOSStore(api: api, recoverDrafts: false); await store.refresh()
        let created = await store.createTask(title: "可移动", fields: ["ledgerEnabled": true, "amountTaxInclusive": 2500, "note": "原文"])
        let id = try XCTUnwrap(created)
        store.edit(id, "taskSpace", "personal")
        var saved = await store.flush(); XCTAssertTrue(saved)
        let privateTask = try XCTUnwrap(store.task(id))
        XCTAssertFalse(StudioLedger.contains(privateTask))
        XCTAssertEqual(privateTask.number("amountTaxInclusive"), 2500)
        XCTAssertEqual(privateTask.text("note"), "原文")
        store.edit(id, "taskSpace", "work")
        saved = await store.flush(); XCTAssertTrue(saved)
        XCTAssertTrue(StudioLedger.contains(try XCTUnwrap(store.task(id))))
    }
}
