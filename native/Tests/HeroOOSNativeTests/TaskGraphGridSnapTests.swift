import XCTest
import AppKit
@testable import OOSCore
@testable import HeroOOSNative

@MainActor final class TaskGraphGridSnapTests: XCTestCase {
    private func fixture(space: TaskSpace? = nil,
                         _ body: (TaskGraphSurface, TaskGraphModel, OOSStore, UserDefaults) async throws -> Void) async throws {
        let identity = "HeroOOS.graph-grid.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: identity))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(identity)
        let store = OOSStore(api: OOSAPI(base: root), recoverDrafts: false)
        store.state = ["tasks": [["id": "a", "title": "任务 A", "taskSpace": "personal", "status": "ready"],
                                 ["id": "b", "title": "任务 B", "taskSpace": "personal", "status": "ready"],
                                 ["id": "child", "title": "子任务", "taskSpace": "personal", "status": "ready", "parentId": "a"],
                                 ["id": "other", "title": "未选任务", "taskSpace": "personal", "status": "ready"]]]
        let graph = TaskGraphModel(defaults: defaults, space: space)
        graph.connect(identity: "isolated-grid", tasks: store.tasks)
        graph.showMiniMap = false; graph.needsInitialFit = false
        graph.layout.positions = ["a": GraphPoint(CGPoint(x: 5, y: 7)), "b": GraphPoint(CGPoint(x: 500, y: 13)),
                                  "child": GraphPoint(CGPoint(x: 99, y: 409)), "other": GraphPoint(CGPoint(x: 1000, y: 200))]
        graph.layout.offset = GraphPoint(CGPoint(x: 80, y: 80))
        let surface = TaskGraphSurface(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        surface.graph = graph; graph.surface = surface; surface.store = store
        defer {
            surface.cancelHoverPreview(); store.stop()
            defaults.removePersistentDomain(forName: identity)
            try? FileManager.default.removeItem(at: root)
        }
        try await body(surface, graph, store, defaults)
    }

    private func event(_ kind: NSEvent.EventType, surface: TaskGraphSurface, point: CGPoint,
                       flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: kind, location: surface.convert(surface.screen(point), to: nil),
                                       modifierFlags: flags, timestamp: 1, windowNumber: 0, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func clickPoint(_ surface: TaskGraphSurface, id: String) -> CGPoint {
        let rect = surface.rect(id)
        return CGPoint(x: rect.midX, y: rect.minY + (surface.graph!.layout.zoom <= TaskGraphGeometry.titleOnlyZoom ? rect.height / 2 : 44))
    }

    func testNearestGridWorksAcrossPositiveNegativeAndHalfStepCoordinates() {
        XCTAssertEqual(TaskGraphGeometry.snapGridSpacing, 24)
        XCTAssertEqual(TaskGraphGeometry.snappedPoint(CGPoint(x: 11.9, y: 12.1)), CGPoint(x: 0, y: 24))
        XCTAssertEqual(TaskGraphGeometry.snappedPoint(CGPoint(x: -11.9, y: -12.1)), CGPoint(x: 0, y: -24))
        XCTAssertEqual(TaskGraphGeometry.snappedPoint(CGPoint(x: 12, y: -12)), CGPoint(x: 24, y: -24))
        XCTAssertEqual(TaskGraphGeometry.snappedPoint(CGPoint(x: -240, y: 480)), CGPoint(x: -240, y: 480))
    }

    func testDragRemainsFreeUntilReleaseAndUsesFinalMouseUpLocation() async throws {
        try await fixture { surface, graph, store, _ in
            let original = store.state, before = graph.layout
            let down = self.clickPoint(surface, id: "a")
            surface.mouseDown(with: try self.event(.leftMouseDown, surface: surface, point: down))
            surface.mouseDragged(with: try self.event(.leftMouseDragged, surface: surface, point: CGPoint(x: down.x + 26, y: down.y + 31)))
            XCTAssertEqual(graph.layout.positions["a"], GraphPoint(CGPoint(x: 31, y: 38)))
            XCTAssertEqual(graph.undoCount, 0)
            // AppKit may coalesce the final dragged event; release is authoritative.
            surface.mouseUp(with: try self.event(.leftMouseUp, surface: surface, point: CGPoint(x: down.x + 49, y: down.y + 28)))
            XCTAssertEqual(graph.layout.positions["a"], GraphPoint(CGPoint(x: 48, y: 24)))
            XCTAssertEqual(graph.layout.positions["b"], before.positions["b"])
            XCTAssertEqual(graph.undoCount, 1)
            XCTAssertEqual(store.state, original); XCTAssertTrue(store.pending.isEmpty)
        }
    }

    func testMultiSelectionUsesDraggedAnchorAndCarriesCollapsedChildAsOneGroup() async throws {
        try await fixture { surface, graph, store, _ in
            let original = store.state
            graph.selection = ["a", "b"]; graph.layout.collapsed = ["a"]
            let before = graph.layout, down = self.clickPoint(surface, id: "b")
            let target = CGPoint(x: down.x + 29, y: down.y - 28)
            surface.mouseDown(with: try self.event(.leftMouseDown, surface: surface, point: down))
            surface.mouseDragged(with: try self.event(.leftMouseDragged, surface: surface, point: target))
            surface.mouseUp(with: try self.event(.leftMouseUp, surface: surface, point: target))
            XCTAssertEqual(graph.layout.positions["b"], GraphPoint(CGPoint(x: 528, y: -24)))
            for id in ["a", "b", "child"] {
                XCTAssertEqual(graph.layout.positions[id]!.x - before.positions[id]!.x, 28, accuracy: 0.000001)
                XCTAssertEqual(graph.layout.positions[id]!.y - before.positions[id]!.y, -37, accuracy: 0.000001)
            }
            XCTAssertEqual(graph.layout.positions["other"], before.positions["other"])
            XCTAssertEqual(graph.undoCount, 1)
            await graph.undo(store: store)
            XCTAssertEqual(graph.layout, before); XCTAssertEqual(graph.undoCount, 0)
            XCTAssertEqual(store.state, original); XCTAssertTrue(store.pending.isEmpty)
        }
    }

    func testWorldGridIsIndependentOfZoomInBothGlobalAndPrivateGraphs() async throws {
        for space: TaskSpace? in [nil, .personal] {
            try await fixture(space: space) { surface, graph, store, _ in
                let original = store.state, positions = graph.layout.positions
                for zoom in [0.08, 0.3, 0.45, 1.0, 3.0] {
                    graph.layout.positions = positions; graph.layout.zoom = zoom
                    let down = self.clickPoint(surface, id: "a")
                    let target = CGPoint(x: down.x - 66, y: down.y + 34)
                    surface.mouseDown(with: try self.event(.leftMouseDown, surface: surface, point: down))
                    surface.mouseDragged(with: try self.event(.leftMouseDragged, surface: surface, point: target))
                    surface.mouseUp(with: try self.event(.leftMouseUp, surface: surface, point: target))
                    XCTAssertEqual(graph.layout.positions["a"], GraphPoint(CGPoint(x: -72, y: 48)), "zoom \(zoom), space \(String(describing: space))")
                    XCTAssertEqual(graph.layout.positions["b"], positions["b"])
                }
                XCTAssertEqual(store.state, original); XCTAssertTrue(store.pending.isEmpty)
            }
        }
    }

    func testClickTinyDriftPanAndReconcileKeepLegacyOffGridPositions() async throws {
        try await fixture { surface, graph, _, _ in
            let before = graph.layout, down = self.clickPoint(surface, id: "a")
            surface.mouseDown(with: try self.event(.leftMouseDown, surface: surface, point: down))
            surface.mouseDragged(with: try self.event(.leftMouseDragged, surface: surface, point: CGPoint(x: down.x + 2, y: down.y + 1)))
            surface.mouseUp(with: try self.event(.leftMouseUp, surface: surface, point: CGPoint(x: down.x + 2, y: down.y + 1)))
            XCTAssertEqual(graph.layout, before); XCTAssertEqual(graph.undoCount, 0)
            graph.reconcile(graph.tasks)
            surface.zoomTo(0.31, anchor: CGPoint(x: 40, y: 50))
            XCTAssertEqual(graph.layout.positions, before.positions)
            let blank = CGPoint(x: 1800, y: 1200)
            let cameraBefore = graph.layout.offset
            let target = CGPoint(x: blank.x + 130, y: blank.y + 120)
            // NSEvent.mouseEvent does not set buttonNumber=2 for synthetic
            // otherMouse events. Exercise the supported Space + drag pan instead.
            let spaceDown = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 1, windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                isARepeat: false, keyCode: 49))
            let spaceUp = try XCTUnwrap(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [],
                timestamp: 2, windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                isARepeat: false, keyCode: 49))
            surface.keyDown(with: spaceDown)
            surface.mouseDown(with: try self.event(.leftMouseDown, surface: surface, point: blank))
            surface.mouseDragged(with: try self.event(.leftMouseDragged, surface: surface, point: target))
            surface.mouseUp(with: try self.event(.leftMouseUp, surface: surface, point: target))
            surface.keyUp(with: spaceUp)
            XCTAssertNotEqual(graph.layout.offset, cameraBefore)
            XCTAssertEqual(graph.layout.positions, before.positions)
        }
    }

    func testSnappedDropPersistsAndReopensWithoutMovingLegacyNeighbours() async throws {
        try await fixture { surface, graph, store, defaults in
            let before = graph.layout, down = self.clickPoint(surface, id: "a")
            let target = CGPoint(x: down.x + 28, y: down.y + 36)
            surface.mouseDown(with: try self.event(.leftMouseDown, surface: surface, point: down))
            surface.mouseDragged(with: try self.event(.leftMouseDragged, surface: surface, point: target))
            surface.mouseUp(with: try self.event(.leftMouseUp, surface: surface, point: target))
            let saved = graph.layout
            let reopened = TaskGraphModel(defaults: defaults)
            reopened.connect(identity: "isolated-grid", tasks: store.tasks)
            XCTAssertEqual(reopened.layout, saved)
            XCTAssertEqual(reopened.layout.positions["a"], GraphPoint(CGPoint(x: 24, y: 48)))
            for id in ["b", "child", "other"] { XCTAssertEqual(reopened.layout.positions[id], before.positions[id]) }
        }
    }
}
