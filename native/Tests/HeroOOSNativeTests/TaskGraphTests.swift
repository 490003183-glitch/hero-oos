import XCTest
import AppKit
@testable import OOSCore
@testable import HeroOOSNative

final class TaskGraphIntegrationTests: SwiftIntegrationCase {
    @MainActor func testCompletionFeedbackThenUndoRestoresExactPriorStatusAndLayout() async throws {
        _ = try mutate([["type": "task.create", "task": ["id": "focus", "title": "当前工作", "status": "waiting"]]])
        let store = OOSStore(api: api, recoverDrafts: false); await store.refresh()
        let graph = TaskGraphModel(); graph.reconcile(store.tasks)
        graph.observeCompletions(store.state["receipts"].records, initial: true)
        let layout = graph.layout
        store.edit("focus", "status", "completed"); graph.reconcile(store.tasks)
        XCTAssertEqual(graph.visible(query: "").map(\.id), ["focus"])
        let saved = await store.flush(); XCTAssertTrue(saved)
        graph.reconcile(store.tasks); graph.observeCompletions(store.state["receipts"].records)
        graph.observeCompletions(store.state["receipts"].records) // No duplicate undo records.
        XCTAssertEqual(graph.undoCount, 1); XCTAssertEqual(graph.undoTitle, "撤销完成")
        graph.expireCompletionFeedback(at: Date().addingTimeInterval(4))
        XCTAssertTrue(graph.visible(query: "").isEmpty)
        XCTAssertEqual(graph.layout, layout)
        await graph.undo(store: store)
        XCTAssertEqual(store.task("focus")?.status, "waiting")
        XCTAssertEqual(graph.visible(query: "").map(\.id), ["focus"])
        XCTAssertEqual(graph.layout, layout); XCTAssertEqual(graph.undoCount, 0)
    }
    @MainActor func testCompletionUndoRefusesToOverwriteLaterEdit() async throws {
        try seed()
        let store = OOSStore(api: api, recoverDrafts: false); await store.refresh()
        let graph = TaskGraphModel(); graph.reconcile(store.tasks)
        graph.observeCompletions(store.state["receipts"].records, initial: true)
        let completed = await store.perform([["type": "task.complete", "id": "a"]]); XCTAssertTrue(completed)
        graph.reconcile(store.tasks); graph.observeCompletions(store.state["receipts"].records)
        XCTAssertEqual(graph.undoCount, 1)
        _ = try mutate([["type": "task.update", "id": "a", "changes": ["note": "其他端的新信息"]]])
        await graph.undo(store: store)
        XCTAssertEqual(store.task("a")?.status, "completed")
        XCTAssertEqual(store.task("a")?.text("note"), "其他端的新信息")
        XCTAssertEqual(graph.undoCount, 1); XCTAssertNotNil(store.error)
    }
    func testSingleTimeConditionPersistsAndGatesAllStartPaths() throws {
        let future = JSON.string(RuntimeDate.iso(Date().addingTimeInterval(3600)))
        _ = try mutate([["type": "task.create", "task": ["id": "clock", "title": "定时任务", "availableAt": future]]])
        let before = try runtime.readState()
        XCTAssertEqual(before["tasks"].records.first?["availableAt"], future)
        let attempts: [JSON] = [
            ["type": "task.update", "id": "clock", "changes": ["status": "active"]],
            ["type": "task.reorder", "id": "clock", "mode": "board", "placement": "first", "status": "active"],
            ["type": "task.create", "task": ["title": "不能提前", "status": "active", "availableAt": future]]
        ]
        for attempt in attempts {
            XCTAssertThrowsError(try mutate([attempt])) { XCTAssertEqual(($0 as? RuntimeError)?.code, "time_condition_pending") }
        }
        XCTAssertEqual(try runtime.readState(), before)
        XCTAssertFalse(runtime.attention(before).contains { $0["id"] == "clock" })
        XCTAssertTrue(runtime.attention(before, at: Date().addingTimeInterval(3601)).contains { $0["id"] == "clock" })
        _ = try mutate([["type": "task.update", "id": "clock", "changes": ["availableAt": .string(RuntimeDate.iso(Date().addingTimeInterval(-1))), "status": "active"]]])
        XCTAssertEqual(try runtime.readState()["tasks"].records.first?.status, "active")
    }
    func testTimeValidationAndClearDoNotAffectOtherDates() throws {
        _ = try mutate([["type": "task.create", "task": ["id": "clock", "title": "定时任务", "due": "2030-11-01", "availableAt": "2030-10-01T12:00:00+08:00"]]])
        for value: JSON in ["wrong", "2030-10-01", 42, true] {
            XCTAssertThrowsError(try mutate([["type": "task.update", "id": "clock", "changes": ["availableAt": value]]]))
        }
        _ = try mutate([["type": "task.update", "id": "clock", "changes": ["availableAt": "", "status": "active"]]])
        let task = try XCTUnwrap(runtime.readState()["tasks"].records.first)
        XCTAssertEqual(task.text("availableAt"), ""); XCTAssertEqual(task.text("due"), "2030-11-01")
    }
    func testTimePhaseBoundaryPrerequisitesAndStopStates() throws {
        let now = try XCTUnwrap(RuntimeDate.parse("2026-10-12T12:00:00Z"))
        var task = Record(["id": "clock", "title": "定时任务", "status": "ready", "availableAt": .string(RuntimeDate.iso(now)), "dependsOn": ["first"]])
        let first = Record(["id": "first", "title": "前置", "status": "completed"])
        var graph = TaskDependencies([task, first])
        XCTAssertEqual(graph.timePhase(task, at: now.addingTimeInterval(-0.001)), .upcoming)
        XCTAssertNotNil(graph.blocked(task, at: now.addingTimeInterval(-0.001)))
        XCTAssertEqual(graph.timePhase(task, at: now), .ready)
        XCTAssertNil(graph.blocked(task, at: now))
        XCTAssertEqual(graph.timePhase(task, at: now.addingTimeInterval(1000000)), .ready) // No overdue rule.
        var unfinished = first; unfinished["status"] = "ready"
        graph = TaskDependencies([task, unfinished])
        XCTAssertEqual(graph.timePhase(task, at: now), .waitingForPredecessors)
        graph = TaskDependencies([task, first])
        for status in ["active", "completed", "cancelled", "paused", "information"] {
            task["status"] = .string(status); XCTAssertEqual(graph.timePhase(task, at: now), .inactive)
        }
        task["status"] = "ready"; task["archived"] = true
        XCTAssertEqual(graph.timePhase(task, at: now), .inactive)
        task["availableAt"] = .null
        XCTAssertEqual(graph.timePhase(task, at: now), .none)
    }
    @MainActor func testTimeConditionStoreAndGraphUseSameGate() async throws {
        _ = try mutate([["type": "task.create", "task": ["id": "clock", "title": "定时任务", "availableAt": .string(RuntimeDate.iso(Date().addingTimeInterval(3600)))]]])
        let store = OOSStore(api: api, recoverDrafts: false); await store.refresh()
        store.edit("clock", "status", "active")
        XCTAssertEqual(store.task("clock")?.status, "ready"); XCTAssertTrue(store.pending.isEmpty)
        let graph = TaskGraphModel(); graph.reconcile(store.tasks)
        graph.filter = .ready; XCTAssertTrue(graph.visible(query: "").isEmpty)
        graph.filter = .blocked; XCTAssertEqual(graph.visible(query: "").map(\.id), ["clock"])
    }
    private func seed() throws {
        _ = try mutate([
            ["type": "task.create", "task": ["id": "a", "title": "A", "taskSpace": "personal"]],
            ["type": "task.create", "task": ["id": "b", "title": "B"]],
            ["type": "task.create", "task": ["id": "c", "title": "C"]]
        ])
    }
    private func link(_ id: String, _ upstream: String, connected: Bool = true) throws -> JSON {
        try mutate([["type": "task.dependency", "id": .string(id), "upstreamId": .string(upstream), "connected": .bool(connected)]])
    }
    func testCrossPageDependenciesAreAtomicAndPreserveExistingEdges() throws {
        try seed()
        _ = try link("a", "b"); _ = try link("a", "c")
        let tasks = try runtime.readState()["tasks"].records
        XCTAssertEqual(tasks[0]["dependsOn"], ["b", "c"])
        XCTAssertTrue(Relations.canMove("a", to: .work, tasks: tasks))
        _ = try link("a", "b", connected: false)
        XCTAssertEqual(try runtime.readState()["tasks"].records[0]["dependsOn"], ["c"])
        let receipt = try XCTUnwrap(runtime.readState()["receipts"].array.last)
        _ = try mutate([["type": "receipt.undo", "receiptId": receipt["id"]]], confirmed: true)
        XCTAssertEqual(try runtime.readState()["tasks"].records[0]["dependsOn"], ["b", "c"])
    }
    func testAllPredecessorsMustCompleteAndReopenRestoresBlocking() throws {
        try seed(); _ = try link("a", "b"); _ = try link("a", "c")
        let before = try runtime.readState()
        XCTAssertThrowsError(try mutate([["type": "task.update", "id": "a", "changes": ["status": "active"]]]))
        XCTAssertThrowsError(try mutate([["type": "task.reorder", "id": "a", "mode": "board", "placement": "first", "status": "active"]]))
        XCTAssertThrowsError(try mutate([["type": "task.create", "task": ["title": "非法开始", "status": "active", "dependsOn": ["b"]]]]))
        XCTAssertEqual(try runtime.readState(), before)
        _ = try mutate([["type": "task.complete", "id": "b"]])
        XCTAssertThrowsError(try mutate([["type": "task.update", "id": "a", "changes": ["status": "active"]]]))
        // A single transaction can complete the prerequisite and start its follower.
        _ = try mutate([["type": "task.complete", "id": "c"], ["type": "task.update", "id": "a", "changes": ["status": "active"]]])
        _ = try mutate([["type": "task.update", "id": "b", "changes": ["status": "ready"]]])
        let tasks = try runtime.readState()["tasks"].records
        XCTAssertEqual(tasks[0].status, "active") // Never silently rewrite the user's status.
        XCTAssertNotNil(TaskDependencies(tasks).blocked(tasks[0]))
    }
    func testCancellationAndArchiveDoNotSatisfyDependency() throws {
        try seed(); _ = try link("a", "b")
        _ = try mutate([["type": "task.update", "id": "b", "changes": ["archived": true, "status": "cancelled"]]])
        let tasks = try runtime.readState()["tasks"].records
        XCTAssertTrue(TaskDependencies(tasks).blocked(tasks[0])?.contains("已放弃") == true)
        XCTAssertThrowsError(try mutate([["type": "task.update", "id": "a", "changes": ["status": "active"]]]))
    }
    func testSelfCyclesAndMixedParentDeadlocksDoNotWrite() throws {
        try seed(); _ = try link("a", "b")
        let before = try runtime.readState()
        XCTAssertThrowsError(try link("b", "a"))
        XCTAssertThrowsError(try link("c", "c"))
        XCTAssertEqual(try runtime.readState(), before)
        _ = try mutate([["type": "task.create", "task": ["id": "child", "title": "子任务", "parentId": "b"]]])
        XCTAssertThrowsError(try link("child", "b"))
        _ = try link("c", "b")
        XCTAssertThrowsError(try mutate([["type": "task.update", "id": "c", "changes": ["parentId": "b"]]]))
    }
    @MainActor func testStoreRejectsStartWithoutPoisoningDraftsAndGraphUndo() async throws {
        try seed()
        let store = OOSStore(api: api, recoverDrafts: false); await store.refresh()
        let graph = TaskGraphModel()
        await graph.link(GraphEdge(from: "b", to: "a"), connected: true, store: store)
        XCTAssertEqual(store.task("a")?["dependsOn"], ["b"])
        store.edit("a", "status", "active")
        XCTAssertEqual(store.task("a")?.status, "ready")
        XCTAssertTrue(store.pending.isEmpty)
        await graph.undo(store: store)
        XCTAssertEqual(store.task("a")?["dependsOn"], [])
        XCTAssertEqual(graph.undoCount, 0)
    }
}

@MainActor final class TaskGraphTests: XCTestCase {
    func testHistoryHiddenByDefaultAndSatisfiedContextIsLocalToOwner() {
        let source = [Record(["id": "done", "title": "旧前置", "status": "completed", "archived": true]),
                      Record(["id": "cancel", "title": "已放弃前置", "status": "cancelled"]),
                      Record(["id": "other", "title": "无关历史", "status": "completed"]),
                      Record(["id": "now", "title": "当前任务", "status": "ready", "dependsOn": ["done", "cancel"]])]
        let graph = TaskGraphModel(); graph.reconcile(source)
        XCTAssertFalse(graph.showClosed); XCTAssertFalse(graph.showArchived); XCTAssertFalse(graph.showCancelled)
        XCTAssertEqual(graph.visible(query: "").map(\.id), ["now"])
        XCTAssertEqual(graph.satisfiedPredecessors(source[3]).map(\.id), ["done"])
        let layout = graph.layout
        graph.toggleSatisfied("now")
        XCTAssertEqual(Set(graph.visible(query: "当前任务").map(\.id)), ["now", "done"])
        XCTAssertEqual(graph.edges(visible: ["now", "done"]).map(\.0), [GraphEdge(from: "done", to: "now")])
        XCTAssertTrue(graph.visible(query: "不匹配").isEmpty)
        graph.filter = .blocked; XCTAssertEqual(Set(graph.visible(query: "").map(\.id)), ["now", "done"])
        graph.toggleSatisfied("now"); XCTAssertEqual(graph.visible(query: "").map(\.id), ["now"])
        graph.filter = .all; graph.showClosed = true
        XCTAssertEqual(Set(graph.visible(query: "").map(\.id)), ["now", "other"])
        graph.showArchived = true; graph.showCancelled = true
        XCTAssertEqual(graph.visible(query: "").count, 4)
        XCTAssertEqual(graph.layout, layout)
    }
    func testHiddenClosedCollapsedParentDoesNotHideReopenedChild() {
        let graph = TaskGraphModel()
        graph.reconcile([Record(["id": "parent", "title": "旧项目", "status": "completed"]),
                         Record(["id": "child", "title": "重开的子任务", "status": "ready", "parentId": "parent"])])
        graph.collapse("parent")
        XCTAssertEqual(graph.visible(query: "").map(\.id), ["child"])
        graph.showClosed = true
        XCTAssertEqual(graph.visible(query: "").map(\.id), ["parent"])
    }
    func testCompletionGracePeriodDoesNotRearrangeAndHistoryToggleKeepsClosedNode() {
        let graph = TaskGraphModel(); graph.reconcile(tasks); graph.filter = .ready
        var updated = tasks; updated[1]["status"] = "completed"
        graph.selection = ["a"]; let layout = graph.layout
        graph.reconcile(updated)
        XCTAssertTrue(graph.visible(query: "").contains { $0.id == "a" })
        graph.expireCompletionFeedback(at: .distantPast)
        XCTAssertTrue(graph.visible(query: "").contains { $0.id == "a" })
        graph.expireCompletionFeedback(at: .distantFuture)
        XCTAssertFalse(graph.visible(query: "").contains { $0.id == "a" })
        XCTAssertFalse(graph.selection.contains("a")); XCTAssertEqual(graph.layout, layout)
        graph.filter = .all; graph.showClosed = true
        XCTAssertTrue(graph.visible(query: "").contains { $0.id == "a" })
        graph.reconcile(updated); XCTAssertTrue(graph.completionFeedback.isEmpty)
    }
    private var tasks: [Record] {
        [Record(["id": "p", "title": "父任务", "status": "ready"]),
         Record(["id": "a", "title": "设计", "parentId": "p", "status": "ready"]),
         Record(["id": "b", "title": "制作", "parentId": "p", "status": "ready"]),
         Record(["id": "c", "title": "发布", "taskSpace": "personal", "dependsOn": ["a", "b"], "status": "ready"]),
         Record(["id": "d", "title": "历史", "status": "completed", "archived": true])]
    }
    func testAutoLayoutIsStableAndNeverOverlaps() {
        let layout = TaskGraphGeometry.arranged(tasks)
        XCTAssertEqual(layout, TaskGraphGeometry.arranged(tasks))
        XCTAssertLessThan(layout["a"]!.x, layout["c"]!.x)
        for a in tasks { for b in tasks where a.id != b.id {
            XCTAssertFalse(CGRect(origin: layout[a.id]!.point, size: TaskGraphGeometry.size).intersects(CGRect(origin: layout[b.id]!.point, size: TaskGraphGeometry.size)))
        } }
    }
    func testDependencyArrangePacksVisibleTasksWithoutHistorySlotsAndCanUndo() async {
        let history = (0..<28).map { index in
            Record(["id": .string("history-\(index)"), "title": "历史任务", "status": .string(index < 19 ? "completed" : "cancelled")])
        }
        let source = [Record(["id": "project-demo", "title": "示例项目录音项目", "status": "waiting"])] + history +
            [Record(["id": "client-demo", "title": "示例客户录音项目", "status": "waiting"]),
             Record(["id": "archived", "title": "已归档", "status": "ready", "archived": true])]
        let graph = TaskGraphModel(); graph.reconcile(source)
        let before = graph.layout
        XCTAssertGreaterThan(before.positions["client-demo"]!.y - before.positions["project-demo"]!.y, 1000)

        graph.arrange()

        XCTAssertEqual(graph.layout.positions["project-demo"]?.y, 0)
        XCTAssertEqual(graph.layout.positions["client-demo"]?.y, 0)
        XCTAssertEqual(graph.layout.positions["client-demo"]?.x, 340)
        for task in history + [source.last!] { XCTAssertEqual(graph.layout.positions[task.id], before.positions[task.id]) }
        XCTAssertEqual(graph.tasks, source)
        XCTAssertEqual(graph.undoCount, 1)
        let packed = graph.layout
        graph.reconcile(source); XCTAssertEqual(graph.layout, packed)
        await graph.undo(store: OOSStore(recoverDrafts: false)); XCTAssertEqual(graph.layout, before)
    }
    func testDependencyArrangeIgnoresHiddenDependencyLayers() {
        let source = [Record(["id": "old-a", "title": "历史前置", "status": "completed"]),
                      Record(["id": "old-b", "title": "历史后续", "status": "completed", "dependsOn": ["old-a"]]),
                      Record(["id": "now", "title": "当前任务", "status": "ready", "dependsOn": ["old-b"]])]
        let graph = TaskGraphModel(); graph.reconcile(source)
        let before = graph.layout
        XCTAssertEqual(before.positions["now"]?.x, 800)
        graph.arrange()
        XCTAssertEqual(graph.layout.positions["now"], GraphPoint(.zero))
        for id in ["old-a", "old-b"] { XCTAssertEqual(graph.layout.positions[id], before.positions[id]) }
        XCTAssertEqual(graph.tasks, source)
    }
    func testDependencyArrangeUsesCurrentSearchAndFilterWithoutMovingOtherTasks() {
        let source = [Record(["id": "other", "title": "其他项目", "status": "ready"]),
                      Record(["id": "ready", "title": "命中 可开始", "status": "ready"]),
                      Record(["id": "blocked", "title": "命中 被阻断", "status": "ready", "dependsOn": ["other"]])]
        let graph = TaskGraphModel(); graph.reconcile(source)
        let surface = TaskGraphSurface(frame: .zero); surface.graph = graph; surface.query = "命中"; graph.surface = surface
        graph.filter = .ready
        let before = graph.layout
        graph.arrange() // The context-menu action obtains the current search from its surface.
        XCTAssertEqual(graph.layout.positions["ready"], GraphPoint(.zero))
        for id in ["other", "blocked"] { XCTAssertEqual(graph.layout.positions[id], before.positions[id]) }
        let readyLayout = graph.layout
        graph.filter = .blocked; graph.reconcile(source)
        XCTAssertEqual(graph.layout, readyLayout) // Changing the filter never arranges implicitly.
        graph.arrange(query: "命中")
        XCTAssertEqual(graph.layout.positions["blocked"], GraphPoint(.zero))
        for id in ["other", "ready"] { XCTAssertEqual(graph.layout.positions[id], readyLayout.positions[id]) }
        let packed = graph.layout, undoCount = graph.undoCount
        graph.arrange(query: "无匹配任务")
        XCTAssertEqual(graph.layout, packed); XCTAssertEqual(graph.undoCount, undoCount)
    }
    func testDependencyArrangeIncludesLocallyExpandedSatisfiedPredecessors() {
        let source = [Record(["id": "done", "title": "已完成前置", "status": "completed", "archived": true]),
                      Record(["id": "old", "title": "无关历史", "status": "completed"]),
                      Record(["id": "now", "title": "当前任务", "status": "ready", "dependsOn": ["done"]])]
        let graph = TaskGraphModel(); graph.reconcile(source)
        graph.layout.positions["now"] = GraphPoint(CGPoint(x: 9000, y: 8000))
        graph.toggleSatisfied("now")
        let before = graph.layout
        graph.arrange(query: "当前任务")
        XCTAssertEqual(graph.layout.positions["done"], GraphPoint(.zero))
        XCTAssertEqual(graph.layout.positions["now"], GraphPoint(CGPoint(x: 400, y: 0)))
        XCTAssertEqual(graph.layout.positions["old"], before.positions["old"])
        let packed = graph.layout
        graph.toggleSatisfied("now"); XCTAssertEqual(graph.layout, packed)
        XCTAssertEqual(graph.tasks, source)
    }
    func testDependencyArrangeProjectsCollapsedChildEdgesToVisibleParents() {
        let source = [Record(["id": "before", "title": "前置", "status": "ready"]),
                      Record(["id": "parent", "title": "项目", "status": "ready"]),
                      Record(["id": "child", "title": "子任务", "status": "ready", "parentId": "parent", "dependsOn": ["before"]]),
                      Record(["id": "after", "title": "后续", "status": "ready", "dependsOn": ["child"]])]
        let graph = TaskGraphModel(); graph.reconcile(source); graph.collapse("parent")
        let before = graph.layout
        XCTAssertEqual(Set(graph.visible(query: "").map(\.id)), ["before", "parent", "after"])
        graph.arrange()
        XCTAssertEqual(graph.layout.positions["before"], GraphPoint(.zero))
        XCTAssertEqual(graph.layout.positions["parent"], GraphPoint(CGPoint(x: 400, y: 0)))
        XCTAssertEqual(graph.layout.positions["after"], GraphPoint(CGPoint(x: 800, y: 0)))
        XCTAssertEqual(graph.layout.positions["child"], before.positions["child"])
        XCTAssertEqual(graph.tasks, source)
        let packed = graph.layout
        graph.collapse("parent"); graph.reconcile(source)
        XCTAssertEqual(graph.layout.positions, packed.positions)
        XCTAssertEqual(graph.layout.zoom, packed.zoom); XCTAssertEqual(graph.layout.offset, packed.offset)
    }
    func testBackwardDependencyRoutesAboveBothEndpointCards() {
        let source = CGRect(x: 400, y: 200, width: 284, height: 170)
        let target = CGRect(x: 0, y: 200, width: 284, height: 170)
        let points = TaskGraphGeometry.backwardPath(from: source, to: target)
        XCTAssertEqual(points.first, CGPoint(x: source.maxX, y: source.midY))
        XCTAssertEqual(points.last, CGPoint(x: target.minX, y: target.midY))
        for (a, b) in zip(points, points.dropFirst()) {
            for i in 1..<20 {
                let t = Double(i) / 20, point = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                XCTAssertFalse(source.insetBy(dx: 1, dy: 1).contains(point))
                XCTAssertFalse(target.insetBy(dx: 1, dy: 1).contains(point))
            }
        }
    }
    func testTitleOverviewShrinksHeightWithoutMovingTaskCenterOrSavedPosition() {
        let point = CGPoint(x: -72, y: 900)
        let full = TaskGraphGeometry.nodeRect(at: point, zoom: 0.46)
        let compact = TaskGraphGeometry.nodeRect(at: point, zoom: 0.45)
        XCTAssertEqual(full.size, TaskGraphGeometry.size)
        XCTAssertEqual(full.midX, compact.midX); XCTAssertEqual(full.midY, compact.midY)
        XCTAssertLessThan(compact.height, full.height)
        XCTAssertEqual(compact, TaskGraphGeometry.nodeRect(at: point, zoom: 0.1))
    }
    func testNearbyPackingKeepsAnchorAndOriginalDirectionsWithoutOverlap() {
        let points = ["center": GraphPoint(.zero), "right": GraphPoint(CGPoint(x: 4000, y: 0)),
                      "left": GraphPoint(CGPoint(x: -6000, y: 0)), "below": GraphPoint(CGPoint(x: 0, y: 9000))]
        let focus = CGPoint(x: TaskGraphGeometry.size.width / 2, y: TaskGraphGeometry.size.height / 2)
        let packed = TaskGraphGeometry.nearby(points, focus: focus, anchor: "center")
        XCTAssertEqual(packed["center"], points["center"])
        XCTAssertGreaterThan(packed["right"]!.x, 0); XCTAssertLessThan(packed["right"]!.x, 4000)
        XCTAssertLessThan(packed["left"]!.x, 0); XCTAssertGreaterThan(packed["left"]!.x, -6000)
        XCTAssertGreaterThan(packed["below"]!.y, 0); XCTAssertLessThan(packed["below"]!.y, 9000)
        XCTAssertEqual(packed, TaskGraphGeometry.nearby(points, focus: focus, anchor: "center"))
        for a in packed.keys { for b in packed.keys where a != b {
            XCTAssertFalse(CGRect(origin: packed[a]!.point, size: TaskGraphGeometry.size).intersects(CGRect(origin: packed[b]!.point, size: TaskGraphGeometry.size)))
        } }
    }
    func testExplicitNearbyArrangeKeepsCameraMovesCollapsedChildrenAndCanUndo() async {
        let graph = TaskGraphModel(); graph.reconcile(tasks); graph.layout.collapsed = ["p"]; graph.selection = ["c"]
        graph.layout.positions["p"] = GraphPoint(CGPoint(x: 5000, y: 5000))
        let old = graph.layout
        graph.arrangeNearby(query: "")
        XCTAssertEqual(graph.layout.positions["c"], old.positions["c"])
        XCTAssertEqual(graph.layout.zoom, old.zoom); XCTAssertEqual(graph.layout.offset, old.offset)
        let dx = graph.layout.positions["p"]!.x - old.positions["p"]!.x
        let dy = graph.layout.positions["p"]!.y - old.positions["p"]!.y
        XCTAssertEqual(graph.layout.positions["a"]!.x - old.positions["a"]!.x, dx, accuracy: 0.001)
        XCTAssertEqual(graph.layout.positions["a"]!.y - old.positions["a"]!.y, dy, accuracy: 0.001)
        let packed = graph.layout; graph.reconcile(tasks); XCTAssertEqual(graph.layout, packed)
        await graph.undo(store: OOSStore(recoverDrafts: false)); XCTAssertEqual(graph.layout, old)
    }
    func testPositionsCameraAndCollapsedStateSurviveReopenAndRefresh() async {
        let suite = "HeroOOS.graph-test.\(UUID().uuidString)"
        let own = UserDefaults(suiteName: suite)!
        defer { own.removePersistentDomain(forName: suite) }
        let graph = TaskGraphModel(defaults: own); graph.connect(identity: "test", tasks: tasks)
        let old = graph.layout
        graph.layout.positions["a"] = GraphPoint(CGPoint(x: -310, y: 800)); graph.layout.zoom = 0.63
        graph.layout.offset = GraphPoint(CGPoint(x: 85, y: -73)); graph.layout.collapsed = ["p"]; graph.checkpoint(old)
        let saved = graph.layout
        let reopened = TaskGraphModel(defaults: own); reopened.connect(identity: "test", tasks: tasks)
        XCTAssertEqual(saved, reopened.layout)
        reopened.reconcile(tasks + [Record(["id": "new", "title": "新任务"])])
        XCTAssertEqual(reopened.layout.positions["a"], saved.positions["a"])
        XCTAssertEqual(reopened.layout.zoom, 0.63)
        await graph.undo(store: OOSStore(recoverDrafts: false)); XCTAssertEqual(graph.layout, old)
    }
    func testCollapseAggregatesEdgesAndSearchFindsHiddenChild() {
        let graph = TaskGraphModel(); graph.reconcile(tasks); graph.collapse("p")
        graph.showClosed = true; graph.showArchived = true
        XCTAssertEqual(Set(graph.visible(query: "").map(\.id)), ["p", "c", "d"])
        XCTAssertEqual(graph.visible(query: "设计").map(\.id), ["p"])
        let edges = graph.edges(visible: ["p", "c", "d"])
        XCTAssertEqual(edges.count, 1); XCTAssertEqual(edges.first?.1.count, 2)
        graph.showClosed = false; graph.showArchived = false
        XCTAssertEqual(Set(graph.visible(query: "").map(\.id)), ["p", "c"])
        graph.filter = .blocked; XCTAssertEqual(graph.visible(query: "").map(\.id), ["c"])
        graph.filter = .ready; XCTAssertEqual(graph.visible(query: "").map(\.id), ["p"])
    }
    func testTraceIncludesTransitiveDependenciesAndHierarchy() {
        let graph = TaskGraphModel(); graph.reconcile(tasks)
        graph.selection = ["c"]; graph.trace = .upstream
        XCTAssertEqual(graph.highlighted, ["c", "a", "b"])
        graph.selection = ["a"]; graph.trace = .downstream
        XCTAssertEqual(graph.highlighted, ["a", "p", "c"])
    }
    func testZoomPreservesPointerWorldCoordinateAndFitKeepsContentVisible() {
        let graph = TaskGraphModel(); graph.reconcile(tasks)
        let surface = TaskGraphSurface(frame: CGRect(x: 0, y: 0, width: 1000, height: 650)); surface.graph = graph
        let anchor = CGPoint(x: 175, y: 231), before = surface.world(anchor)
        surface.zoomTo(0.23, anchor: anchor)
        XCTAssertEqual(surface.world(anchor).x, before.x, accuracy: 0.0001)
        XCTAssertEqual(surface.world(anchor).y, before.y, accuracy: 0.0001)
        surface.fit()
        for item in graph.visible(query: "") {
            let r = surface.rect(item.id)
            XCTAssertTrue(surface.bounds.contains(surface.screen(r.origin)))
            XCTAssertTrue(surface.bounds.contains(surface.screen(CGPoint(x: r.maxX, y: r.maxY))))
        }
    }
    func testInlineEditorRemainsAttachedAndCommitsOnlyOnFinish() {
        _ = NSApplication.shared
        let graph = TaskGraphModel(); graph.reconcile(tasks)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        let surface = TaskGraphSurface(frame: window.contentView!.bounds); surface.graph = graph
        window.contentView = surface
        surface.beginTitle(tasks[0])
        let editor = surface.subviews.compactMap { $0 as? NSTextField }.first
        XCTAssertNotNil(editor)
        editor?.stringValue = "改名验证"
        surface.commitTitle()
        XCTAssertTrue(surface.subviews.isEmpty)
        window.contentView = nil
    }
}
