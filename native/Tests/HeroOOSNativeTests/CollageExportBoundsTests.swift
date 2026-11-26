import XCTest
import AppKit
@testable import HeroOOSNative

final class CollageExportBoundsTests: XCTestCase {
    func testSelectionIncludesGapsRotationAndWholePixelRounding() throws {
        let first = Record(["id": "a", "kind": "image", "x": 10.2, "y": 20.2, "width": 100, "height": 40, "rotation": 0])
        let second = Record(["id": "b", "kind": "image", "x": 150.4, "y": 70.4, "width": 40, "height": 20, "rotation": 90])
        let bounds = try XCTUnwrap(CanvasGeometry.exportBounds([first, second]))
        XCTAssertEqual(bounds, CGRect(x: 10, y: 20, width: 171, height: 81))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width), pixelsHigh: Int(bounds.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        XCTAssertEqual(bitmap.pixelsWide, 171); XCTAssertEqual(bitmap.pixelsHigh, 81)
    }

    func testTextAndImagesUseTheSameExportBounds() throws {
        let image = Record(["id": "a", "kind": "image", "x": 0, "y": 0, "width": 100, "height": 50])
        let text = Record(["id": "b", "kind": "text", "x": 125, "y": 75, "width": 60, "height": 40])
        XCTAssertEqual(try XCTUnwrap(CanvasGeometry.exportBounds([image, text])).size, CGSize(width: 185, height: 115))
        XCTAssertNil(CanvasGeometry.exportBounds([]))
    }
}
