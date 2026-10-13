import XCTest
import AppKit
@testable import OOSCore
@testable import HeroOOSNative

@MainActor final class TaskGraphPersonFilterTests: XCTestCase {
    private func wait(_ person: String, resolved: Bool = false, id: String = UUID().uuidString) -> JSON {
        ["id": .string(id), "person": .string(person), "outcome": "等待确认", "resolved": .bool(resolved)]
    }

    private func task(_ id: String, title: String? = nil, status: String = "ready", waits: [JSON] = []) -> Record {
        Record(["id": .string(id), "title": .string(title ?? id), "status": .string(status), "peopleWaits": .array(waits)])
    }

    private func ids(_ graph: TaskGraphModel, query: String = "") -> Set<String> {
        Set(graph.visible(query: query).map(\.id))
    }

    func testDefaultAndPeopleChoicesNormalizeCaseWhitespaceAndDeduplicateUnresolvedPeople() {
        let source = [task("a", waits: [wait(" ALICE "), wait("bob")]),
                      task("b", waits: [wait("\nalice\t"), wait("OLD", resolved: true)]),
                      task("c")]
        let graph = TaskGraphModel(); graph.reconcile(source)

        XCTAssertEqual(graph.personFilter, .all)
        XCTAssertEqual(graph.blockerPeople, ["alice", "bob"])
        XCTAssertEqual(ids(graph), ["a", "b", "c"])
        graph.personFilter = .person("alice")
        XCTAssertEqual(ids(graph), ["a", "b"])
        graph.personFilter = .person("bob")
        XCTAssertEqual(ids(graph), ["a"])
        XCTAssertEqual(graph.tasks, source) // Reading/filtering never normalizes the stored task.
    }

    func testLegacyBlockedByIsSupportedButExplicitEmptyPeopleWaitsWins() {
        let source = [Record(["id": "legacy", "title": "旧格式", "status": "waiting", "blockedBy": "  ALICE\n"]),
                      Record(["id": "cleared", "title": "已清除", "status": "ready", "blockedBy": "ALICE", "peopleWaits": []]),
                      task("resolved", waits: [wait("alice", resolved: true)]),
                      task("free")]
        let graph = TaskGraphModel(); graph.reconcile(source)

        XCTAssertEqual(graph.blockerPeople, ["alice"])
        graph.personFilter = .person("alice")
        XCTAssertEqual(ids(graph), ["legacy"])
        graph.personFilter = .none
        XCTAssertEqual(ids(graph), ["cleared", "resolved", "free"])
        XCTAssertEqual(graph.tasks, source)
    }

    func testPeopleSearchAndReadinessFiltersIntersect() {
        let source = [task("invoice", title: "示例甲 已开票", waits: [wait("ALICE")]),
                      task("recording", title: "示例乙 录音", waits: [wait("alice")]),
                      task("other", title: "示例甲 已开票", waits: [wait("other")]),
                      task("ready", title: "示例甲 可开始")]
        let graph = TaskGraphModel(); graph.reconcile(source)
        graph.personFilter = .person("alice")

        XCTAssertEqual(ids(graph, query: "示例甲"), ["invoice"])
        XCTAssertTrue(ids(graph, query: "不存在").isEmpty)
        graph.filter = .blocked
        XCTAssertEqual(ids(graph, query: "示例甲"), ["invoice"])
        graph.filter = .ready
        XCTAssertTrue(ids(graph).isEmpty)
        graph.personFilter = .none
        XCTAssertEqual(ids(graph, query: "示例甲"), ["ready"])
    }

    func testHistoryVisibilityAlsoScopesPeopleOptionsAndMatches() {
        var archived = task("archived", waits: [wait("archive-person")]); archived["archived"] = true
        let source = [task("open", waits: [wait("alice")]),
                      task("closed", status: "completed", waits: [wait("closed-person")]),
                      task("cancelled", status: "cancelled", waits: [wait("cancel-person")]), archived]
        let graph = TaskGraphModel(); graph.reconcile(source)

        XCTAssertEqual(graph.blockerPeople, ["alice"])
        graph.personFilter = .person("closed-person")
        XCTAssertTrue(ids(graph).isEmpty)
        XCTAssertEqual(Set(graph.blockerPeople), ["alice", "closed-person"])
        graph.showClosed = true
        XCTAssertEqual(ids(graph), ["closed"])
        graph.personFilter = .all; graph.showCancelled = true; graph.showArchived = true
        XCTAssertEqual(graph.blockerPeople, ["alice", "archive-person", "cancel-person", "closed-person"])
        XCTAssertEqual(ids(graph), ["open", "closed", "cancelled", "archived"])
    }

    func testCollapsedChildIsRepresentedByParentAndSearchMustMatchTheSameRealTask() {
        let parent = task("parent", title: "项目总览")
        var alice = task("child-alice", title: "录音结算", waits: [wait("ALICE")]); alice["parentId"] = "parent"
        var other = task("child-other", title: "美术交付", waits: [wait("other")]); other["parentId"] = "parent"
        let graph = TaskGraphModel(); graph.reconcile([parent, alice, other]); graph.collapse("parent")
        graph.personFilter = .person("alice")

        XCTAssertEqual(ids(graph), ["parent"])
        XCTAssertEqual(ids(graph, query: "录音"), ["parent"])
        XCTAssertTrue(ids(graph, query: "美术").isEmpty) // No person match on one sibling + search on another.
        XCTAssertTrue(ids(graph, query: "项目总览").isEmpty) // A parent's title is not the child's own text.
        graph.collapse("parent")
        XCTAssertEqual(ids(graph), ["child-alice"])
    }

    func testExpandedSatisfiedPredecessorsRemainLocalContextUnderPeopleFilter() {
        var done = task("done", title: "已完成前置", status: "completed", waits: [wait("other", resolved: true)])
        done["archived"] = true
        var now = task("now", title: "当前交付", waits: [wait("alice")]); now["dependsOn"] = ["done"]
        let graph = TaskGraphModel(); graph.reconcile([done, now, task("unrelated", status: "completed")])
        graph.personFilter = .person("alice")

        XCTAssertEqual(ids(graph), ["now"])
        graph.toggleSatisfied("now")
        XCTAssertEqual(ids(graph, query: "当前交付"), ["done", "now"])
        XCTAssertEqual(graph.edges(visible: ids(graph)).map(\.0), [GraphEdge(from: "done", to: "now")])
        XCTAssertTrue(ids(graph, query: "不匹配").isEmpty)
        graph.personFilter = .person("unmatched")
        XCTAssertTrue(ids(graph).isEmpty) // Expanded history cannot leak without its matching owner.
    }

    func testChangingPersonFilterClearsOnlyHiddenSelectionsAndEdgesWithoutChangingDataOrCamera() {
        var follower = task("follower", waits: [wait("alice")]); follower["dependsOn"] = ["first"]
        let source = [task("first", waits: [wait("ALICE")]), follower, task("other", waits: [wait("other")])]
        let graph = TaskGraphModel(); graph.reconcile(source)
        graph.layout.zoom = 0.28; graph.layout.offset = GraphPoint(CGPoint(x: -871, y: 435))
        graph.selection = ["first", "follower", "other"]
        graph.selectedEdge = GraphEdge(from: "first", to: "other")
        let before = graph.layout

        graph.personFilter = .person("alice"); graph.personFilterDidChange(query: "")

        XCTAssertEqual(graph.selection, ["first", "follower"])
        XCTAssertNil(graph.selectedEdge)
        XCTAssertEqual(graph.layout, before); XCTAssertEqual(graph.tasks, source); XCTAssertEqual(graph.undoCount, 0)
        graph.selectedEdge = GraphEdge(from: "first", to: "follower")
        graph.personFilterDidChange(query: "")
        XCTAssertEqual(graph.selectedEdge, GraphEdge(from: "first", to: "follower"))
        graph.personFilterDidChange(query: "follower")
        XCTAssertEqual(graph.selection, ["follower"]); XCTAssertNil(graph.selectedEdge)
        XCTAssertEqual(graph.layout, before)
    }

    func testDependencyArrangeMovesOnlyPersonAndSearchMatchesAndResetDoesNotRearrange() {
        let source = [task("match", title: "示例甲 结算", waits: [wait("alice")]),
                      task("not-search", title: "示例乙 结算", waits: [wait("alice")]),
                      task("not-person", title: "示例甲 交付", waits: [wait("other")]),
                      task("closed", title: "示例甲 历史", status: "completed", waits: [wait("alice")])]
        let graph = TaskGraphModel(); graph.reconcile(source)
        for (index, item) in source.enumerated() {
            graph.layout.positions[item.id] = GraphPoint(CGPoint(x: 9000 + index * 500, y: 8000 + index * 400))
        }
        graph.layout.zoom = 0.36; graph.layout.offset = GraphPoint(CGPoint(x: 173, y: -288))
        graph.personFilter = .person("alice")
        let before = graph.layout

        graph.arrange(query: "示例甲")

        XCTAssertEqual(graph.layout.positions["match"], GraphPoint(.zero))
        for id in ["not-search", "not-person", "closed"] { XCTAssertEqual(graph.layout.positions[id], before.positions[id]) }
        XCTAssertEqual(graph.tasks, source); XCTAssertEqual(graph.undoCount, 1)
        let arranged = graph.layout
        graph.personFilter = .all; graph.personFilterDidChange(query: "")
        XCTAssertEqual(graph.layout, arranged); XCTAssertEqual(graph.undoCount, 1)
        XCTAssertEqual(ids(graph), ["match", "not-search", "not-person"])
    }

    func testNearbyArrangeDoesNotMoveTasksExcludedByPerson() {
        let source = [task("a", waits: [wait("alice")]), task("b", waits: [wait("alice")]), task("excluded", waits: [wait("other")])]
        let graph = TaskGraphModel(); graph.reconcile(source)
        graph.layout.positions["a"] = GraphPoint(CGPoint(x: 6000, y: 7000))
        graph.layout.positions["b"] = GraphPoint(CGPoint(x: 10000, y: 10000))
        graph.personFilter = .person("alice")
        let before = graph.layout

        graph.arrangeNearby(query: "")

        XCTAssertNotEqual(graph.layout.positions["a"], before.positions["a"])
        XCTAssertEqual(graph.layout.positions["excluded"], before.positions["excluded"])
        XCTAssertEqual(graph.layout.zoom, before.zoom); XCTAssertEqual(graph.layout.offset, before.offset)
        XCTAssertEqual(graph.tasks, source)
    }

    func testRefreshUpdatesPeopleChoicesWhileRetainingSelectedMissingPersonAndLayout() {
        let graph = TaskGraphModel(); graph.reconcile([task("a", waits: [wait("ALICE")])])
        graph.personFilter = .person("alice")
        let layout = graph.layout

        graph.reconcile([task("a", waits: [wait("new-person"), wait("alice", resolved: true)])])

        XCTAssertEqual(graph.personFilter, .person("alice"))
        XCTAssertEqual(graph.blockerPeople, ["alice", "new-person"])
        XCTAssertTrue(ids(graph).isEmpty)
        XCTAssertEqual(graph.layout, layout)
        graph.personFilter = .all; graph.personFilterDidChange(query: "")
        XCTAssertEqual(graph.blockerPeople, ["new-person"])
        XCTAssertEqual(ids(graph), ["a"]); XCTAssertEqual(graph.layout, layout)
    }

    func testRevealResetsPeopleFilterAndUnfoldsTheRequestedTask() {
        var child = task("child", status: "completed", waits: [wait("other")])
        child["parentId"] = "parent"; child["archived"] = true
        let graph = TaskGraphModel(); graph.reconcile([task("parent"), child])
        graph.collapse("parent"); graph.personFilter = .person("alice"); graph.filter = .blocked
        let positions = graph.layout.positions

        graph.reveal("child")

        XCTAssertEqual(graph.personFilter, .all); XCTAssertEqual(graph.filter, .all)
        XCTAssertEqual(graph.selection, ["child"])
        XCTAssertFalse(graph.layout.collapsed.contains("parent"))
        XCTAssertTrue(graph.showClosed); XCTAssertTrue(graph.showArchived)
        XCTAssertTrue(ids(graph).contains("child"))
        XCTAssertEqual(graph.layout.positions, positions)
    }
}
