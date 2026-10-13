import XCTest
import AppKit
@testable import HeroOOSNative

private func taskState(_ tasks: [Record], version: Int = 1) -> JSON {
    .object(["meta": .object(["version": .number(Double(version))]), "tasks": .array(tasks.map(\.json))])
}

private func canvasDocument(_ text: String = "原文") -> JSON {
    .object(["activeCanvasId": .string("one"), "canvases": .array([
        .object(["id": .string("one"), "name": .string("画布一"), "items": .array([
            .object(["id": .string("text"), "kind": .string("text"), "text": .string(text), "x": .number(0), "width": .number(300), "height": .number(100), "locked": .bool(false)])])]),
        .object(["id": .string("two"), "name": .string("画布二"), "items": .array([])])])])
}

private actor TestServer {
    var state = taskState([Record(["id": .string("a"), "title": .string("任务"), "status": .string("ready")])])
    var collages = canvasDocument()
    var stateDelay = 0
    var collageDelay = 0
    var assetDelay = 0
    var receivedAssetPath = ""
    func setDelay(state: Int = 0, collage: Int = 0, asset: Int = 0) { stateDelay = state; collageDelay = collage; assetDelay = asset }
    func setCollages(_ value: JSON) { collages = value }
    func request(_ path: String, _ method: String, _ body: JSON?, _ data: Data?) async throws -> JSON {
        if path == "/api/state" {
            let snapshot = state
            try await Task.sleep(for: .milliseconds(stateDelay))
            return .object(["state": snapshot])
        }
        if path == "/api/collages" {
            if method == "PUT" {
                guard body?["expectedCollages"] == collages else { throw APIError(code: "collage_conflict", payload: .null) }
                collages = body?["collages"] ?? .null
            }
            let snapshot = collages
            try await Task.sleep(for: .milliseconds(collageDelay))
            return .object(["collages": snapshot])
        }
        if path.hasPrefix("/api/collage-assets?") {
            receivedAssetPath = path
            try await Task.sleep(for: .milliseconds(assetDelay))
            return .object(["asset": .object(["assetFile": .string("test.png"), "originalName": .string("测试&图.png")])])
        }
        throw NativeError.message("Unexpected test request: \(path)")
    }
    nonisolated var api: OOSAPI { OOSAPI(base: URL(string: "http://qa.invalid/\(UUID().uuidString)")!, transport: { path, method, body, data in try await self.request(path, method, body, data) }) }
}

final class ExperienceTests: XCTestCase {
    @MainActor func testReopeningCleanCacheDoesNotCreatePhantomMutation() async throws {
        let server = TestServer(); let api = server.api
        let store = OOSStore(api: api); await store.refresh()
        let reopened = OOSStore(api: api)
        XCTAssertFalse(reopened.hasUnsavedChanges)
        await reopened.refresh()
        XCTAssertNil(reopened.error)
        XCTAssertFalse(reopened.hasUnsavedChanges)
        XCTAssertEqual(reopened.saveMessage, "已保存 · v1")
        UserDefaults.standard.removeObject(forKey: "HeroOOS.taskDrafts.\(api.draftIdentity)")
    }
    @MainActor func testRenderingExistingValueDoesNotCreateMutation() {
        let store = OOSStore(recoverDrafts: false)
        store.state = taskState([Record(["id": .string("a"), "effortHours": .number(2.5)])])
        store.edit("a", "effortHours", .number(2.5)); XCTAssertTrue(store.pending.isEmpty)
        store.edit("a", "effortHours", .number(3)); XCTAssertFalse(store.pending.isEmpty)
        store.edit("a", "effortHours", .number(2.5)); XCTAssertTrue(store.pending.isEmpty)
    }
    @MainActor func testHistoricalUndoCannotOverwriteLaterEdit() {
        let store = OOSStore(recoverDrafts: false)
        let affected: JSON = .array([.object(["entity": .string("task"), "id": .string("a")])])
        let old = Record(["id": .string("old"), "version": .number(2), "affected": affected])
        let latest = Record(["id": .string("new"), "version": .number(3), "affected": affected])
        store.state = .object(["receipts": .array([old.json, latest.json])])
        XCTAssertEqual(store.undoBlock(old), "后续已有修改")
        XCTAssertNil(store.undoBlock(latest))
    }
    @MainActor func testSlowRefreshNeverRevertsNewerState() async throws {
        let server = TestServer(); let store = OOSStore(api: server.api, recoverDrafts: false)
        await server.setDelay(state: 150)
        let refresh = Task { await store.refresh() }
        try await Task.sleep(for: .milliseconds(30))
        store.acceptState(taskState([Record(["id": .string("a"), "title": .string("新版本")])], version: 4))
        await refresh.value
        XCTAssertEqual(store.version, 4); XCTAssertEqual(store.task("a")?.title, "新版本")
    }

    func testUnlimitedHierarchyAndBothCycleChecks() {
        var tasks = [Record(["id": .string("root")])]
        for i in 1...20 { tasks.append(Record(["id": .string("level-\(i)"), "parentId": .string(i == 1 ? "root" : "level-\(i - 1)")])) }
        XCTAssertFalse(Relations.canParent("root", under: "level-20", tasks: tasks))
        tasks.append(Record(["id": "new"]))
        XCTAssertTrue(Relations.canParent("new", under: "level-20", tasks: tasks))
        tasks[0]["dependsOn"] = .array([.string("level-20")])
        XCTAssertFalse(Relations.canDepend("level-20", on: "root", tasks: tasks))
        XCTAssertFalse(Relations.canDepend("level-1", on: "root", tasks: tasks))
    }

    @MainActor func testInvalidRelationshipAndParentClosureDoNotPoisonDrafts() {
        let store = OOSStore(recoverDrafts: false)
        store.state = taskState([Record(["id": .string("p"), "title": .string("父任务"), "status": .string("ready")]), Record(["id": .string("c"), "parentId": .string("p"), "status": .string("ready")])])
        store.edit("p", "parentId", .string("c")); XCTAssertTrue(store.pending.isEmpty)
        store.edit("p", "status", .string("completed")); XCTAssertTrue(store.pending.isEmpty)
        store.edit("p", "status", .string("cancelled")); XCTAssertTrue(store.pending.isEmpty)
        store.edit("c", "title", .string("正常编辑")); XCTAssertEqual(store.task("c")?.title, "正常编辑")
        store.discardDraft("c"); XCTAssertTrue(store.pending.isEmpty)
    }

    @MainActor func testDeferCapsWeightAndKeepsBase() {
        let store = OOSStore(recoverDrafts: false)
        store.state = taskState([Record(["id": .string("a"), "priority": .number(9), "priorityBase": .number(5), "deferCount": .number(4), "due": .string("2026-09-24")])])
        store.deferTask("a", days: 1); store.deferTask("a", days: 2)
        XCTAssertEqual(store.task("a")?.number("priority"), 10)
        XCTAssertEqual(store.task("a")?.number("priorityBase"), 5)
        XCTAssertEqual(store.task("a")?.number("deferCount"), 6)
        XCTAssertEqual(store.task("a")?.text("due"), "2026-09-27")
        store.discardDraft("a")
    }

    @MainActor func testOfflineRestartRetainsTaskAndDraft() async throws {
        let server = TestServer(); let api = server.api
        let store = OOSStore(api: api); await store.refresh(); store.edit("a", "title", .string("离线输入"))
        let reopened = OOSStore(api: api)
        XCTAssertEqual(reopened.task("a")?.title, "离线输入")
        XCTAssertFalse(reopened.connected)
        store.discardDraft("a"); reopened.discardDraft("a")
        UserDefaults.standard.removeObject(forKey: "HeroOOS.taskDrafts.\(api.base.absoluteString)")
    }

    @MainActor func testSlowCollageLoadDoesNotEraseTyping() async throws {
        let server = TestServer(); let model = CollageStore(api: server.api, recoverDrafts: false)
        await model.load(); await server.setDelay(collage: 150)
        let refresh = Task { await model.load() }
        try await Task.sleep(for: .milliseconds(30))
        model.selection = ["text"]; model.updateSelected("text", .string("刷新中继续输入"))
        await refresh.value
        XCTAssertEqual(model.items.first?.text("text"), "刷新中继续输入")
        XCTAssertTrue(model.dirty)
        await server.setDelay(); let saved = await model.save(); XCTAssertTrue(saved)
    }

    @MainActor func testInsertTextCreatesSelectedEditableItem() async throws {
        let server = TestServer(); let model = CollageStore(api: server.api, recoverDrafts: false)
        await model.load()
        let before = model.items.count
        model.insertText("画布标题")
        let item = try XCTUnwrap(model.selectedItems.first)
        XCTAssertEqual(model.items.count, before + 1)
        XCTAssertEqual(item.text("kind"), "text")
        XCTAssertEqual(item.text("text"), "画布标题")
        XCTAssertEqual(item.text("fontFamily"), "PingFang SC")
        XCTAssertGreaterThanOrEqual(item.number("fontSize"), 72)
        XCTAssertGreaterThanOrEqual(item.number("width"), 720)
        XCTAssertGreaterThanOrEqual(item.number("height"), 200)
        let saved = await model.save()
        XCTAssertTrue(saved)
    }

    @MainActor func testInsertedTextRemainsVisibleWhenCanvasIsZoomedOut() async throws {
        let server = TestServer(); let model = CollageStore(api: server.api, recoverDrafts: false)
        await model.load()
        let surface = CollageSurface(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        surface.model = model; model.surface = surface
        surface.zoomTo(0.07)
        model.insertText("缩小画布也可见")
        let item = try XCTUnwrap(model.selectedItems.first)
        XCTAssertEqual(item.number("width") * surface.displayScale, 420, accuracy: 0.1)
        XCTAssertEqual(item.number("height") * surface.displayScale, 150, accuracy: 0.1)
        XCTAssertGreaterThanOrEqual(item.number("fontSize") * surface.displayScale, 34)
        _ = await model.save()
    }

    @MainActor func testUndoPreservesExternalCanvasEdits() async throws {
        let server = TestServer(); let model = CollageStore(api: server.api, recoverDrafts: false)
        await model.load(); model.selection = ["text"]; model.updateSelected("x", .number(80))
        var remote = canvasDocument(); var list = remote["canvases"].array; list[1]["name"] = .string("另一端改名"); remote["canvases"] = .array(list)
        await server.setCollages(remote)
        let saved = await model.save(); XCTAssertTrue(saved)
        model.undo()
        XCTAssertEqual(model.items.first?.number("x"), 0)
        XCTAssertEqual(model.canvases.last?.text("name"), "另一端改名")
        let undoSaved = await model.save(); XCTAssertTrue(undoSaved)
    }

    @MainActor func testImageImportStaysOnOriginalCanvasAndEncodesFilename() async throws {
        let server = TestServer(); let model = CollageStore(api: server.api, recoverDrafts: false)
        await model.load(); await server.setDelay(asset: 150)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("测试&图.png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try rep.representation(using: .png, properties: [:])!.write(to: file)
        let importing = Task { await model.addImages([file]) }
        try await Task.sleep(for: .milliseconds(30)); model.switchCanvas("two")
        await importing.value
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.canvases.first?["items"].array.count, 2)
        let path = await server.receivedAssetPath
        XCTAssertEqual(URLComponents(string: path)?.queryItems?.first?.value, "测试&图.png")
        let saved = await model.save(); XCTAssertTrue(saved)
    }

    @MainActor func testLockedItemCannotMoveResizeOrReorder() async {
        let server = TestServer(); let model = CollageStore(api: server.api, recoverDrafts: false)
        await model.load(); model.selection = ["text"]; model.updateSelected("locked", .bool(true))
        let locked = model.items.first
        model.updateSelected("x", .number(200)); model.updateSelected("width", .number(500)); model.updateSelected("z", .number(-1)); model.deleteSelection()
        XCTAssertEqual(model.items.first, locked)
        _ = await model.save()
    }

    @MainActor func testCollageConflictCanKeepBothVersions() async {
        let server = TestServer(); let model = CollageStore(api: server.api, recoverDrafts: false)
        await model.load(); model.selection = ["text"]; model.updateSelected("text", .string("本地版"))
        await server.setCollages(canvasDocument("外部版"))
        let saved = await model.save(); XCTAssertFalse(saved); XCTAssertTrue(model.hasConflict)
        await model.keepLocalCopies()
        XCTAssertFalse(model.dirty)
        XCTAssertEqual(model.canvases.count, 3)
        XCTAssertEqual(model.canvases.first?["items"].records.first?.text("text"), "外部版")
        XCTAssertEqual(model.items.first?.text("text"), "本地版")
    }
}

final class ExperienceIntegrationTests: SwiftIntegrationCase {
    @MainActor func testLostCommittedResponseDoesNotDuplicateTask() async throws {
        let store = OOSStore(api: proxy, recoverDrafts: false); await store.refresh()
        let title = "回执丢失-\(UUID().uuidString)"
        _ = try await proxy.request("/__qa/control", method: "POST", body: .object(["loseResponse": .bool(true)]))
        _ = await store.createTask(title: title)
        let recovered = await store.flush(); XCTAssertTrue(recovered)
        let state = try await direct.request("/api/state")["state"]
        XCTAssertEqual(state["tasks"].records.filter { $0.title == title }.count, 1)
    }
    @MainActor func testServerUnavailableKeepsEditsThenSavesAfterReconnect() async throws {
        let store = OOSStore(api: proxy, recoverDrafts: false); await store.refresh()
        let created = await store.createTask(title: "断线恢复测试")
        let id = try XCTUnwrap(created)
        _ = try await proxy.request("/__qa/control", method: "POST", body: .object(["offline": .bool(true)]))
        store.edit(id, "note", .string("断线时的备注")); let offlineSave = await store.flush(); XCTAssertFalse(offlineSave)
        await store.refresh(); XCTAssertFalse(store.connected)
        XCTAssertEqual(store.task(id)?.text("note"), "断线时的备注")
        _ = try await proxy.request("/__qa/control", method: "POST", body: .object(["offline": .bool(false)]))
        await store.refresh(); XCTAssertTrue(store.pending.isEmpty)
        let task = try await direct.request("/api/state")["state"]["tasks"].records.first { $0.id == id }
        XCTAssertEqual(task?.text("note"), "断线时的备注")
    }
    @MainActor func testCreateRefreshesExternalVersion() async throws {
        let one = OOSStore(api: direct, recoverDrafts: false); let two = OOSStore(api: direct, recoverDrafts: false)
        await one.refresh(); await two.refresh()
        let first = await one.createTask(title: "另一端新增")
        let second = await two.createTask(title: "旧窗口继续新增")
        XCTAssertNotNil(first); XCTAssertNotNil(second)
    }
    @MainActor func testScheduleCreateMoveCompleteAndUndo() async throws {
        let store = OOSStore(api: direct, recoverDrafts: false); await store.refresh()
        let id = "schedule-\(UUID().uuidString)"
        let created = await store.perform([.object(["type": .string("schedule.create"), "block": .object(["id": .string(id), "title": .string("日程回归"), "start": .string("2026-09-25T10:00:00+08:00"), "end": .string("2026-09-25T11:00:00+08:00")])])])
        XCTAssertTrue(created)
        let moved = await store.perform([.object(["type": .string("schedule.move"), "id": .string(id), "start": .string("2026-09-25T12:00:00+08:00"), "end": .string("2026-09-25T13:00:00+08:00")])])
        XCTAssertTrue(moved)
        XCTAssertEqual(store.schedules.first { $0.id == id }?.text("start"), "2026-09-25T12:00:00+08:00")
        let completed = await store.perform([.object(["type": .string("schedule.complete"), "id": .string(id)])])
        XCTAssertTrue(completed)
        let receipt = try XCTUnwrap(store.state["receipts"].records.last)
        let undone = await store.perform([.object(["type": .string("receipt.undo"), "receiptId": .string(receipt.id)])])
        XCTAssertTrue(undone)
        XCTAssertEqual(store.schedules.first { $0.id == id }?.status, "scheduled")
    }
    @MainActor func testCaptureAndTrackCheckin() async {
        let store = OOSStore(api: direct, recoverDrafts: false); await store.refresh()
        let text = "快速记录回归-\(UUID().uuidString)"
        let captured = await store.perform([.object(["type": .string("capture.add"), "text": .string(text)])])
        XCTAssertTrue(captured)
        XCTAssertTrue(store.state["captures"].records.contains { $0.text("text") == text })
        let checked = await store.perform([.object(["type": .string("checkin.record"), "trackId": .string("track-personal"), "value": .bool(true), "date": .string(Dates.day())])])
        XCTAssertTrue(checked)
    }
}
