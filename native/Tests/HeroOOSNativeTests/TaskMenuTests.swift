import XCTest
@testable import OOSCore
@testable import HeroOOSNative

final class TaskMenuTests: SwiftIntegrationCase {
    @MainActor func testDropHitAreaClipsOversizedVisibleRectAndHiddenPortions() {
        let bounds = CGRect(x: 0, y: 0, width: 264, height: 50)
        let oversized = CGRect(x: -8, y: -58, width: 280, height: 203)
        XCTAssertTrue(TaskDropView.containsDropPoint(CGPoint(x: 44, y: 7), bounds: bounds, visibleRect: oversized))
        XCTAssertFalse(TaskDropView.containsDropPoint(CGPoint(x: 44, y: -51), bounds: bounds, visibleRect: oversized))
        XCTAssertFalse(TaskDropView.containsDropPoint(CGPoint(x: -4, y: 7), bounds: bounds, visibleRect: oversized))
        let clipped = CGRect(x: 0, y: 20, width: 264, height: 30)
        XCTAssertFalse(TaskDropView.containsDropPoint(CGPoint(x: 44, y: 7), bounds: bounds, visibleRect: clipped))
        XCTAssertTrue(TaskDropView.containsDropPoint(CGPoint(x: 44, y: 27), bounds: bounds, visibleRect: clipped))
    }
    private func seed() throws {
        _ = try mutate([
            ["type": "task.create", "task": ["id": "a", "title": "A", "priority": 8]],
            ["type": "task.create", "task": ["id": "b", "title": "B"]],
            ["type": "task.create", "task": ["id": "c", "title": "C"]],
            ["type": "task.create", "task": ["id": "waiting", "title": "等待", "status": "waiting"]],
            ["type": "task.create", "task": ["id": "private", "title": "私人", "taskSpace": "personal"]],
            ["type": "task.create", "task": ["id": "child", "title": "子任务", "parentId": "a"]]
        ])
    }
    private func move(_ id: String, _ placement: String, anchor: String? = nil, mode: String = "board", status: String? = nil) throws -> JSON {
        var op: JSON = ["type": "task.reorder", "id": .string(id), "mode": .string(mode), "placement": .string(placement), "seedIds": ["a", "b", "c", "child", "waiting", "private"]]
        if let anchor { op["anchorId"] = .string(anchor) }
        if let status { op["status"] = .string(status) }
        return try mutate([op])
    }
    private func ordered(_ mode: String, status: String = "ready") throws -> [String] {
        TaskOrdering.sorted(try runtime.readState()["tasks"].records.filter {
            $0.taskSpace == .work && (mode == "board" ? $0.status == status : $0.text("parentId").isEmpty)
        }, mode: mode).map(\.id)
    }
    func testBoardReorderPersistsAndUndoPreservesPriorities() throws {
        try seed()
        _ = try move("c", "first")
        XCTAssertEqual(try ordered("board"), ["c", "a", "b", "child"])
        _ = try move("a", "last")
        XCTAssertEqual(try ordered("board"), ["c", "b", "child", "a"])
        _ = try move("b", "after", anchor: "a")
        XCTAssertEqual(try ordered("board"), ["c", "child", "a", "b"])
        let state = try runtime.readState()
        XCTAssertEqual(state["tasks"].records.first { $0.id == "a" }?.number("priority"), 8)
        let receipt = try XCTUnwrap(state["receipts"].array.last)
        _ = try mutate([["type": "receipt.undo", "receiptId": receipt["id"]]], confirmed: true)
        XCTAssertEqual(try ordered("board"), ["c", "b", "child", "a"])
        XCTAssertEqual(try StateRuntime(root: root).readState()["tasks"], try runtime.readState()["tasks"])
    }
    func testCrossColumnMoveIsAtomicAndListOrderIsIndependent() throws {
        try seed()
        _ = try move("b", "before", anchor: "waiting", status: "waiting")
        XCTAssertEqual(try ordered("board", status: "waiting"), ["b", "waiting"])
        _ = try move("c", "first", mode: "list")
        XCTAssertEqual(try ordered("list").first, "c")
        XCTAssertEqual(try ordered("board", status: "waiting"), ["b", "waiting"])
        XCTAssertEqual(try runtime.readState()["tasks"].records.first { $0.id == "private" }?["boardOrder"], .null)
    }
    func testReorderRejectsCrossSpaceAndHierarchyAndParentCompletion() throws {
        try seed()
        let before = try runtime.readState()
        XCTAssertThrowsError(try move("a", "before", anchor: "private"))
        XCTAssertThrowsError(try move("child", "before", anchor: "b", mode: "list"))
        XCTAssertThrowsError(try move("a", "first", status: "completed"))
        XCTAssertEqual(try runtime.readState(), before)
    }
    func testArchiveIsNotCompletionAndIsReversible() throws {
        try seed()
        _ = try mutate([["type": "task.update", "id": "b", "changes": ["archived": true]]])
        let archived = try XCTUnwrap(runtime.readState()["tasks"].records.first { $0.id == "b" })
        XCTAssertTrue(archived.isArchived); XCTAssertFalse(archived.isOpen); XCTAssertFalse(archived.isExecutionTracked)
        XCTAssertFalse(archived.isClosed); XCTAssertEqual(archived.status, "ready")
        XCTAssertFalse(TaskSpace.work.matches(archived, status: "all", track: "all", query: ""))
        _ = try mutate([["type": "task.update", "id": "b", "changes": ["archived": false]]])
        XCTAssertTrue(try XCTUnwrap(runtime.readState()["tasks"].records.first { $0.id == "b" }).isOpen)
    }
    func testDeleteHasRecoveryReceiptAndCannotOrphanChildren() throws {
        try seed()
        XCTAssertThrowsError(try mutate([["type": "task.delete", "id": "a"]], confirmed: true))
        _ = try mutate([["type": "task.delete", "id": "c"]], confirmed: true)
        let deleted = try runtime.readState()
        XCTAssertFalse(deleted["tasks"].records.contains { $0.id == "c" })
        let receipt = try XCTUnwrap(deleted["receipts"].array.last)
        _ = try mutate([["type": "receipt.undo", "receiptId": receipt["id"]]], confirmed: true)
        XCTAssertTrue(try runtime.readState()["tasks"].records.contains { $0.id == "c" })
    }
    @MainActor func testStoreMenuActionsAndOrderingRoundTrip() async throws {
        try seed()
        let store = OOSStore(api: api, recoverDrafts: false); await store.refresh()
        let moved = await store.moveTask("c", mode: .board, placement: "first")
        XCTAssertTrue(moved)
        XCTAssertEqual(store.displayOrdered(store.tasks.filter { $0.status == "ready" && $0.taskSpace == .work }, mode: .board).first?.id, "c")
        store.edit("c", "archived", true)
        let saved = await store.flush(); XCTAssertTrue(saved)
        XCTAssertTrue(store.task("c")?.isArchived == true)
        let completed = await store.perform([["type": "task.complete", "id": "b"]]); XCTAssertTrue(completed)
        XCTAssertEqual(store.task("b")?.status, "completed")
    }
}
