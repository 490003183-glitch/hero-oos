import XCTest
import AppKit
@testable import HeroOOSNative

@MainActor final class TaskDetailInteractionTests: XCTestCase {
    func testBlankCanvasDismissesButTaskAndInspectorRegionsDoNot() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let inspector = DetailProtectedView(frame: NSRect(x: 0, y: 0, width: 1000, height: 300))
        let task = DetailProtectedView(frame: NSRect(x: 20, y: 550, width: 260, height: 80))
        root.addSubview(inspector); root.addSubview(task)
        XCTAssertFalse(DetailClickPolicy.isBlank(at: NSPoint(x: 100, y: 100), in: root, hit: root))
        XCTAssertFalse(DetailClickPolicy.isBlank(at: NSPoint(x: 100, y: 580), in: root, hit: root))
        XCTAssertTrue(DetailClickPolicy.isBlank(at: NSPoint(x: 500, y: 450), in: root, hit: root))
    }
    func testNativeControlsAndTextEditingDoNotDismiss() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        for control in [NSButton(), NSTextField(), NSSlider(), NSTextView(), NSScroller()] as [NSView] {
            root.addSubview(control)
            XCTAssertFalse(DetailClickPolicy.isBlank(at: .zero, in: root, hit: control))
            control.removeFromSuperview()
        }
    }
    func testHiddenTaskTargetsDoNotBlockBlankClicks() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let task = DetailProtectedView(frame: root.bounds); root.addSubview(task)
        task.isHidden = true
        XCTAssertTrue(DetailClickPolicy.isBlank(at: NSPoint(x: 100, y: 100), in: root, hit: root))
    }
    func testNativeTableRowsAreProtectedButEmptySpaceDismisses() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let table = NSTableView(frame: root.bounds), dataSource = DetailTestRows()
        table.addTableColumn(NSTableColumn(identifier: .init("title")))
        table.dataSource = dataSource; table.rowHeight = 30
        root.addSubview(table); table.reloadData()
        let rowPoint = root.convert(NSPoint(x: 10, y: 10), from: table)
        let blankPoint = root.convert(NSPoint(x: 10, y: 350), from: table)
        XCTAssertFalse(DetailClickPolicy.isBlank(at: rowPoint, in: root, hit: table))
        XCTAssertTrue(DetailClickPolicy.isBlank(at: blankPoint, in: root, hit: table))
    }
    func testSplitDividerDragDoesNotDismissDetails() {
        for vertical in [false, true] {
            let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 800))
            split.isVertical = vertical
            split.addArrangedSubview(NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300)))
            split.addArrangedSubview(NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300)))
            split.adjustSubviews()
            let edge = split.arrangedSubviews[0].frame
            let point = vertical ? NSPoint(x: edge.maxX, y: 100) : NSPoint(x: 100, y: edge.maxY)
            XCTAssertFalse(DetailClickPolicy.isBlank(at: point, in: split, hit: split))
            XCTAssertTrue(DetailClickPolicy.isBlank(at: NSPoint(x: 100, y: 100), in: split, hit: split))
        }
    }
}

private final class DetailTestRows: NSObject, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { 2 }
}

final class TaskDetailSaveTests: SwiftIntegrationCase {
    @MainActor func testDismissingSelectionKeepsPendingAutosave() async throws {
        let store = OOSStore(api: api, recoverDrafts: false); await store.refresh()
        let created = await store.createTask(title: "底部详情保存测试", space: .personal)
        let id = try XCTUnwrap(created)
        var selection: String? = id
        store.edit(id, "note", "收起面板后仍需保留")
        selection = nil
        XCTAssertNil(selection)
        try await Task.sleep(for: .seconds(1.2))
        XCTAssertTrue(store.pending.isEmpty)
        let reopened = OOSStore(api: api, recoverDrafts: false); await reopened.refresh()
        XCTAssertEqual(reopened.task(id)?.text("note"), "收起面板后仍需保留")
    }
}
