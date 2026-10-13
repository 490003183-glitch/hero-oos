import XCTest
import AppKit
@testable import OOSCore
@testable import HeroOOSNative

@MainActor final class TaskGraphRestorationTests: XCTestCase {
    private let tasks = [Record(["id": "a", "title": "前置", "status": "completed"]),
                         Record(["id": "b", "title": "当前", "status": "ready", "dependsOn": ["a"]])]

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "HeroOOS.graph-restoration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func testReopenRestoresEveryFilterSelectionExpandedContextAndExactCamera() throws {
        try withDefaults { defaults in
            let graph = TaskGraphModel(defaults: defaults); graph.connect(identity: "workspace", tasks: tasks)
            graph.filter = .blocked; graph.personFilter = .person("alice"); graph.timeFilter = .hideUpcoming
            graph.trace = .upstream; graph.showClosed = true; graph.showCancelled = true; graph.showArchived = true
            graph.showHierarchy = false; graph.showMiniMap = false
            graph.selection = ["b"]; graph.toggleSatisfied("b")
            graph.layout.positions["b"] = GraphPoint(CGPoint(x: -831, y: 2190))
            graph.layout.collapsed = ["a"]
            graph.updateCamera(zoom: 0.27, offset: CGPoint(x: -876, y: 321))
            graph.persist()

            let reopened = TaskGraphModel(defaults: defaults); reopened.connect(identity: "workspace", tasks: tasks)
            XCTAssertEqual(reopened.layout, graph.layout)
            XCTAssertEqual(reopened.filter, .blocked); XCTAssertEqual(reopened.personFilter, .person("alice"))
            XCTAssertEqual(reopened.timeFilter, .hideUpcoming); XCTAssertEqual(reopened.trace, .upstream)
            XCTAssertTrue(reopened.showClosed); XCTAssertTrue(reopened.showCancelled); XCTAssertTrue(reopened.showArchived)
            XCTAssertFalse(reopened.showHierarchy); XCTAssertFalse(reopened.showMiniMap)
            XCTAssertEqual(reopened.selection, ["b"]); XCTAssertEqual(reopened.expandedSatisfied, ["b"])
            XCTAssertFalse(reopened.needsInitialFit)
        }
    }

    func testLegacyLayoutWithoutViewPreferencesOrMigrationFlagNeverRefitsSavedCamera() throws {
        try withDefaults { defaults in
            var legacy = GraphLayout()
            legacy.positions = ["a": GraphPoint(.zero), "b": GraphPoint(CGPoint(x: 550, y: 600))]
            legacy.zoom = 0.18; legacy.offset = GraphPoint(CGPoint(x: -512, y: 909))
            let key = "HeroOOS.taskGraph.v1.legacy"
            defaults.set(try JSONEncoder().encode(legacy), forKey: key)
            XCTAssertFalse(defaults.bool(forKey: key + ".unfinishedDefault"))
            let graph = TaskGraphModel(defaults: defaults); graph.connect(identity: "legacy", tasks: tasks)
            XCTAssertEqual(graph.layout, legacy); XCTAssertFalse(graph.needsInitialFit)
            XCTAssertEqual(graph.filter, .all); XCTAssertEqual(graph.trace, .all)
            XCTAssertEqual(graph.personFilter, .all); XCTAssertEqual(graph.timeFilter, .all)
            XCTAssertFalse(graph.showClosed); XCTAssertTrue(graph.showHierarchy); XCTAssertTrue(graph.showMiniMap)
        }
    }

    func testWorkspaceIdentitiesKeepFiltersAndSelectionsSeparate() throws {
        try withDefaults { defaults in
            let graph = TaskGraphModel(defaults: defaults); graph.connect(identity: "first", tasks: tasks)
            graph.filter = .ready; graph.trace = .related; graph.personFilter = .none; graph.showClosed = true
            graph.selection = ["b"]; graph.toggleSatisfied("b")
            graph.updateCamera(zoom: 0.4, offset: CGPoint(x: 300, y: 600))
            let firstLayout = graph.layout
            graph.connect(identity: "second", tasks: tasks)
            XCTAssertEqual(graph.filter, .all); XCTAssertEqual(graph.trace, .all); XCTAssertEqual(graph.personFilter, .all)
            XCTAssertFalse(graph.showClosed); XCTAssertTrue(graph.selection.isEmpty); XCTAssertTrue(graph.expandedSatisfied.isEmpty)
            graph.timeFilter = .upcomingOnly; graph.showMiniMap = false
            graph.connect(identity: "first", tasks: tasks)
            XCTAssertEqual(graph.layout, firstLayout); XCTAssertFalse(graph.needsInitialFit)
            XCTAssertEqual(graph.filter, .ready); XCTAssertEqual(graph.trace, .related); XCTAssertEqual(graph.personFilter, .none)
            XCTAssertEqual(graph.timeFilter, .all); XCTAssertTrue(graph.showClosed); XCTAssertTrue(graph.showMiniMap)
            XCTAssertEqual(graph.selection, ["b"]); XCTAssertEqual(graph.expandedSatisfied, ["b"])
            graph.connect(identity: "second", tasks: tasks)
            XCTAssertEqual(graph.timeFilter, .upcomingOnly); XCTAssertFalse(graph.showMiniMap)
        }
    }

    func testDeletedSelectionAndExpandedOwnersAreRemovedWithoutMovingRemainingNodes() throws {
        try withDefaults { defaults in
            let graph = TaskGraphModel(defaults: defaults); graph.connect(identity: "one", tasks: tasks)
            graph.selection = ["a", "b", "missing"]; graph.toggleSatisfied("b"); graph.toggleSatisfied("missing")
            graph.persist(); let layout = graph.layout
            let reopened = TaskGraphModel(defaults: defaults); reopened.connect(identity: "one", tasks: [tasks[0]])
            XCTAssertEqual(reopened.selection, ["a"]); XCTAssertTrue(reopened.expandedSatisfied.isEmpty)
            XCTAssertEqual(reopened.layout, layout); XCTAssertFalse(reopened.needsInitialFit)
            reopened.persist()
            let onceMore = TaskGraphModel(defaults: defaults); onceMore.connect(identity: "one", tasks: tasks)
            XCTAssertEqual(onceMore.selection, ["a"]); XCTAssertTrue(onceMore.expandedSatisfied.isEmpty)
        }
    }

    func testPartialOrUnknownPreferencesUseSafeDefaultsButKeepKnownChoices() throws {
        try withDefaults { defaults in
            let data: JSON = ["filter": "future-new-mode", "personMode": "person", "person": " ALICE ",
                              "showClosed": true, "showMiniMap": false, "selection": ["b"]]
            defaults.set(try data.encoded(), forKey: "HeroOOS.taskGraph.v1.partial.view")
            let graph = TaskGraphModel(defaults: defaults); graph.connect(identity: "partial", tasks: tasks)
            XCTAssertEqual(graph.filter, .all); XCTAssertEqual(graph.trace, .all); XCTAssertEqual(graph.timeFilter, .all)
            XCTAssertEqual(graph.personFilter, .person("alice")); XCTAssertTrue(graph.showClosed)
            XCTAssertFalse(graph.showMiniMap); XCTAssertTrue(graph.showHierarchy); XCTAssertEqual(graph.selection, ["b"])
        }
    }

    func testSavedEmptyGraphCameraSurvivesDelayedTaskArrivalAndOnlyNewGraphsAutoFit() throws {
        try withDefaults { defaults in
            let graph = TaskGraphModel(defaults: defaults); graph.connect(identity: "one", tasks: [])
            XCTAssertTrue(graph.needsInitialFit)
            graph.updateCamera(zoom: 0.6, offset: CGPoint(x: -600, y: 99)); graph.persist()
            let reopened = TaskGraphModel(defaults: defaults); reopened.connect(identity: "one", tasks: [])
            XCTAssertFalse(reopened.needsInitialFit)
            reopened.reconcile(tasks)
            XCTAssertFalse(reopened.needsInitialFit)
            XCTAssertEqual(reopened.layout.offset, graph.layout.offset); XCTAssertEqual(reopened.layout.zoom, graph.layout.zoom)
        }
    }

    func testPreferencesAutosaveWithoutMovingCameraOrRequiringExplicitLayoutSave() async throws {
        let suite = "HeroOOS.graph-view-autosave.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let graph = TaskGraphModel(defaults: defaults); graph.connect(identity: "one", tasks: tasks)
        let layout = graph.layout, writes = graph.persistenceWriteCount
        graph.filter = .blocked; graph.timeFilter = .upcomingOnly; graph.selection = ["b"]
        try await Task.sleep(for: .milliseconds(350))
        let reopened = TaskGraphModel(defaults: defaults); reopened.connect(identity: "one", tasks: tasks)
        XCTAssertEqual(reopened.filter, .blocked); XCTAssertEqual(reopened.timeFilter, .upcomingOnly)
        XCTAssertEqual(reopened.selection, ["b"]); XCTAssertEqual(reopened.layout, layout)
        XCTAssertEqual(graph.persistenceWriteCount, writes)
    }
}
