import XCTest
import AppKit
import Combine
@testable import OOSCore
@testable import HeroOOSNative

@MainActor final class TaskGraphTimeFilterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_864_000) // 2026-10-13 12:00 +08:00

    private func task(_ id: String, title: String? = nil, status: String = "ready", availableAt: String? = nil, person: String? = nil) -> OOSCore.Record {
        var record = OOSCore.Record(["id": .string(id), "title": .string(title ?? id), "status": .string(status)])
        if let availableAt { record["availableAt"] = .string(availableAt) }
        if let person {
            record["peopleWaits"] = [["id": .string("wait-" + id), "person": .string(person), "outcome": "等待确认", "resolved": false]]
        }
        return record
    }

    private func ids(_ graph: TaskGraphModel, query: String = "", at date: Date? = nil) -> Set<String> {
        Set(graph.visible(query: query, at: date ?? now).map(\.id))
    }

    func testCanvasClipsZoomedCardsSoFilterToolbarStaysVisible() {
        let surface = TaskGraphSurface(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertTrue(surface.clipsToBounds)
    }

    func testDefaultAndTimeBoundaryUseAbsoluteTimestampNotCalendarDay() throws {
        let boundary = try XCTUnwrap(RuntimeDate.parse("2026-10-13T12:00:00+08:00"))
        XCTAssertEqual(now, boundary)
        let source = [task("future", availableAt: "2026-10-13T12:00:01+08:00"),
                      task("same", availableAt: "2026-10-13T04:00:00Z"),
                      task("past", availableAt: "2026-10-13T11:59:59+08:00"),
                      task("none"), task("empty", availableAt: ""), task("invalid", availableAt: "不是日期")]
        let graph = TaskGraphModel(); graph.reconcile(source)

        XCTAssertEqual(graph.timeFilter, .all)
        XCTAssertEqual(ids(graph), Set(source.map(\.id)))
        graph.timeFilter = .hideUpcoming
        XCTAssertEqual(ids(graph), ["same", "past", "none", "empty", "invalid"])
        graph.timeFilter = .upcomingOnly
        XCTAssertEqual(ids(graph), ["future"])
        XCTAssertTrue(ids(graph, at: now.addingTimeInterval(1)).isEmpty) // Equal to the time means available.
        XCTAssertEqual(graph.tasks, source)
    }

    func testDeadlineReviewDateAndNullAvailableAtAreNotTimeBlocks() {
        var deadline = task("deadline"); deadline["dueDate"] = "2099-10-20"; deadline["due"] = "2099-10-20"
        var review = task("review", status: "waiting"); review["reviewDate"] = "2099-10-20"
        var null = task("null"); null["availableAt"] = .null
        let graph = TaskGraphModel(); graph.reconcile([deadline, review, null])

        graph.timeFilter = .hideUpcoming
        XCTAssertEqual(ids(graph), ["deadline", "review", "null"])
        graph.timeFilter = .upcomingOnly
        XCTAssertTrue(ids(graph).isEmpty)
    }

    func testTimePeopleSearchAndReadinessFiltersIntersectWithoutTreatingOtherBlocksAsTime() {
        let future = RuntimeDate.iso(now.addingTimeInterval(3600))
        let past = RuntimeDate.iso(now.addingTimeInterval(-3600))
        var dependency = task("dependency", title: "示例客户 等前置", availableAt: past, person: "alice")
        dependency["dependsOn"] = ["upstream"]
        let source = [task("future", title: "示例客户 未到时间", availableAt: future, person: " ALICE "),
                      task("person", title: "示例客户 等回复", availableAt: past, person: "alice"), dependency,
                      task("other-person", title: "示例客户 其他人", person: "other"),
                      task("other-search", title: "示例项目 等回复", person: "alice"),
                      task("available", title: "示例客户 可以开始", availableAt: past), task("upstream")]
        let graph = TaskGraphModel(); graph.reconcile(source)
        graph.timeFilter = .hideUpcoming; graph.personFilter = .person("alice")

        XCTAssertEqual(ids(graph, query: "示例客户"), ["person", "dependency"])
        graph.filter = .blocked
        XCTAssertEqual(ids(graph, query: "示例客户"), ["person", "dependency"])
        graph.filter = .ready
        XCTAssertTrue(ids(graph, query: "示例客户").isEmpty)
        graph.personFilter = .none
        XCTAssertEqual(ids(graph, query: "示例客户"), ["available"])
        graph.timeFilter = .upcomingOnly; graph.personFilter = .all; graph.filter = .blocked
        XCTAssertEqual(ids(graph, query: "示例客户"), ["future"])
        XCTAssertTrue(ids(graph, query: "不存在").isEmpty)
    }

    func testReadinessUsesTheSameInjectedClockAsTimeFilter() {
        let task = task("clock", availableAt: RuntimeDate.iso(now.addingTimeInterval(20)))
        let graph = TaskGraphModel(); graph.reconcile([task])
        graph.timeFilter = .upcomingOnly; graph.filter = .blocked
        XCTAssertEqual(ids(graph), ["clock"])
        graph.filter = .ready
        XCTAssertTrue(ids(graph).isEmpty)
        graph.timeFilter = .hideUpcoming
        XCTAssertEqual(ids(graph, at: now.addingTimeInterval(20)), ["clock"])
        graph.filter = .blocked
        XCTAssertTrue(ids(graph, at: now.addingTimeInterval(20)).isEmpty)
    }

    func testCollapsedChildrenMustMatchPersonTimeAndSearchOnTheSameRealTask() {
        let parent = task("parent", title: "项目总览")
        var future = task("future-child", title: "录音结算", availableAt: RuntimeDate.iso(now.addingTimeInterval(60)), person: "alice")
        var past = task("past-child", title: "美术交付", availableAt: RuntimeDate.iso(now.addingTimeInterval(-60)), person: "alice")
        var other = task("other-child", title: "设计交付", availableAt: RuntimeDate.iso(now.addingTimeInterval(60)), person: "other")
        future["parentId"] = "parent"; past["parentId"] = "parent"; other["parentId"] = "parent"
        let graph = TaskGraphModel(); graph.reconcile([parent, future, past, other]); graph.collapse("parent")
        graph.timeFilter = .upcomingOnly; graph.personFilter = .person("alice")

        XCTAssertEqual(ids(graph), ["parent"])
        XCTAssertEqual(ids(graph, query: "录音"), ["parent"])
        XCTAssertTrue(ids(graph, query: "美术").isEmpty)
        XCTAssertTrue(ids(graph, query: "设计").isEmpty)
        XCTAssertTrue(ids(graph, query: "项目总览").isEmpty)
        graph.collapse("parent")
        XCTAssertEqual(ids(graph), ["future-child"])
    }

    func testHiddenHistoryCannotSupplyATimeMatchForACollapsedOpenParent() {
        let future = RuntimeDate.iso(now.addingTimeInterval(60))
        var closed = task("closed-child", status: "completed", availableAt: future); closed["parentId"] = "parent"
        var archived = task("archived", availableAt: future); archived["archived"] = true
        let graph = TaskGraphModel()
        graph.reconcile([task("parent"), closed, task("cancelled", status: "cancelled", availableAt: future), archived])
        graph.collapse("parent"); graph.timeFilter = .upcomingOnly

        XCTAssertTrue(ids(graph).isEmpty)
        graph.showClosed = true
        XCTAssertEqual(ids(graph), ["parent"])
        graph.showCancelled = true; graph.showArchived = true
        XCTAssertEqual(ids(graph), ["parent", "cancelled", "archived"])
        graph.timeFilter = .hideUpcoming
        XCTAssertEqual(ids(graph), ["parent"])
    }

    func testFutureTimeIsFilteredEvenForActiveOrPausedTasksWithoutAFlashingTimePhase() {
        let future = RuntimeDate.iso(now.addingTimeInterval(3600))
        let active = task("active", status: "active", availableAt: future)
        let paused = task("paused", status: "paused", availableAt: future)
        let information = task("information", status: "information", availableAt: future)
        let graph = TaskGraphModel(); graph.reconcile([active, paused, information, task("ready")])

        XCTAssertEqual(graph.dependencies.timePhase(active, at: now), .inactive)
        graph.timeFilter = .upcomingOnly
        XCTAssertEqual(ids(graph), ["active", "paused", "information"])
        graph.timeFilter = .hideUpcoming
        XCTAssertEqual(ids(graph), ["ready"])
    }

    func testExplicitlyExpandedCompletedPredecessorRemainsContextDespiteItsTime() {
        let future = RuntimeDate.iso(now.addingTimeInterval(3600))
        var done = task("done", status: "completed", availableAt: future); done["archived"] = true
        var current = task("current", title: "当前交付", person: "alice"); current["dependsOn"] = ["done"]
        let graph = TaskGraphModel(); graph.reconcile([done, current, task("unrelated", status: "completed", availableAt: future)])
        graph.timeFilter = .hideUpcoming; graph.personFilter = .person("alice")

        XCTAssertEqual(ids(graph), ["current"])
        graph.toggleSatisfied("current")
        XCTAssertEqual(ids(graph, query: "当前交付"), ["current", "done"])
        XCTAssertEqual(graph.edges(visible: ids(graph)).map(\.0), [GraphEdge(from: "done", to: "current")])
        XCTAssertTrue(ids(graph, query: "不匹配").isEmpty)
        graph.timeFilter = .upcomingOnly
        XCTAssertTrue(ids(graph).isEmpty) // Expanded context cannot outlive its matching owner.
    }

    func testChangingTimeFilterClearsHiddenSelectionAndEdgesButDoesNotMutateStateOrLayout() {
        var visible = task("visible"); visible["dependsOn"] = ["first"]
        let source = [task("first"), visible, task("future", availableAt: RuntimeDate.iso(now.addingTimeInterval(60)))]
        let graph = TaskGraphModel(); graph.reconcile(source)
        graph.layout.zoom = 0.31; graph.layout.offset = GraphPoint(CGPoint(x: 127, y: -431))
        graph.selection = ["first", "visible", "future"]; graph.selectedEdge = GraphEdge(from: "future", to: "visible")
        let before = graph.layout

        graph.timeFilter = .hideUpcoming; graph.timeFilterDidChange(query: "", at: now)

        XCTAssertEqual(graph.selection, ["first", "visible"]); XCTAssertNil(graph.selectedEdge)
        graph.selectedEdge = GraphEdge(from: "first", to: "visible")
        graph.timeFilterDidChange(query: "", at: now)
        XCTAssertEqual(graph.selectedEdge, GraphEdge(from: "first", to: "visible"))
        graph.timeFilterDidChange(query: "visible", at: now)
        XCTAssertEqual(graph.selection, ["visible"]); XCTAssertNil(graph.selectedEdge)
        graph.timeFilter = .all; graph.timeFilterDidChange(query: "", at: now)
        XCTAssertEqual(ids(graph), ["first", "visible", "future"])
        XCTAssertEqual(graph.layout, before); XCTAssertEqual(graph.tasks, source); XCTAssertEqual(graph.undoCount, 0)
    }

    func testClockRefreshPublishesWhenHiddenTaskBecomesAvailableWithoutChangingDataOrLayout() {
        let source = [task("clock", availableAt: RuntimeDate.iso(now.addingTimeInterval(20))), task("other")]
        let graph = TaskGraphModel(); graph.reconcile(source)
        graph.timeFilter = .hideUpcoming; graph.timeFilterDidChange(query: "", at: now)
        graph.refreshTimeFilter(query: "", at: now)
        let before = graph.layout
        var changes = 0
        let observation = graph.objectWillChange.sink { changes += 1 }

        XCTAssertEqual(ids(graph), ["other"])
        graph.refreshTimeFilter(query: "", at: now.addingTimeInterval(10))
        XCTAssertEqual(changes, 0)
        graph.refreshTimeFilter(query: "", at: now.addingTimeInterval(20))
        XCTAssertGreaterThan(changes, 0)
        XCTAssertEqual(ids(graph, at: now.addingTimeInterval(20)), ["clock", "other"])
        changes = 0
        graph.refreshTimeFilter(query: "", at: now.addingTimeInterval(30))
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(graph.layout, before); XCTAssertEqual(graph.tasks, source); XCTAssertEqual(graph.undoCount, 0)
        withExtendedLifetime(observation) {}
    }

    func testClockRefreshRemovesSelectionAndEdgesWhenUpcomingOnlyTaskReachesItsTime() {
        let graph = TaskGraphModel()
        graph.reconcile([task("first", availableAt: RuntimeDate.iso(now.addingTimeInterval(10))),
                         task("later", availableAt: RuntimeDate.iso(now.addingTimeInterval(30)))])
        graph.timeFilter = .upcomingOnly; graph.timeFilterDidChange(query: "", at: now)
        graph.refreshTimeFilter(query: "", at: now)
        graph.selection = ["first", "later"]; graph.selectedEdge = GraphEdge(from: "first", to: "later")
        let before = graph.layout

        graph.refreshTimeFilter(query: "", at: now.addingTimeInterval(10))

        XCTAssertEqual(ids(graph, at: now.addingTimeInterval(10)), ["later"])
        XCTAssertEqual(graph.selection, ["later"]); XCTAssertNil(graph.selectedEdge)
        XCTAssertEqual(graph.layout, before); XCTAssertEqual(graph.timeFilter, .upcomingOnly)
    }

    func testRefreshAfterTimeConditionEditUsesCurrentTaskAndKeepsCoordinates() {
        let graph = TaskGraphModel(); graph.reconcile([task("edited")])
        graph.timeFilter = .hideUpcoming; graph.timeFilterDidChange(query: "", at: now)
        graph.refreshTimeFilter(query: "", at: now)
        graph.selection = ["edited"]
        let before = graph.layout
        let updated = [task("edited", availableAt: RuntimeDate.iso(now.addingTimeInterval(60)))]

        graph.reconcile(updated); graph.refreshTimeFilter(query: "", at: now)

        XCTAssertTrue(ids(graph).isEmpty); XCTAssertTrue(graph.selection.isEmpty)
        XCTAssertEqual(graph.layout, before); XCTAssertEqual(graph.tasks, updated); XCTAssertEqual(graph.undoCount, 0)
    }

    func testDependencyAndNearbyArrangeOnlyMoveTasksPassingTimeFilter() {
        let source = [task("shown", title: "示例客户 已到时间", availableAt: "2000-01-01T00:00:00Z", person: "alice"),
                      task("future", title: "示例客户 未到时间", availableAt: "2099-01-01T00:00:00Z", person: "alice"),
                      task("other-person", title: "示例客户 已到时间", person: "other"),
                      task("other-search", title: "示例项目 已到时间", person: "alice")]
        for nearby in [false, true] {
            let graph = TaskGraphModel(); graph.reconcile(source)
            for (index, item) in source.enumerated() {
                graph.layout.positions[item.id] = GraphPoint(CGPoint(x: 5000 + index * 1000, y: 6000 + index * 1000))
            }
            graph.timeFilter = .hideUpcoming; graph.personFilter = .person("alice")
            let before = graph.layout

            if nearby { graph.arrangeNearby(query: "示例客户") } else { graph.arrange(query: "示例客户") }

            XCTAssertNotEqual(graph.layout.positions["shown"], before.positions["shown"])
            for id in ["future", "other-person", "other-search"] {
                XCTAssertEqual(graph.layout.positions[id], before.positions[id], "Unexpected movement: \(id), nearby=\(nearby)")
            }
            XCTAssertEqual(graph.tasks, source); XCTAssertEqual(graph.undoCount, 1)
            let arranged = graph.layout
            graph.timeFilter = .all; graph.timeFilterDidChange(query: "", at: now)
            XCTAssertEqual(graph.layout, arranged)
        }
    }

    func testRevealResetsTimePersonAndRangeFiltersAndUnfoldsRequestedTask() {
        var child = task("child", status: "completed", availableAt: RuntimeDate.iso(now.addingTimeInterval(60)), person: "other")
        child["parentId"] = "parent"; child["archived"] = true
        let graph = TaskGraphModel(); graph.reconcile([task("parent"), child]); graph.collapse("parent")
        graph.timeFilter = .hideUpcoming; graph.personFilter = .person("alice"); graph.filter = .blocked
        let positions = graph.layout.positions

        graph.reveal("child")

        XCTAssertEqual(graph.timeFilter, .all); XCTAssertEqual(graph.personFilter, .all); XCTAssertEqual(graph.filter, .all)
        XCTAssertEqual(graph.selection, ["child"]); XCTAssertFalse(graph.layout.collapsed.contains("parent"))
        XCTAssertTrue(graph.showClosed); XCTAssertTrue(graph.showArchived); XCTAssertTrue(ids(graph).contains("child"))
        XCTAssertEqual(graph.layout.positions, positions)
    }
}
