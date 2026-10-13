import XCTest
import AppKit
@testable import HeroOOSNative

final class ImageDimensionTests: SwiftIntegrationCase {
    @MainActor func testNativeSliderTracksPointerWithoutBlockingAndGroupsGesture() throws {
        let slider = DimensionSliderView(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        slider.minValue = ImageDimensionScale.range.lowerBound; slider.maxValue = ImageDimensionScale.range.upperBound
        var phases: [Bool] = []
        slider.editingChanged = { phases.append($0) }
        func event(_ type: NSEvent.EventType, x: Double) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 12), modifierFlags: [], timestamp: 0,
                                            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        slider.mouseDown(with: try event(.leftMouseDown, x: 0))
        XCTAssertEqual(slider.doubleValue, slider.minValue)
        slider.mouseDragged(with: try event(.leftMouseDragged, x: 110))
        XCTAssertGreaterThan(slider.doubleValue, slider.minValue)
        XCTAssertLessThan(slider.doubleValue, slider.maxValue)
        slider.mouseUp(with: try event(.leftMouseUp, x: 220))
        XCTAssertEqual(slider.doubleValue, slider.maxValue)
        XCTAssertEqual(phases, [true, false])
        slider.isEnabled = false
        slider.mouseDown(with: try event(.leftMouseDown, x: 0))
        XCTAssertEqual(slider.doubleValue, slider.maxValue)
        XCTAssertEqual(phases, [true, false])
    }
    func testSliderScaleRoundTripsAndClamps() {
        for pixels in [40.0, 100, 500, 1920, 8192, 20000] {
            XCTAssertEqual(ImageDimensionScale.pixels(ImageDimensionScale.position(pixels)), pixels, accuracy: 1)
        }
        XCTAssertEqual(ImageDimensionScale.pixels(ImageDimensionScale.position(-10)), 40)
        XCTAssertEqual(ImageDimensionScale.pixels(ImageDimensionScale.position(30000)), 20000)
    }
    @MainActor func testEachAxisPreservesOtherAxisCropAndRotationWithOneUndoPerDrag() async throws {
        let model = CollageStore(api: api, recoverDrafts: false); await model.load()
        let image: JSON = ["id": "image", "kind": "image", "assetFile": "test.png", "naturalWidth": 500, "naturalHeight": 400,
                           "width": 400, "height": 300, "imageWidth": 500, "imageHeight": 400,
                           "imageOffsetX": 20, "imageOffsetY": -10, "rotation": 37, "x": 100, "y": 100]
        var locked = image; locked["id"] = "locked"; locked["locked"] = true
        model.mutateCanvas { $0["items"] = [image, locked] }
        model.selection = ["image", "locked"]
        var saved = await model.save(); XCTAssertTrue(saved)
        let before = model.document, historyCount = model.history.count
        model.beginSizeAdjustment()
        for width in [500.0, 600, 800] { model.resizeSelected("width", value: width) }
        model.endSizeAdjustment()
        let changed = try XCTUnwrap(model.items.first { $0.id == "image" })
        XCTAssertEqual(changed.number("width"), 800)
        XCTAssertEqual(changed.number("imageWidth"), 1000)
        XCTAssertEqual(changed.number("imageOffsetX"), 40)
        for key in ["height", "imageHeight", "imageOffsetY", "rotation", "x", "y"] { XCTAssertEqual(changed[key], image[key]) }
        XCTAssertEqual(model.items.first { $0.id == "locked" }?.number("width"), 400)
        XCTAssertEqual(model.history.count, historyCount + 1)
        model.undo(); XCTAssertEqual(model.document, before)
        model.redo()
        model.selection = ["image", "locked"]
        model.beginSizeAdjustment()
        model.resizeSelected("height", value: 450); model.resizeSelected("height", value: 600)
        model.endSizeAdjustment()
        let final = try XCTUnwrap(model.items.first { $0.id == "image" })
        XCTAssertEqual(final.number("width"), 800); XCTAssertEqual(final.number("height"), 600)
        XCTAssertEqual(final.number("imageHeight"), 800); XCTAssertEqual(final.number("imageOffsetY"), -20)
        try await Task.sleep(for: .seconds(1.2))
        XCTAssertFalse(model.dirty)
        let reopened = CollageStore(api: api, recoverDrafts: false); await reopened.load()
        XCTAssertEqual(reopened.items.first { $0.id == "image" }, final)
        model.resizeSelected("width", value: .nan)
        XCTAssertEqual(model.items.first { $0.id == "image" }, final)
        saved = await model.save(); XCTAssertTrue(saved)
    }
}
