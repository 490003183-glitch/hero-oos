import XCTest
import SwiftUI
import AppKit
@testable import HeroOOSNative

@MainActor final class TaskGraphWindowInteractionTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func fixture(_ body: (NSWindow, TaskGraphSurface, TaskGraphModel, OOSStore) async throws -> Void) async throws {
        _ = NSApplication.shared
        let identity = "HeroOOS.graph-window-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: identity))
        let store = OOSStore(api: OOSAPI(base: FileManager.default.temporaryDirectory.appendingPathComponent(identity)), recoverDrafts: false)
        store.state = ["tasks": [["id": "a", "title": "标题双击编辑测试", "status": "ready"]]]
        let graph = TaskGraphModel(defaults: defaults); graph.reconcile(store.tasks)
        graph.showMiniMap = false; graph.needsInitialFit = false
        graph.layout.positions = ["a": GraphPoint(.zero)]
        graph.layout.offset = GraphPoint(CGPoint(x: 80, y: 80))
        let host = NSHostingView(rootView: TaskGraphView(store: store, graph: graph, selected: .constant(nil), search: "")
            .frame(width: 900, height: 600))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; host.layoutSubtreeIfNeeded()
        let surface = try XCTUnwrap(descendants(host).compactMap { $0 as? TaskGraphSurface }.first)
        defer {
            // Cancel, never commit a test editor into task storage.
            if let editor = surface.subviews.compactMap({ $0 as? NSTextField }).first {
                _ = surface.control(editor, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
            }
            window.contentView = nil; surface.cancelHoverPreview(); store.stop()
            defaults.removePersistentDomain(forName: identity)
        }
        try await body(window, surface, graph, store)
    }

    private func click(_ surface: TaskGraphSurface, at point: CGPoint, count: Int) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: surface.convert(surface.screen(point), to: nil),
                modifierFlags: [], timestamp: 1, windowNumber: surface.window?.windowNumber ?? 0,
                context: nil, eventNumber: 0, clickCount: count, pressure: 1))
            if type == .leftMouseDown { surface.mouseDown(with: event) } else { surface.mouseUp(with: event) }
        }
    }

    private func assertEditor(_ surface: TaskGraphSurface, window: NSWindow, file: StaticString = #filePath, line: UInt = #line) throws {
        let editor = try XCTUnwrap(surface.subviews.compactMap { $0 as? NSTextField }.first, file: file, line: line)
        XCTAssertEqual(editor.stringValue, "标题双击编辑测试", file: file, line: line)
        let fieldEditor = try XCTUnwrap(editor.currentEditor(), file: file, line: line)
        XCTAssertTrue(window.firstResponder === fieldEditor, file: file, line: line)
        XCTAssertEqual((fieldEditor as? NSTextView)?.selectedRange(), NSRange(location: 0, length: editor.stringValue.utf16.count), file: file, line: line)
    }

    func testDirectBeginTitleKeepsFieldEditorAfterHostingUpdate() async throws {
        try await fixture { window, surface, graph, store in
            let original = store.state
            surface.beginTitle(try XCTUnwrap(store.task("a")))
            try assertEditor(surface, window: window)
            graph.objectWillChange.send()
            await Task.yield(); try await Task.sleep(for: .milliseconds(30))
            window.contentView?.layoutSubtreeIfNeeded()
            try assertEditor(surface, window: window)
            XCTAssertEqual(store.state, original); XCTAssertTrue(store.pending.isEmpty)
        }
    }

    func testTitleDoubleClickKeepsFieldEditorAfterSelectionPublishes() async throws {
        try await fixture { window, surface, graph, store in
            let original = store.state
            try click(surface, at: CGPoint(x: 130, y: 44), count: 1)
            await Task.yield(); try await Task.sleep(for: .milliseconds(20))
            try click(surface, at: CGPoint(x: 130, y: 44), count: 2)
            try assertEditor(surface, window: window)
            await Task.yield(); try await Task.sleep(for: .milliseconds(100))
            window.contentView?.layoutSubtreeIfNeeded()
            try assertEditor(surface, window: window)
            XCTAssertEqual(graph.selection, ["a"])
            XCTAssertEqual(store.state, original); XCTAssertTrue(store.pending.isEmpty)
        }
    }

    func testTitleCanBeRenamedAgainAfterLosingAndRegainingFirstResponder() async throws {
        try await fixture { window, surface, _, store in
            let original = store.state
            try click(surface, at: CGPoint(x: 130, y: 44), count: 2)
            try assertEditor(surface, window: window)
            XCTAssertTrue(window.makeFirstResponder(nil))
            await Task.yield()
            XCTAssertFalse(surface.subviews.contains { $0 is NSTextField })
            XCTAssertTrue(window.makeFirstResponder(surface))
            try click(surface, at: CGPoint(x: 130, y: 44), count: 1)
            try click(surface, at: CGPoint(x: 130, y: 44), count: 2)
            await Task.yield(); try await Task.sleep(for: .milliseconds(30))
            try assertEditor(surface, window: window)
            XCTAssertEqual(store.state, original); XCTAssertTrue(store.pending.isEmpty)
        }
    }
}
