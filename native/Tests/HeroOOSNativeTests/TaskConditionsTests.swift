import XCTest
@testable import OOSCore
@testable import HeroOOSNative

final class TaskConditionsTests: SwiftIntegrationCase {
    private func person(_ id: String = "p1", resolved: Bool = false) -> JSON {
        ["id": .string(id), "person": "张三", "outcome": "确认报价", "resolved": .bool(resolved), "futureField": "保留"]
    }
    func testAllThreeConditionsAreConjunctiveAndTimeNeverOverridesPeople() throws {
        let now = try XCTUnwrap(RuntimeDate.parse("2026-10-13T12:00:00+08:00"))
        for peopleDone in [false, true] { for timeReached in [false, true] { for predecessorDone in [false, true] {
            let task = Record(["id": "a", "status": "waiting", "peopleWaits": .array([person(resolved: peopleDone)]),
                               "availableAt": .string(RuntimeDate.iso(now.addingTimeInterval(timeReached ? 0 : 1))), "dependsOn": ["b"]])
            let predecessor = Record(["id": "b", "title": "素材整理", "status": .string(predecessorDone ? "completed" : "ready")])
            let graph = TaskDependencies([task, predecessor])
            XCTAssertEqual(graph.conditions(task, at: now).count, 3)
            XCTAssertEqual(graph.pendingConditions(task, at: now).count, [peopleDone, timeReached, predecessorDone].filter { !$0 }.count)
            let ready = peopleDone && timeReached && predecessorDone
            XCTAssertEqual(graph.blocked(task, at: now) == nil, ready)
            XCTAssertEqual(graph.shouldSignalReady(task, at: now), ready)
            XCTAssertEqual(graph.readyToBegin(task, at: now), ready)
            if timeReached && !peopleDone { XCTAssertEqual(graph.timePhase(task, at: now), .waitingForPeople) }
        } } }
    }
    func testMultiplePeopleReblockingAndSignalStopStates() {
        var task = Record(["id": "a", "status": "ready", "peopleWaits": .array([person(), person("p2", resolved: true)])])
        let graph = TaskDependencies([task])
        XCTAssertEqual(graph.conditionCounts(task), "人 1")
        XCTAssertFalse(graph.shouldSignalReady(task))
        task["peopleWaits"] = .array([person(resolved: true), person("p2", resolved: true)])
        XCTAssertTrue(graph.shouldSignalReady(task))
        for status in ["active", "paused", "information", "completed", "cancelled"] {
            task["status"] = .string(status); XCTAssertFalse(graph.shouldSignalReady(task))
        }
        task["status"] = "ready"; task["archived"] = true; XCTAssertFalse(graph.shouldSignalReady(task))
        task["archived"] = false; task["peopleWaits"] = .array([person(), person("p2", resolved: true)])
        XCTAssertNotNil(graph.blocked(task)); XCTAssertFalse(graph.shouldSignalReady(task))
        task["peopleWaits"] = []
        XCTAssertTrue(graph.readyToBegin(task)); XCTAssertFalse(graph.shouldSignalReady(task)) // No gratuitous flashing.
    }
    func testRepairingMissingLegacyMirrorDoesNotFlattenStructuredPeople() throws {
        // Some clients supply an array but no legacy field. Repairing the mirror is not a list replacement.
        let current = Record(["peopleWaits": .array([person(), person("p2", resolved: true)])])
        let patch: JSON = ["blockedBy": .string(TaskPeopleWaits.summary(current))]
        let normalized = try TaskPeopleWaits.normalized(patch, current: current)
        XCTAssertNil(normalized.object["peopleWaits"])
        XCTAssertEqual(TaskPeopleWaits.entries(current).count, 2)
    }
    func testLegacyWaitingProseIsNotClaimedReadyWithoutExplicitConditions() {
        for status in ["waiting", "review", "blocked", "backlog"] {
            let task = Record(["id": "legacy", "status": .string(status), "waitingCondition": "等待对方支付"])
            let graph = TaskDependencies([task])
            XCTAssertFalse(graph.readyToBegin(task)); XCTAssertFalse(graph.shouldSignalReady(task))
        }
    }
    @MainActor func testConcurrentPeopleChangesAreNotSilentlyOverwritten() async throws {
        _ = try mutate([["type": "task.create", "task": ["id": "a", "title": "并发条件", "peopleWaits": .array([person()])]]])
        let store = OOSStore(api: api, recoverDrafts: false); await store.refresh()
        store.edit("a", "peopleWaits", .array([person(resolved: true)]))
        _ = try mutate([["type": "task.update", "id": "a", "changes": ["peopleWaits": .array([person(), person("new")])]]])
        let saved = await store.flush(); XCTAssertFalse(saved)
        XCTAssertEqual(try runtime.readState()["tasks"].records[0]["peopleWaits"].array.count, 2)
        XCTAssertNotNil(store.conflictTaskID)
    }
    func testLegacyReadDoesNotMigrateOrLoseFieldsAndResolutionUndoRestoresIt() throws {
        _ = try mutate([["type": "task.create", "task": ["id": "a", "title": "旧记录", "blockedBy": "李四提供素材", "unknown": ["keep": true]]]])
        let before = try runtime.readState(), old = before["tasks"].records[0]
        let entries = TaskPeopleWaits.entries(old)
        XCTAssertEqual(entries.count, 1); XCTAssertEqual(entries[0].text("person"), "李四提供素材")
        XCTAssertNotNil(TaskDependencies([old]).blocked(old)); XCTAssertEqual(try runtime.readState(), before)
        var resolved = entries[0]; resolved["resolved"] = true
        let result = try mutate([["type": "task.update", "id": "a", "changes": ["peopleWaits": .array([resolved.json])]]])
        let changed = result["state"]["tasks"].records[0]
        XCTAssertEqual(changed.text("blockedBy"), ""); XCTAssertEqual(changed["unknown"], old["unknown"])
        XCTAssertEqual(changed.status, "ready"); XCTAssertFalse(StudioLedger.contains(changed))
        _ = try mutate([["type": "receipt.undo", "receiptId": result["receipt"]["id"]]], confirmed: true)
        let restored = try runtime.readState()["tasks"].records[0]
        XCTAssertEqual(restored["peopleWaits"], .null); XCTAssertEqual(restored["blockedBy"], old["blockedBy"])
        XCTAssertNotNil(TaskDependencies([restored]).blocked(restored))
    }
    func testPeopleConditionsGateCreateUpdateReorderAndBatchAgainstFinalState() throws {
        _ = try mutate([["type": "task.create", "task": ["id": "a", "title": "待确认", "peopleWaits": .array([person()])]]])
        let before = try runtime.readState()
        let attempts: [JSON] = [
            ["type": "task.update", "id": "a", "changes": ["status": "active"]],
            ["type": "task.reorder", "id": "a", "mode": "board", "placement": "first", "status": "active"],
            ["type": "task.create", "task": ["title": "非法开始", "status": "active", "peopleWaits": .array([person()])]]
        ]
        for op in attempts { XCTAssertThrowsError(try mutate([op])) }
        XCTAssertEqual(try runtime.readState(), before)
        XCTAssertFalse(runtime.attention(before).contains { $0["id"] == "a" })
        _ = try mutate([["type": "task.update", "id": "a", "changes": ["status": "active"]],
                        ["type": "task.update", "id": "a", "changes": ["peopleWaits": .array([person(resolved: true)])]]])
        _ = try mutate([["type": "task.update", "id": "a", "changes": ["peopleWaits": .array([person()])]]])
        let active = try runtime.readState()["tasks"].records[0]
        XCTAssertEqual(active.status, "active"); XCTAssertNotNil(TaskDependencies([active]).blocked(active))
    }
    func testInvalidPeopleConditionsDoNotWriteAndLegacyClientsCanStillEdit() throws {
        _ = try mutate([["type": "task.create", "task": ["id": "a", "title": "待確認", "peopleWaits": .array([person()])]]])
        let before = try runtime.readState()
        for bad: JSON in [.null, "谁", .array([person(), person()]), [["id": "x", "person": "", "outcome": "", "resolved": false]], [["id": "x", "person": "甲", "outcome": "", "resolved": "false"]]] {
            XCTAssertThrowsError(try mutate([["type": "task.update", "id": "a", "changes": ["peopleWaits": bad]]]))
        }
        XCTAssertEqual(try runtime.readState(), before)
        _ = try mutate([["type": "task.update", "id": "a", "changes": ["blockedBy": "王五核对"]]])
        var task = try runtime.readState()["tasks"].records[0]
        XCTAssertEqual(TaskPeopleWaits.entries(task).count, 1); XCTAssertEqual(TaskPeopleWaits.summary(task), "王五核对")
        _ = try mutate([["type": "task.update", "id": "a", "changes": ["blockedBy": ""]]])
        task = try runtime.readState()["tasks"].records[0]
        XCTAssertTrue(TaskPeopleWaits.entries(task).isEmpty); XCTAssertNil(TaskDependencies([task]).blocked(task))
    }
    @MainActor func testStoreAutosavesAllSpacesWithLedgerMirrorAndNoStatusOrLayoutChanges() async throws {
        let page = "page-\(UUID().uuidString)"
        _ = try mutate([["type": "taskPage.create", "taskPage": ["id": .string(page), "title": "自定义"]]])
        for space in ["work", "personal", page] {
            _ = try mutate([["type": "task.create", "task": ["id": .string(space), "title": "测试条件", "taskSpace": .string(space), "status": "waiting"]]])
        }
        let store = OOSStore(api: api, recoverDrafts: false); await store.refresh()
        let graph = TaskGraphModel(); graph.reconcile(store.tasks); let layout = graph.layout
        for space in ["work", "personal", page] {
            store.edit(space, "peopleWaits", .array([person(), person("p2", resolved: true)]))
            XCTAssertEqual(store.task(space)?.text("blockedBy"), "张三 · 确认报价")
            store.edit(space, "status", "active"); XCTAssertEqual(store.task(space)?.status, "waiting")
        }
        _ = try mutate([["type": "task.update", "id": "work", "changes": ["note": "并发备注"]]])
        let saved = await store.flush(); XCTAssertTrue(saved)
        await store.refresh(); graph.reconcile(store.tasks); XCTAssertEqual(graph.layout, layout)
        XCTAssertEqual(store.task("work")?.text("note"), "并发备注")
        for task in store.tasks {
            XCTAssertEqual(task.status, "waiting"); XCTAssertFalse(StudioLedger.contains(task))
            XCTAssertEqual(task["peopleWaits"].array[0]["futureField"], "保留")
            XCTAssertTrue(StudioLedger.matches(task, query: "确认报价"))
        }
        graph.filter = .blocked; XCTAssertEqual(graph.visible(query: "").count, 3)
        graph.filter = .ready; XCTAssertTrue(graph.visible(query: "").isEmpty)
        store.edit("work", "peopleWaits", .array([person(resolved: true)])); let resolved = await store.flush(); XCTAssertTrue(resolved)
        graph.reconcile(store.tasks); XCTAssertEqual(graph.visible(query: "").map(\.id), ["work"])
        XCTAssertEqual(store.task("work")?.status, "waiting")
        let reopened = OOSStore(api: api, recoverDrafts: false); await reopened.refresh()
        XCTAssertEqual(reopened.task("work")?["peopleWaits"], store.task("work")?["peopleWaits"])
        store.edit("work", "peopleWaits", []); let cleared = await store.flush(); XCTAssertTrue(cleared)
        XCTAssertEqual(store.task("work")?.text("blockedBy"), "")
    }
    @MainActor func testConditionHitRegionsStaySeparateFromTitleAndCompletion() {
        let graph = TaskGraphModel(); graph.reconcile([Record(["id": "a", "title": "A", "status": "ready"])])
        let surface = TaskGraphSurface(); surface.graph = graph
        let full = surface.rect("a"), editor = surface.conditionsRect("a")
        XCTAssertGreaterThan(editor.minY - full.minY, 74)
        XCTAssertLessThan(editor.maxY, full.maxY - 31)
        XCTAssertFalse(editor.intersects(surface.satisfiedRect("a")))
        graph.layout.zoom = 0.3
        XCTAssertTrue(surface.rect("a").contains(surface.conditionsRect("a")))
    }
    @MainActor func testClickingAConditionTargetsOnlyThatType() {
        var task = Record(["id": "a", "title": "A", "status": "waiting", "peopleWaits": .array([person()]),
                           "availableAt": "2099-01-01T12:00:00+08:00", "dependsOn": ["b"]])
        let predecessor = Record(["id": "b", "title": "B", "status": "ready"])
        let graph = TaskGraphModel(); graph.reconcile([task, predecessor])
        let surface = TaskGraphSurface(); surface.graph = graph
        let area = surface.conditionsRect("a")
        for (index, kind) in TaskConditionKind.allCases.enumerated() {
            XCTAssertEqual(surface.conditionKind("a", at: CGPoint(x: area.midX, y: area.minY + Double(index) * 20 + 5)), kind)
        }
        task["peopleWaits"] = .array([person(resolved: true)]); graph.reconcile([task, predecessor])
        XCTAssertEqual(surface.conditionKind("a", at: CGPoint(x: area.midX, y: area.minY + 5)), .time)
        XCTAssertNil(surface.conditionKind("a", at: CGPoint(x: area.midX, y: area.minY + 45)))
        graph.layout.zoom = 0.3
        XCTAssertNil(surface.conditionKind("a", at: surface.conditionsRect("a").origin))
    }
    @MainActor func testQuickConditionWindowIsCompactAndTimeIsShorter() {
        let task = Record(["dependsOn": .array((0..<50).map { .string("task-\($0)") })])
        for kind in TaskConditionKind.allCases {
            let size = TaskConditionsPanel.size(for: kind, task: task)
            XCTAssertEqual(size.width, 330); XCTAssertLessThanOrEqual(size.height, 300)
        }
        XCTAssertLessThan(TaskConditionsPanel.size(for: .time, task: task).height, 160)
        XCTAssertEqual(TaskConditionsPanel.size(for: .person, task: task).height, 240)
    }
}
