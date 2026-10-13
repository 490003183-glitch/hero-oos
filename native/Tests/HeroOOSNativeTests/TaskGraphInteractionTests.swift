import XCTest
import AppKit
@testable import HeroOOSNative

@MainActor final class TaskGraphInteractionTests: XCTestCase {
    private func fixture(_ body: (TaskGraphSurface, TaskGraphModel, OOSStore) throws -> Void) throws {
        let name = "HeroOOS.graph-interaction.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = OOSStore(api: OOSAPI(base: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)), recoverDrafts: false)
        store.state = ["tasks": [["id": "a", "title": "测试任务", "status": "ready", "background": "保留原始背景"],
                                 ["id": "b", "title": "另一任务", "status": "ready"]]]
        let graph = TaskGraphModel(defaults: defaults); graph.reconcile(store.tasks); graph.showMiniMap = false
        graph.layout.positions = ["a": GraphPoint(.zero), "b": GraphPoint(CGPoint(x: 500, y: 0))]
        graph.layout.offset = GraphPoint(CGPoint(x: 80, y: 80)); graph.needsInitialFit = false
        let surface = TaskGraphSurface(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        surface.graph = graph; surface.store = store
        defer { surface.cancelHoverPreview(); store.stop() }
        try body(surface, graph, store)
    }
    private func event(_ kind: NSEvent.EventType, surface: TaskGraphSurface, point: CGPoint, count: Int = 1,
                       flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: kind, location: surface.convert(surface.screen(point), to: nil),
                                        modifierFlags: flags, timestamp: 1, windowNumber: 0, context: nil,
                                        eventNumber: 0, clickCount: count, pressure: 1))
    }
    private func click(_ surface: TaskGraphSurface, at point: CGPoint, count: Int, flags: NSEvent.ModifierFlags = []) throws {
        surface.mouseDown(with: try event(.leftMouseDown, surface: surface, point: point, count: count, flags: flags))
        surface.mouseUp(with: try event(.leftMouseUp, surface: surface, point: point, count: count, flags: flags))
    }
    func testSingleSelectsAndDoubleRenamesTitleAtAllSemanticZoomsWithoutOpeningDetails() throws {
        try fixture { surface, graph, store in
            let original = store.state
            var opened: [String?] = []; surface.openDetail = { opened.append($0) }
            for zoom in [0.08, 0.3, 0.45, 1.0, 2.0] {
                graph.layout.zoom = zoom; graph.selection = []; opened = []
                let rect = surface.rect("a")
                let point = CGPoint(x: rect.midX, y: zoom <= TaskGraphGeometry.titleOnlyZoom ? rect.midY : rect.minY + 44)
                try click(surface, at: point, count: 1)
                XCTAssertEqual(graph.selection, ["a"]); XCTAssertTrue(opened.isEmpty)
                try click(surface, at: point, count: 2)
                XCTAssertTrue(opened.isEmpty)
                let editor = try XCTUnwrap(surface.subviews.compactMap { $0 as? NSTextField }.first)
                XCTAssertEqual(editor.stringValue, "测试任务")
                XCTAssertGreaterThanOrEqual(graph.layout.zoom, 1, "Overview titles zoom in for readable editing.")
                XCTAssertTrue(surface.control(editor, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
                XCTAssertFalse(surface.subviews.contains { $0 is NSTextField })
            }
            XCTAssertEqual(store.state, original); XCTAssertTrue(store.pending.isEmpty)
        }
    }
    func testBodySingleDoesNotReplaceOpenDetailAndDoubleDoes() throws {
        try fixture { surface, graph, _ in
            var detail: String? = "b"; surface.openDetail = { detail = $0 }
            let point = CGPoint(x: 130, y: 82)
            try click(surface, at: point, count: 1)
            XCTAssertEqual(graph.selection, ["a"]); XCTAssertEqual(detail, "b")
            try click(surface, at: point, count: 2)
            XCTAssertEqual(detail, "a")
        }
    }
    func testMultiSelectionAndModifiedDoubleClickNeverOpenDetails() throws {
        try fixture { surface, graph, _ in
            var opened = 0; surface.openDetail = { _ in opened += 1 }
            graph.selection = ["b"]
            try click(surface, at: CGPoint(x: 130, y: 44), count: 1, flags: .shift)
            XCTAssertEqual(graph.selection, ["a", "b"])
            try click(surface, at: CGPoint(x: 130, y: 44), count: 2, flags: .shift)
            XCTAssertEqual(opened, 0)
            XCTAssertFalse(surface.subviews.contains { $0 is NSTextField })
            graph.selection = ["a", "b"]
            try click(surface, at: CGPoint(x: 130, y: 82), count: 2)
            XCTAssertEqual(graph.selection, ["a"]); XCTAssertEqual(opened, 1)
        }
    }
    func testDraggingEvenOnSecondClickDoesNotOpenDetailOrModifyTaskFields() throws {
        try fixture { surface, graph, store in
            let source = store.state
            var opened = 0; surface.openDetail = { _ in opened += 1 }
            surface.mouseDown(with: try event(.leftMouseDown, surface: surface, point: CGPoint(x: 130, y: 44), count: 2))
            surface.mouseDragged(with: try event(.leftMouseDragged, surface: surface, point: CGPoint(x: 155, y: 69), count: 2))
            surface.mouseUp(with: try event(.leftMouseUp, surface: surface, point: CGPoint(x: 155, y: 69), count: 2))
            XCTAssertEqual(opened, 0); XCTAssertEqual(graph.layout.positions["a"]?.x, 25)
            XCTAssertEqual(graph.layout.positions["a"]?.y, 25)
            XCTAssertFalse(surface.subviews.contains { $0 is NSTextField })
            XCTAssertEqual(store.state, source); XCTAssertTrue(store.pending.isEmpty)
        }
    }
    func testTitleBoundaryDriftKeepsRenameAndEditorReceivesFurtherClicks() throws {
        try fixture { surface, _, store in
            let original = store.state
            var opened = 0; surface.openDetail = { _ in opened += 1 }
            surface.mouseDown(with: try event(.leftMouseDown, surface: surface, point: CGPoint(x: 130, y: 72), count: 2))
            surface.mouseUp(with: try event(.leftMouseUp, surface: surface, point: CGPoint(x: 130, y: 75), count: 2))
            let editor = try XCTUnwrap(surface.subviews.compactMap { $0 as? NSTextField }.first)
            // NSView hitTest expects coordinates in its superview, not its own
            // flipped canvas coordinate system.
            let target = surface.hitTest(surface.convert(CGPoint(x: editor.frame.midX, y: editor.frame.midY), to: surface.superview))
            XCTAssertTrue(target === editor || target?.isDescendant(of: editor) == true)
            XCTAssertEqual(opened, 0)
            XCTAssertTrue(surface.control(editor, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
            XCTAssertEqual(store.state, original); XCTAssertTrue(store.pending.isEmpty)
        }
    }
    func testHoverWaitsHalfASecondAndMovingWithinCardDoesNotRestartDelay() {
        var dwell = TaskGraphHoverDwell()
        XCTAssertTrue(dwell.update("a", at: 10))
        XCTAssertNil(dwell.ready(at: 10.499))
        XCTAssertFalse(dwell.update("a", at: 10.4))
        XCTAssertEqual(dwell.ready(at: 10.5), "a")
    }
    func testHoverSwitchExitAndInteractionCancelPendingPreview() {
        var dwell = TaskGraphHoverDwell()
        dwell.update("a", at: 10); dwell.update("b", at: 10.4)
        XCTAssertNil(dwell.ready(at: 10.8)); XCTAssertEqual(dwell.ready(at: 10.91), "b")
        dwell.update(nil, at: 11); XCTAssertNil(dwell.ready(at: 100))
        dwell.update("a", at: 101); dwell.cancel()
        XCTAssertNil(dwell.candidate); XCTAssertNil(dwell.ready(at: 200))
        dwell.update("a", at: 201); XCTAssertNil(dwell.ready(at: 200.9))
        XCTAssertEqual(dwell.ready(at: 201.5), "a")
    }
}
