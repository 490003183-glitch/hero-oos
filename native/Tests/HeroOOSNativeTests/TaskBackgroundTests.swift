import XCTest
import SwiftUI
import AppKit
@testable import OOSCore
@testable import HeroOOSNative

final class TaskBackgroundTests: SwiftIntegrationCase {
    func testUnicodeLimitAndClippingDoNotSplitVisibleCharacters() throws {
        let boundary = String(repeating: "中", count: 2000)
        XCTAssertNoThrow(try TaskBackground.validate(.string(boundary)))
        XCTAssertThrowsError(try TaskBackground.validate(.string(boundary + "文")))
        XCTAssertEqual(TaskBackground.clipped(boundary + "多余"), boundary)
        XCTAssertEqual(TaskBackground.count("😀"), 1)
        XCTAssertEqual(TaskBackground.count("e\u{301}"), 2)
        XCTAssertEqual(TaskBackground.clipped(String(repeating: "中", count: 1999) + "👨‍👩‍👧‍👦"), String(repeating: "中", count: 1999))
        XCTAssertEqual(TaskBackground.clipped("中", limit: 0), "")
        for value: JSON in [42, true, [], [:]] { XCTAssertThrowsError(try TaskBackground.validate(value)) }
        XCTAssertNoThrow(try TaskBackground.validate(.null))
        XCTAssertNoThrow(try TaskBackground.validate(""))
    }
    func testRuntimeRejectsOversizedCreateAndUpdateAtomically() throws {
        _ = try mutate([["type": "task.create", "task": ["id": "work", "title": "任务", "note": "旧备注"]]])
        let before = try runtime.readState()
        let tooLong = JSON.string(String(repeating: "中", count: 2001))
        XCTAssertThrowsError(try mutate([["type": "task.update", "id": "work", "changes": ["background": tooLong, "title": "不能写入"]]]))
        XCTAssertThrowsError(try mutate([["type": "task.create", "task": ["title": "不能创建", "background": tooLong]]]))
        XCTAssertEqual(try runtime.readState(), before)
        _ = try mutate([["type": "task.update", "id": "work", "changes": ["background": "起因\n目标\n必要背景"]]])
        XCTAssertEqual(try runtime.readState()["tasks"].array[0]["note"], "旧备注")
        _ = try mutate([["type": "task.update", "id": "work", "changes": ["background": nil]]])
        XCTAssertEqual(try runtime.readState()["tasks"].array[0]["background"], .null)
    }
    func testBothCloudScopesPersistClearAndIsolateBackground() throws {
        _ = try mutate([
            ["type": "task.create", "task": ["id": "work", "title": "共享", "background": "组织背景"]],
            ["type": "task.create", "task": ["id": "private", "title": "私人", "taskSpace": "personal", "background": "私人背景"]]
        ])
        let org = try runtime.organizationState(), personal = try runtime.personalTaskState()
        XCTAssertEqual(org["tasks"].array[0]["background"], "组织背景")
        XCTAssertEqual(personal["tasks"].array[0]["background"], "私人背景")
        XCTAssertEqual(org["tasks"].array.count, 1)
        try runtime.validateOrganizationState(org); try runtime.validatePersonalTaskState(personal)
        var incoming = org
        incoming["tasks"] = [["id": "work", "title": "共享", "taskSpace": "work", "background": "异地新背景"]]
        _ = try runtime.applyOrganizationState(incoming, expected: org)
        XCTAssertEqual(try runtime.personalTaskState(), personal)
        XCTAssertEqual(try runtime.organizationState()["tasks"].array[0]["background"], "异地新背景")
        var cleared = personal
        cleared["tasks"] = [["id": "private", "title": "私人", "taskSpace": "personal", "background": ""]]
        _ = try runtime.applyPersonalTaskState(cleared, expected: personal)
        XCTAssertEqual(try runtime.personalTaskState()["tasks"].array[0]["background"], "")
        var invalid = incoming
        invalid["tasks"] = [["id": "work", "title": "共享", "taskSpace": "work", "background": .string(String(repeating: "😀", count: 2001))]]
        XCTAssertThrowsError(try runtime.validateOrganizationState(invalid))
    }
    @MainActor func testAutosaveAndReopenKeepBackgroundSeparateFromNotes() async throws {
        _ = try mutate([["type": "task.create", "task": ["id": "work", "title": "任务", "note": "保留备注", "details": ["保留来源"]]]])
        let store = OOSStore(api: api, recoverDrafts: false); await store.refresh()
        XCTAssertEqual(store.task("work")?.text("background"), "")
        store.edit("work", "background", "任务起因\n任务目标")
        let saved = await store.flush()
        XCTAssertTrue(saved)
        let reopened = OOSStore(api: api, recoverDrafts: false); await reopened.refresh()
        XCTAssertEqual(reopened.task("work")?.text("background"), "任务起因\n任务目标")
        XCTAssertEqual(reopened.task("work")?.text("note"), "保留备注")
        XCTAssertEqual(reopened.task("work")?["details"], ["保留来源"])
    }
    @MainActor func testEditorRespectsCompositionAndOverLimitInputPreservesExistingText() {
        var saved = "原背景", hitLimit = false
        let editorView = BackgroundTextEditor(text: Binding(get: { saved }, set: { saved = $0 }),
                                              reachedLimit: Binding(get: { hitLimit }, set: { hitLimit = $0 }))
        let coordinator = BackgroundTextEditor.Coordinator(editorView)
        let editor = BackgroundTextView()
        editor.delegate = coordinator; editor.string = saved
        editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: NSRange(location: 3, length: 0))
        coordinator.publish(editor)
        XCTAssertEqual(saved, "原背景")
        editor.unmarkText(); editor.string = "原背景中"
        coordinator.publish(editor)
        XCTAssertEqual(saved, "原背景中")
        editor.string = String(repeating: "多", count: 2001)
        coordinator.publish(editor)
        XCTAssertTrue(hitLimit)
        XCTAssertEqual(saved, "原背景中")
        XCTAssertEqual(editor.string, saved)
        saved = String(repeating: "中", count: 1998) + "尾"; editor.string = saved
        XCTAssertFalse(coordinator.textView(editor, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementString: "甲乙丙"))
        XCTAssertEqual(editor.string, "甲" + String(repeating: "中", count: 1998) + "尾")
        XCTAssertEqual(saved, editor.string)
        XCTAssertTrue(hitLimit)
    }
}
