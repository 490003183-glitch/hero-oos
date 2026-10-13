import XCTest
import AppKit
@testable import OOSCore
@testable import HeroOOSNative

final class PrivateTaskViewPreferenceTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "HeroOOS.private-view-preferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func testGraphIsAvailableOnlyOnPersonalPageAndUnsupportedDefaultsFallBack() throws {
        let custom = try XCTUnwrap(TaskSpace(rawValue: "page-13FC9187-4D3F-4B19-971B-720650FA3BE6"))
        XCTAssertEqual(TaskViewMode.graph.rawValue, 2)
        XCTAssertEqual(TaskViewMode.available(for: .personal), [.list, .board, .graph])
        XCTAssertEqual(TaskViewMode.available(for: .work), [.list, .board])
        XCTAssertEqual(TaskViewMode.available(for: custom), [.list, .board])
        try withDefaults { defaults in
            defaults.set(TaskViewMode.graph.rawValue, forKey: TaskViewPreferences.personalKey)
            defaults.set(TaskViewMode.graph.rawValue, forKey: TaskViewPreferences.workKey)
            XCTAssertEqual(TaskViewPreferences.mode(for: .personal, defaults: defaults), .graph)
            XCTAssertEqual(TaskViewPreferences.mode(for: .work, defaults: defaults), .board)
            let malformed = WorkspaceViewState(modes: ["work": 2, custom.rawValue: 2])
            XCTAssertEqual(malformed.mode(for: .work, defaults: defaults), .board)
            XCTAssertEqual(malformed.mode(for: custom, defaults: defaults), .board)
        }
    }

    func testLastPrivateGraphChoicePersistsPerAccountWithoutChangingWorkMode() throws {
        try withDefaults { defaults in
            WorkspaceViewState(pageKey: "personal", selectedTaskID: "private-a",
                modes: ["personal": 2, "work": 0]).save(identity: "account-a", defaults: defaults)
            WorkspaceViewState(pageKey: "personal", modes: ["personal": 1, "work": 1])
                .save(identity: "account-b", defaults: defaults)
            let reopened = WorkspaceViewState.load(identity: "account-a", defaults: defaults)
            XCTAssertEqual(reopened.page, .personal)
            XCTAssertEqual(reopened.selectedTaskID, "private-a")
            XCTAssertEqual(reopened.mode(for: .personal, defaults: defaults), .graph)
            XCTAssertEqual(reopened.mode(for: .work, defaults: defaults), .list)
            XCTAssertEqual(WorkspaceViewState.load(identity: "account-b", defaults: defaults)
                .mode(for: .personal, defaults: defaults), .board)
        }
    }
}

@MainActor final class TaskGraphPrivateViewTests: XCTestCase {
    private var records: [Record] {
        [Record(["id": "private", "title": "私人任务", "taskSpace": "personal", "status": "ready", "dependsOn": ["work-done", "private-done"]]),
         Record(["id": "private-child", "title": "私人子任务", "taskSpace": "personal", "status": "ready", "parentId": "private"]),
         Record(["id": "private-done", "title": "私人已完成前置", "taskSpace": "personal", "status": "completed"]),
         Record(["id": "work-done", "title": "工作已完成前置", "taskSpace": "work", "status": "completed"]),
         Record(["id": "work", "title": "组织工作", "taskSpace": "work", "status": "ready"])]
    }
    private let privateIDs: Set<String> = ["private", "private-child", "private-done"]

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "HeroOOS.private-graph.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func testGraphHasOnlyPrivateTasksIncludingExpandedCompletedContext() throws {
        try withDefaults { defaults in
            let graph = TaskGraphModel(defaults: defaults, space: .personal)
            graph.connect(identity: "one", tasks: records)
            XCTAssertEqual(graph.space, .personal)
            XCTAssertEqual(Set(graph.tasks.map(\.id)), privateIDs)
            XCTAssertEqual(Set(graph.byID.keys), privateIDs)
            XCTAssertEqual(Set(graph.layout.positions.keys), privateIDs)
            XCTAssertEqual(Set(graph.visible(query: "").map(\.id)), ["private", "private-child"])
            graph.toggleSatisfied("private")
            XCTAssertEqual(graph.satisfiedPredecessors(records[0]).map(\.id), ["private-done"])
            XCTAssertEqual(Set(graph.visible(query: "").map(\.id)), privateIDs)
            graph.showClosed = true; graph.showCancelled = true; graph.showArchived = true
            XCTAssertEqual(Set(graph.visible(query: "").map(\.id)), privateIDs)
            XCTAssertTrue(graph.visible(query: "组织工作").isEmpty)
        }
    }

    func testCrossPagePrerequisiteRefreshInvalidatesPrivateConditionCacheWithoutShowingWorkNode() throws {
        try withDefaults { defaults in
            var tasks = records
            tasks[3]["status"] = "ready"
            let graph = TaskGraphModel(defaults: defaults, space: .personal)
            graph.connect(identity: "one", tasks: tasks)
            graph.filter = .blocked
            XCTAssertEqual(graph.visible(query: "").map(\.id), ["private"])
            XCTAssertEqual(graph.presentation()["private"]?.pending.count, 1)
            let layout = graph.layout
            tasks[3]["status"] = "completed"
            graph.reconcile(tasks)
            XCTAssertTrue(graph.visible(query: "").isEmpty)
            XCTAssertEqual(graph.presentation()["private"]?.pending.count, 0)
            graph.filter = .ready
            XCTAssertEqual(Set(graph.visible(query: "").map(\.id)), ["private", "private-child"])
            XCTAssertEqual(graph.layout, layout)
            XCTAssertNil(graph.byID["work-done"])
            tasks[3]["status"] = "ready"
            graph.reconcile(tasks)
            XCTAssertFalse(graph.visible(query: "").contains { $0.id == "private" })
        }
    }

    func testGlobalPrivateAndOtherAccountKeepSeparateCameraLayoutAndFilters() throws {
        try withDefaults { defaults in
            let global = TaskGraphModel(defaults: defaults)
            global.connect(identity: "one", tasks: records)
            global.layout.positions["private"] = GraphPoint(CGPoint(x: 720, y: 180))
            global.updateCamera(zoom: 0.31, offset: CGPoint(x: -80, y: 900))
            global.personFilter = .person("alice"); global.timeFilter = .hideUpcoming
            global.selection = ["work"]; global.persist()
            let globalLayout = global.layout

            let personal = TaskGraphModel(defaults: defaults, space: .personal)
            personal.connect(identity: "one", tasks: records)
            personal.layout.positions["private"] = GraphPoint(CGPoint(x: -1200, y: 33))
            personal.updateCamera(zoom: 0.74, offset: CGPoint(x: 318, y: -89))
            personal.filter = .blocked; personal.timeFilter = .upcomingOnly
            personal.selection = ["private"]; personal.persist()
            let personalLayout = personal.layout

            XCTAssertNotNil(defaults.data(forKey: "HeroOOS.taskGraph.v1.one"))
            XCTAssertNotNil(defaults.data(forKey: "HeroOOS.taskGraph.v1.one.page.personal"))
            let globalAgain = TaskGraphModel(defaults: defaults)
            globalAgain.connect(identity: "one", tasks: records)
            XCTAssertEqual(globalAgain.layout, globalLayout)
            XCTAssertEqual(globalAgain.personFilter, .person("alice"))
            XCTAssertEqual(globalAgain.timeFilter, .hideUpcoming)
            XCTAssertEqual(globalAgain.selection, ["work"])

            let personalAgain = TaskGraphModel(defaults: defaults, space: .personal)
            personalAgain.connect(identity: "one", tasks: records)
            XCTAssertEqual(personalAgain.layout, personalLayout)
            XCTAssertEqual(personalAgain.personFilter, .all)
            XCTAssertEqual(personalAgain.timeFilter, .upcomingOnly)
            XCTAssertEqual(personalAgain.filter, .blocked)
            XCTAssertEqual(personalAgain.selection, ["private"])
            XCTAssertFalse(personalAgain.needsInitialFit)
            personalAgain.connect(identity: "two", tasks: records)
            XCTAssertEqual(personalAgain.filter, .all)
            XCTAssertEqual(personalAgain.timeFilter, .all)
            XCTAssertTrue(personalAgain.selection.isEmpty)
            personalAgain.connect(identity: "one", tasks: records)
            XCTAssertEqual(personalAgain.layout, personalLayout)
            XCTAssertEqual(personalAgain.filter, .blocked)
        }
    }

    func testReconcilePrunesMovedOutTasksButPreservesTheirPrivateLayoutHistory() throws {
        try withDefaults { defaults in
            let graph = TaskGraphModel(defaults: defaults, space: .personal)
            graph.connect(identity: "one", tasks: records)
            graph.selection = ["private", "work"]
            graph.selectedEdge = GraphEdge(from: "work-done", to: "private")
            graph.toggleSatisfied("work")
            graph.reconcile(records)
            XCTAssertEqual(graph.selection, ["private"])
            XCTAssertNil(graph.selectedEdge)
            XCTAssertTrue(graph.expandedSatisfied.isEmpty)
            let priorPosition = graph.layout.positions["private"]
            let priorCamera = graph.layout.offset
            var updated = records
            updated[0]["taskSpace"] = "work"
            updated.append(Record(["id": "new-private", "title": "新私人任务", "taskSpace": "personal", "status": "ready"]))
            updated.append(Record(["id": "new-work", "title": "新工作任务", "taskSpace": "work", "status": "ready"]))
            graph.reconcile(updated)
            let expected: Set<String> = ["private-child", "private-done", "new-private"]
            XCTAssertEqual(Set(graph.tasks.map(\.id)), expected)
            // Historical coordinates remain in this private-only namespace,
            // matching the existing global graph's undo/move-back semantics.
            XCTAssertEqual(Set(graph.layout.positions.keys), expected.union(["private"]))
            XCTAssertEqual(graph.layout.positions["private"], priorPosition)
            XCTAssertEqual(graph.layout.offset, priorCamera)
            XCTAssertNil(graph.layout.positions["new-work"])
            XCTAssertTrue(graph.selection.isEmpty)
            XCTAssertNil(graph.byID["private"])
            graph.filter = .all; graph.showClosed = true
            XCTAssertEqual(Set(graph.visible(query: "").map(\.id)), expected)
        }
    }

    func testTraceAndEdgesDoNotBringCrossPagePrerequisitesOntoPrivateCanvas() throws {
        try withDefaults { defaults in
            let graph = TaskGraphModel(defaults: defaults, space: .personal)
            graph.connect(identity: "one", tasks: records)
            graph.showClosed = true; graph.selection = ["private"]; graph.trace = .upstream
            XCTAssertTrue(graph.highlighted.isSubset(of: privateIDs))
            XCTAssertTrue(graph.highlighted.contains("private-done"))
            let visible = Set(graph.visible(query: "").map(\.id))
            for (edge, originals) in graph.edges(visible: visible) {
                XCTAssertTrue(privateIDs.contains(edge.from)); XCTAssertTrue(privateIDs.contains(edge.to))
                for original in originals {
                    XCTAssertTrue(privateIDs.contains(original.from)); XCTAssertTrue(privateIDs.contains(original.to))
                }
            }
        }
    }

    func testPrivateCanvasCreatesOnlyPrivateTasksWhileGlobalGraphRetainsAllSpaces() throws {
        try withDefaults { defaults in
            let personal = TaskGraphModel(defaults: defaults, space: .personal)
            personal.connect(identity: "one", tasks: records)
            XCTAssertEqual(personal.creationSpaces(parent: nil, available: [.work, .personal]), [.personal])
            XCTAssertEqual(personal.creationSpaces(parent: "private", available: [.work, .personal]), [.personal])
            XCTAssertEqual(personal.creationSpaces(parent: "work", available: [.work, .personal]), [.personal])
            let global = TaskGraphModel(defaults: defaults)
            global.connect(identity: "one", tasks: records)
            XCTAssertEqual(global.creationSpaces(parent: nil, available: [.work, .personal]), [.work, .personal])
            XCTAssertEqual(global.creationSpaces(parent: "private", available: [.work, .personal]), [.personal])
            XCTAssertEqual(global.creationSpaces(parent: "work", available: [.work, .personal]), [.work])
        }
    }
}

final class TaskGraphPrivateIntegrationTests: SwiftIntegrationCase {
    private func seed() throws {
        _ = try mutate([
            ["type": "task.create", "task": ["id": "private", "title": "私人", "taskSpace": "personal"]],
            ["type": "task.create", "task": ["id": "private-2", "title": "私人二", "taskSpace": "personal"]],
            ["type": "task.create", "task": ["id": "work", "title": "工作"]]
        ])
    }

    @MainActor func testCompletionUndoIgnoresWorkReceiptsAndReconcilesOnlyPrivateTasks() async throws {
        try seed()
        let store = OOSStore(api: api, recoverDrafts: false); await store.refresh()
        let graph = TaskGraphModel(space: .personal); graph.reconcile(store.tasks)
        graph.observeCompletions(store.state["receipts"].records, initial: true)
        let workCompleted = await store.perform([["type": "task.complete", "id": "work"]])
        XCTAssertTrue(workCompleted)
        graph.reconcile(store.tasks); graph.observeCompletions(store.state["receipts"].records)
        XCTAssertEqual(graph.undoCount, 0)
        XCTAssertNil(graph.completionFeedback["work"])
        let personalCompleted = await store.perform([["type": "task.complete", "id": "private"]])
        XCTAssertTrue(personalCompleted)
        graph.reconcile(store.tasks); graph.observeCompletions(store.state["receipts"].records)
        XCTAssertEqual(graph.undoCount, 1)
        await graph.undo(store: store)
        XCTAssertEqual(store.task("work")?.status, "completed")
        XCTAssertEqual(store.task("private")?.status, "ready")
        XCTAssertEqual(graph.selection, ["private"])
        XCTAssertEqual(Set(graph.tasks.map(\.id)), ["private", "private-2"])
        XCTAssertEqual(Set(graph.layout.positions.keys), ["private", "private-2"])
    }

    @MainActor func testMixedSpaceReceiptCannotUndoWorkFromPrivateGraph() async throws {
        try seed()
        let store = OOSStore(api: api, recoverDrafts: false); await store.refresh()
        let graph = TaskGraphModel(space: .personal); graph.reconcile(store.tasks)
        graph.observeCompletions(store.state["receipts"].records, initial: true)
        let completed = await store.perform([
            ["type": "task.complete", "id": "private"],
            ["type": "task.complete", "id": "work"]
        ])
        XCTAssertTrue(completed)
        graph.reconcile(store.tasks); graph.observeCompletions(store.state["receipts"].records)
        XCTAssertEqual(graph.undoCount, 0)
        await graph.undo(store: store)
        XCTAssertEqual(store.task("private")?.status, "completed")
        XCTAssertEqual(store.task("work")?.status, "completed")
        XCTAssertNil(graph.completionFeedback["work"])
    }

    @MainActor func testLayoutUndoRestoresPrivateCoordinatesWithoutDisplayingMovedOutTask() async throws {
        try seed()
        let store = OOSStore(api: api, recoverDrafts: false); await store.refresh()
        let graph = TaskGraphModel(space: .personal); graph.reconcile(store.tasks)
        let old = graph.layout
        graph.layout.positions["private"] = GraphPoint(CGPoint(x: 3000, y: 2000))
        graph.checkpoint(old)
        let moved = await store.perform([["type": "task.update", "id": "private", "changes": ["taskSpace": "work"]]])
        XCTAssertTrue(moved)
        graph.reconcile(store.tasks)
        await graph.undo(store: store)
        XCTAssertEqual(store.task("private")?.taskSpace, .work)
        XCTAssertEqual(Set(graph.tasks.map(\.id)), ["private-2"])
        XCTAssertNil(graph.byID["private"])
        XCTAssertFalse(graph.selection.contains("private"))
        XCTAssertEqual(Set(graph.visible(query: "").map(\.id)), ["private-2"])
        XCTAssertEqual(graph.layout, old)
        XCTAssertNil(graph.layout.positions["work"])
    }
}
