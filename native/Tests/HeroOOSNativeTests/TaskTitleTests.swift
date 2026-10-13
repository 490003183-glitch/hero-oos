import XCTest
@testable import OOSCore
@testable import HeroOOSNative

final class TaskTitleTests: SwiftIntegrationCase {
    func testDraftTrimsTitleButRejectsEmptyUnchangedAndCancelledInput() {
        var draft = TaskTitleDraft("原任务")
        XCTAssertNil(draft.change())
        draft.text = "  \n "
        XCTAssertNil(draft.change())
        draft.text = "  新任务  "
        XCTAssertEqual(draft.change(), "新任务")
        XCTAssertNil(draft.change(cancelled: true))
    }
    @MainActor func testRenameAutosavesInBothSpacesWithoutChangingOtherFields() async throws {
        _ = try mutate([
            ["type": "task.create", "task": ["id": "work-title", "title": "工作原名", "priority": 8, "note": "保留备注"]],
            ["type": "task.create", "task": ["id": "private-title", "title": "私人原名", "taskSpace": "personal", "status": "waiting"]]
        ])
        let store = OOSStore(api: api, recoverDrafts: false); await store.refresh()
        for id in ["work-title", "private-title"] {
            let before = try XCTUnwrap(store.task(id))
            var draft = TaskTitleDraft(before.title); draft.text = before.title + "已改"
            store.edit(id, "title", .string(try XCTUnwrap(draft.change())))
        }
        try await Task.sleep(for: .seconds(1.2))
        XCTAssertTrue(store.pending.isEmpty)
        let reopened = OOSStore(api: api, recoverDrafts: false); await reopened.refresh()
        XCTAssertEqual(reopened.task("work-title")?.title, "工作原名已改")
        XCTAssertEqual(reopened.task("work-title")?.number("priority"), 8)
        XCTAssertEqual(reopened.task("work-title")?.text("note"), "保留备注")
        XCTAssertEqual(reopened.task("private-title")?.title, "私人原名已改")
        XCTAssertEqual(reopened.task("private-title")?.taskSpace, .personal)
        XCTAssertEqual(reopened.task("private-title")?.status, "waiting")
    }
}
