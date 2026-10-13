import XCTest
import AppKit
@testable import HeroOOSNative

private func cropImage() -> Record {
    Record(["id": "image", "kind": "image", "assetFile": "test.png", "x": 1000, "y": 1000,
            "width": 400, "height": 300, "imageWidth": 400, "imageHeight": 300,
            "naturalWidth": 400, "naturalHeight": 300, "imageOffsetX": 0, "imageOffsetY": 0, "rotation": 0])
}

final class CropTests: XCTestCase {
    func testImageEdgeHandlesCropAndCornersKeepAspect() {
        let original = cropImage()
        for (handle, delta, edge) in [(1, CGSize(width: 0, height: 60), CropEdge.top), (3, CGSize(width: -80, height: 0), .right), (5, CGSize(width: 0, height: -60), .bottom), (7, CGSize(width: 80, height: 0), .left)] {
            let cropped = CanvasTransform.draggingHandle(handle, delta: delta, item: original)
            XCTAssertEqual(ImageCrop.fraction(edge, item: cropped), 0.2, accuracy: 0.00001)
            XCTAssertEqual(cropped.number("imageWidth"), 400)
            XCTAssertEqual(cropped.number("imageHeight"), 300)
        }
        for handle in [0, 2, 4, 6] {
            let resized = CanvasTransform.draggingHandle(handle, delta: CGSize(width: 100, height: 10), item: original)
            XCTAssertEqual(resized.number("width") / resized.number("height"), 4.0 / 3, accuracy: 0.00001)
        }
    }
    func testRotatedHandleCropAndLegacyImageDimensions() {
        var original = cropImage(); original["x"] = 0; original["y"] = 0; original["rotation"] = 90
        original.fields.removeValue(forKey: "imageWidth"); original.fields.removeValue(forKey: "imageHeight")
        let before = CanvasGeometry.world(CGPoint(x: 200, y: 150), item: original)
        let cropped = CanvasTransform.draggingHandle(7, delta: CGSize(width: 0, height: 80), item: original)
        XCTAssertEqual(cropped.number("width"), 320, accuracy: 0.00001)
        XCTAssertEqual(cropped.number("imageWidth"), 400)
        let image = ImageCrop.imageRect(cropped)
        let after = CanvasGeometry.world(CGPoint(x: image.midX, y: image.midY), item: cropped)
        XCTAssertEqual(before.x, after.x, accuracy: 0.00001); XCTAssertEqual(before.y, after.y, accuracy: 0.00001)
        let restored = CanvasTransform.draggingHandle(7, delta: CGSize(width: 0, height: -80), item: cropped)
        XCTAssertEqual(restored.number("width"), 400, accuracy: 0.00001)
    }
    func testEachEdgeClipsWithoutResizingSourceImage() {
        let original = cropImage()
        for edge in CropEdge.allCases {
            XCTAssertEqual(ImageCrop.fraction(edge, item: original).sign, .plus)
            let cropped = ImageCrop.applying(edge, fraction: 0.2, to: original)
            XCTAssertEqual(ImageCrop.fraction(edge, item: cropped), 0.2, accuracy: 0.00001)
            XCTAssertEqual(cropped.number("imageWidth"), 400)
            XCTAssertEqual(cropped.number("imageHeight"), 300)
            for other in CropEdge.allCases where other != edge { XCTAssertEqual(ImageCrop.fraction(other, item: cropped), 0, accuracy: 0.00001) }
            XCTAssertEqual(cropped.number("width"), [.left, .right].contains(edge) ? 320 : 400)
            XCTAssertEqual(cropped.number("height"), [.top, .bottom].contains(edge) ? 240 : 300)
        }
    }
    func testRotatedImageStaysFixedAndAllEdgesAreReversible() {
        var original = cropImage(); original["rotation"] = 37
        let initialCenter = CanvasGeometry.world(CGPoint(x: 200, y: 150), item: original)
        var cropped = original
        for edge in CropEdge.allCases {
            cropped = ImageCrop.applying(edge, fraction: 0.15, to: cropped)
            let image = ImageCrop.imageRect(cropped)
            let center = CanvasGeometry.world(CGPoint(x: image.midX, y: image.midY), item: cropped)
            XCTAssertEqual(center.x, initialCenter.x, accuracy: 0.00001)
            XCTAssertEqual(center.y, initialCenter.y, accuracy: 0.00001)
        }
        for edge in CropEdge.allCases { cropped = ImageCrop.applying(edge, fraction: 0, to: cropped) }
        for key in ["x", "y", "width", "height", "imageWidth", "imageHeight", "imageOffsetX", "imageOffsetY", "rotation"] {
            XCTAssertEqual(cropped.number(key), original.number(key), accuracy: 0.00001, key)
        }
    }
    func testExistingCropOffsetsDetermineSliderValues() {
        var item = cropImage()
        item["width"] = 280; item["height"] = 210
        item["imageOffsetX"] = 20; item["imageOffsetY"] = -15
        XCTAssertEqual(ImageCrop.fraction(.left, item: item), 0.10, accuracy: 0.00001)
        XCTAssertEqual(ImageCrop.fraction(.right, item: item), 0.20, accuracy: 0.00001)
        XCTAssertEqual(ImageCrop.fraction(.top, item: item), 0.20, accuracy: 0.00001)
        XCTAssertEqual(ImageCrop.fraction(.bottom, item: item), 0.10, accuracy: 0.00001)
    }
    func testOpposingEdgesNeverRemoveWholeImageAndInvalidInputIsIgnored() {
        var item = cropImage()
        for edge in CropEdge.allCases { item = ImageCrop.applying(edge, fraction: 1, to: item) }
        XCTAssertEqual(item.number("width"), 40)
        XCTAssertEqual(item.number("height"), 40)
        XCTAssertEqual(ImageCrop.applying(.top, fraction: .nan, to: item), item)
        item["locked"] = true
        XCTAssertEqual(ImageCrop.applying(.left, fraction: 0, to: item), item)
    }
    @MainActor func testCropPreviewPixelsMatchClippedSource() throws {
        let source = NSImage(size: NSSize(width: 400, height: 300), flipped: true) { _ in
            NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 200, height: 300).fill()
            NSColor.blue.setFill(); NSRect(x: 200, y: 0, width: 200, height: 300).fill()
            return true
        }
        var item = ImageCrop.applying(.left, fraction: 0.5, to: cropImage())
        item["x"] = 0; item["y"] = 0
        let surface = CollageSurface()
        let rendered = NSImage(size: NSSize(width: 200, height: 300), flipped: true) { _ in
            surface.drawItem(item, image: source); return true
        }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(rendered.tiffRepresentation)))
        let color = try XCTUnwrap(bitmap.colorAt(x: 100, y: 150)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(color.blueComponent, 0.9)
        XCTAssertLessThan(color.redComponent, 0.1)
    }
}

final class CropIntegrationTests: SwiftIntegrationCase {
    @MainActor func testSidebarWidthOnlyStretchesHorizontally() async throws {
        let model = CollageStore(api: api, recoverDrafts: false); await model.load()
        model.mutateCanvas { $0["items"] = .array([cropImage().json]) }
        model.selection = ["image"]
        model.updateSelected("width", 600)
        let item = try XCTUnwrap(model.items.first)
        XCTAssertEqual(item.number("width"), 600); XCTAssertEqual(item.number("imageWidth"), 600)
        XCTAssertEqual(item.number("height"), 300); XCTAssertEqual(item.number("imageHeight"), 300)
        let saved = await model.save(); XCTAssertTrue(saved)
    }
    @MainActor func testSliderGestureIsOneUndoAndAutosavesAcrossReopen() async throws {
        let model = CollageStore(api: api, recoverDrafts: false); await model.load()
        var locked = cropImage(); locked["id"] = "locked"; locked["locked"] = true
        let text = Record(["id": "text", "kind": "text", "text": "保留文字"])
        model.mutateCanvas { $0["items"] = .array([cropImage().json, locked.json, text.json]) }
        let initialSaved = await model.save(); XCTAssertTrue(initialSaved)
        model.selection = ["image", "locked", "text"]
        let before = model.document, count = model.history.count
        model.beginCropAdjustment()
        for fraction in [0.1, 0.2, 0.25] { model.cropSelected(.left, fraction: fraction) }
        model.endCropAdjustment()
        XCTAssertEqual(model.history.count, count + 1)
        XCTAssertEqual(model.items.first { $0.id == "locked" }?.number("width"), 400)
        XCTAssertEqual(model.items.first { $0.id == "text" }?.text("text"), "保留文字")
        try await Task.sleep(for: .seconds(1.2))
        XCTAssertFalse(model.dirty)
        let reopened = CollageStore(api: api, recoverDrafts: false); await reopened.load()
        let item = try XCTUnwrap(reopened.items.first { $0.id == "image" })
        XCTAssertEqual(ImageCrop.fraction(.left, item: item), 0.25, accuracy: 0.00001)
        model.undo(); XCTAssertEqual(model.document, before)
        model.redo()
        XCTAssertEqual(ImageCrop.fraction(.left, item: try XCTUnwrap(model.items.first { $0.id == "image" })), 0.25, accuracy: 0.00001)
        let saved = await model.save(); XCTAssertTrue(saved)
    }
}
