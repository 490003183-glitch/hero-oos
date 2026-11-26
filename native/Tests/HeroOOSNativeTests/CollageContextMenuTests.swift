import XCTest
import AppKit
@testable import HeroOOSNative

@MainActor final class CollageContextMenuTests: XCTestCase {
    private func fixture(locked: Bool = false) -> (CollageStore, CollageSurface) {
        let model = CollageStore(api: OOSAPI(base: URL(fileURLWithPath: "/test-only/context-menu")), recoverDrafts: false)
        model.document = ["activeCanvasId": "one", "canvases": [["id": "one", "name": "one", "items": [
            ["id": "back", "kind": "image", "assetFile": "back.png", "x": 0, "y": 0, "width": 100, "height": 100, "z": 1],
            ["id": "front", "kind": "image", "assetFile": "front.png", "x": 10, "y": 10, "width": 80, "height": 80, "z": 2, "locked": .bool(locked)],
            ["id": "text", "kind": "text", "x": 150, "y": 0, "width": 50, "height": 50, "z": 3]
        ]]]]
        let surface = CollageSurface(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        surface.model = model
        return (model, surface)
    }
    private func event(_ surface: CollageSurface, _ x: CGFloat, _ y: CGFloat) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: surface.convert(NSPoint(x: x, y: y), to: nil),
                                        modifierFlags: [], timestamp: 0, windowNumber: 0,
                                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    func testRightClickTargetsFrontImageAndProvidesActions() throws {
        let (model, surface) = fixture()
        model.selection = ["back"]
        let menu = try XCTUnwrap(surface.menu(for: event(surface, 75, 75)))
        XCTAssertEqual(model.selection, ["front"])
        for title in ["在 Finder 中显示原图文件", "复制图片", "在画布中创建副本", "旋转 90 度", "置顶", "置底", "锁定", "从画布移除"] {
            XCTAssertNotNil(menu.item(withTitle: title))
        }
        XCTAssertTrue(try XCTUnwrap(menu.item(withTitle: "从画布移除")).isEnabled)
    }
    func testLockedImageOffersUnlockAndDisablesEdits() throws {
        let (model, surface) = fixture(locked: true)
        let menu = try XCTUnwrap(surface.menu(for: event(surface, 75, 75)))
        XCTAssertEqual(model.selection, ["front"])
        XCTAssertNotNil(menu.item(withTitle: "解除锁定"))
        XCTAssertTrue(try XCTUnwrap(menu.item(withTitle: "在 Finder 中显示原图文件")).isEnabled)
        XCTAssertFalse(try XCTUnwrap(menu.item(withTitle: "旋转 90 度")).isEnabled)
        XCTAssertFalse(try XCTUnwrap(menu.item(withTitle: "从画布移除")).isEnabled)
    }
    func testBlankAndTextDoNotChangeSelectionOrOpenImageMenu() throws {
        let (model, surface) = fixture()
        model.selection = ["back"]
        XCTAssertNil(surface.menu(for: try event(surface, 400, 400)))
        XCTAssertNil(surface.menu(for: try event(surface, 210, 60)))
        XCTAssertEqual(model.selection, ["back"])
    }
}
