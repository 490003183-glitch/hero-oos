import XCTest
import AppKit
import Combine
@testable import OOSCore
@testable import HeroOOSNative

@MainActor final class TaskGraphRenderingTests: XCTestCase {
    private func records(_ count: Int) -> [OOSCore.Record] {
        (0..<count).map { i in
            OOSCore.Record(["id": .string("task-\(i)"), "title": .string("第 \(i) 项制作与交付任务"),
                    "status": "ready", "dependsOn": i > 0 && i % 4 != 0 ? [.string("task-\(i - 1)")] : []])
        }
    }

    func testPanPreparationBenchmark() throws {
        let suite = "HeroOOS.graph-performance.\(UUID().uuidString)", own = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { own.removePersistentDomain(forName: suite) }
        let count = ProcessInfo.processInfo.environment["HERO_OOS_GRAPH_BENCHMARK"] == "1" ? 1000 : 100
        let tasks = records(count), graph = TaskGraphModel(defaults: own)
        graph.connect(identity: "benchmark", tasks: tasks)
        let writes = graph.persistenceWriteCount
        let start = ProcessInfo.processInfo.systemUptime
        var edgeCount = 0
        for frame in 0..<120 {
            graph.updateCamera(offset: CGPoint(x: frame * 2, y: frame))
            let visible = graph.visible(query: "")
            _ = graph.presentation()
            edgeCount += graph.edges(visible: Set(visible.map(\.id))).count
        }
        XCTAssertEqual(graph.persistenceWriteCount, writes)
        graph.persist()
        XCTAssertEqual(graph.persistenceWriteCount, writes + 1)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertGreaterThan(edgeCount, 0)
        XCTAssertEqual(graph.visibilityBuildCount, 1)
        XCTAssertEqual(graph.edgeBuildCount, 1)
        XCTAssertEqual(graph.presentationBuildCount, 1)
        print("GRAPH_PAN_BENCHMARK \(count) tasks / 120 frames: \(String(format: "%.2f", elapsed * 1000)) ms total (including cold condition cache and final camera save)")
        let warmStart = ProcessInfo.processInfo.systemUptime
        for frame in 0..<120 {
            graph.updateCamera(offset: CGPoint(x: -frame * 2, y: -frame))
            let visible = graph.visible(query: "")
            _ = graph.presentation()
            _ = graph.edges(visible: Set(visible.map(\.id)))
        }
        graph.persist()
        print("GRAPH_PAN_WARM_BENCHMARK \(count) tasks / 120 frames: \(String(format: "%.2f", (ProcessInfo.processInfo.systemUptime - warmStart) * 1000)) ms total")
    }

    func testCameraDoesNotPublishEachPanAndFinalFlushSurvivesReopen() throws {
        let suite = "HeroOOS.graph-camera.\(UUID().uuidString)", own = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { own.removePersistentDomain(forName: suite) }
        let graph = TaskGraphModel(defaults: own); graph.connect(identity: "one", tasks: records(12))
        let positions = graph.layout.positions, writes = graph.persistenceWriteCount, revision = graph.geometryRevision
        var publications = 0
        let observation = graph.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        for i in 0..<120 { graph.updateCamera(offset: CGPoint(x: i * 3, y: -i)) }
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(graph.persistenceWriteCount, writes)
        XCTAssertEqual(graph.geometryRevision, revision)
        XCTAssertEqual(graph.layout.positions, positions)
        graph.persist() // The same flush used by page disappearance and app quit.
        let reopened = TaskGraphModel(defaults: own); reopened.connect(identity: "one", tasks: records(12))
        XCTAssertEqual(reopened.layout, graph.layout)
        XCTAssertEqual(graph.persistenceWriteCount, writes + 1)
        graph.persist(); XCTAssertEqual(graph.persistenceWriteCount, writes + 1)
    }

    func testCameraDebounceFlushesOnceAfterGestureSettles() async throws {
        let suite = "HeroOOS.graph-debounce.\(UUID().uuidString)", own = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { own.removePersistentDomain(forName: suite) }
        let graph = TaskGraphModel(defaults: own); graph.connect(identity: "one", tasks: records(3))
        let writes = graph.persistenceWriteCount
        for i in 0..<30 { graph.updateCamera(zoom: 0.30, offset: CGPoint(x: i, y: i)) }
        XCTAssertEqual(graph.persistenceWriteCount, writes)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(graph.persistenceWriteCount, writes + 1)
        let reopened = TaskGraphModel(defaults: own); reopened.connect(identity: "one", tasks: records(3))
        XCTAssertEqual(reopened.layout.zoom, 0.30)
        XCTAssertEqual(reopened.layout.offset, GraphPoint(CGPoint(x: 29, y: 29)))
    }

    func testChangingIdentityFlushesOldCameraWithoutLeakingItIntoNewGraph() throws {
        let suite = "HeroOOS.graph-identity.\(UUID().uuidString)", own = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { own.removePersistentDomain(forName: suite) }
        let graph = TaskGraphModel(defaults: own); graph.connect(identity: "one", tasks: records(3))
        graph.updateCamera(zoom: 0.32, offset: CGPoint(x: 876, y: 432))
        let old = graph.layout
        graph.connect(identity: "two", tasks: records(3))
        XCTAssertNotEqual(graph.layout.offset, old.offset)
        let reopened = TaskGraphModel(defaults: own); reopened.connect(identity: "one", tasks: records(3))
        XCTAssertEqual(reopened.layout, old)
    }

    func testRenderCachesInvalidateForDataFiltersCollapseAndClockNotSelectionOrPan() throws {
        let now = Date(), future = now.addingTimeInterval(600)
        var source = records(4)
        source[1]["availableAt"] = .string(RuntimeDate.iso(future))
        source[2]["parentId"] = "task-0"
        let graph = TaskGraphModel(); graph.reconcile(source)
        graph.timeFilter = .hideUpcoming
        func snapshot(_ at: Date) -> Set<String> {
            let ids = Set(graph.visible(query: "", at: at).map(\.id))
            _ = graph.edges(visible: ids)
            return ids
        }
        XCTAssertFalse(snapshot(now).contains("task-1"))
        let first = graph.visibilityBuildCount
        graph.selection = ["task-0"]; graph.updateCamera(offset: CGPoint(x: 900, y: 400))
        _ = snapshot(now.addingTimeInterval(20))
        XCTAssertEqual(graph.visibilityBuildCount, first)
        XCTAssertTrue(snapshot(future.addingTimeInterval(1)).contains("task-1"))
        XCTAssertEqual(graph.visibilityBuildCount, first + 1)
        graph.collapse("task-0")
        XCTAssertFalse(snapshot(future.addingTimeInterval(2)).contains("task-2"))
        source[3]["status"] = "cancelled"; graph.reconcile(source)
        XCTAssertFalse(snapshot(future.addingTimeInterval(3)).contains("task-3"))
        graph.showCancelled = true
        XCTAssertTrue(snapshot(future.addingTimeInterval(4)).contains("task-3"))
        XCTAssertFalse(snapshot(now).contains("task-1")) // Clock adjustment is also safe.
    }

    func testCompactGeometryRetainsCenterAndTwoReadableLinesAtEveryTitleZoom() {
        let point = CGPoint(x: -100, y: 120), full = CGRect(origin: point, size: TaskGraphGeometry.size)
        for zoom in [0.2, 0.25, 0.3, 0.4, 0.45] {
            let compact = TaskGraphGeometry.nodeRect(at: point, zoom: zoom)
            XCTAssertEqual(compact.midX, full.midX, accuracy: 0.0001)
            XCTAssertEqual(compact.midY, full.midY, accuracy: 0.0001)
            XCTAssertGreaterThanOrEqual(compact.height * zoom, 38)
            XCTAssertEqual(TaskGraphGeometry.titleScreenFontSize / zoom * zoom, 13, accuracy: 0.0001)
        }
    }

    func testEmptyAndValidTimeConditionsKeepTheSameSemantics() throws {
        for value: JSON in [.null, "", "not-a-date"] {
            XCTAssertNil(TaskDependencies.availableDate(OOSCore.Record(["availableAt": value])))
        }
        let text = "2026-10-13T12:30:00Z"
        XCTAssertEqual(TaskDependencies.availableDate(OOSCore.Record(["availableAt": .string(text)])), RuntimeDate.parse(text))
    }

    func testNodeHitAndPortsAcrossSemanticLevelsDoNotConsumeOverviewSelection() throws {
        let graph = TaskGraphModel(); graph.reconcile(records(2))
        graph.layout.positions["task-0"] = GraphPoint(.zero)
        graph.layout.positions["task-1"] = GraphPoint(CGPoint(x: 1000, y: 0))
        let surface = TaskGraphSurface(frame: CGRect(x: 0, y: 0, width: 1000, height: 650)); surface.graph = graph
        graph.selection = ["task-0"]
        let positions = graph.layout.positions
        for zoom in [0.08, 0.19, 0.20, 0.3, 0.45, 0.46, 1] {
            surface.zoomTo(zoom)
            let rect = surface.rect("task-0"), center = CGPoint(x: rect.midX, y: rect.midY)
            XCTAssertEqual(surface.hit(center), "task-0")
            XCTAssertNil(surface.port(center))
            if zoom < TaskGraphGeometry.overviewZoom { XCTAssertNil(surface.port(CGPoint(x: rect.maxX, y: rect.midY))) }
            else { XCTAssertEqual(surface.port(CGPoint(x: rect.maxX, y: rect.midY))?.0, "task-0") }
            XCTAssertEqual(graph.layout.positions, positions)
        }
    }

    func testOptionalNativeOverviewRenderingPreview() throws {
        guard let directory = ProcessInfo.processInfo.environment["HERO_OOS_GRAPH_RENDER_PREVIEW"] else { return }
        _ = NSApplication.shared
        let graph = TaskGraphModel(); graph.reconcile(records(24)); graph.showMiniMap = false
        let store = OOSStore(api: OOSAPI(base: URL(fileURLWithPath: directory)), recoverDrafts: false)
        let surface = TaskGraphSurface(frame: CGRect(x: 0, y: 0, width: 900, height: 560))
        surface.graph = graph; surface.store = store
        graph.selection = ["task-2"]
        for zoom in [0.30, 0.08] {
            graph.updateCamera(zoom: zoom, offset: CGPoint(x: 80, y: 90))
            let image = NSImage(size: surface.bounds.size)
            image.lockFocus(); surface.draw(surface.bounds); image.unlockFocus()
            let data = try XCTUnwrap(image.tiffRepresentation)
            let png = try XCTUnwrap(NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("graph-\(Int(zoom * 100)).png"))
        }
    }
}
