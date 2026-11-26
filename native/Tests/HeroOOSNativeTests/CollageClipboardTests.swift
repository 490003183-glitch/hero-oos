import XCTest
import AppKit
@testable import HeroOOSNative

@MainActor final class CollageClipboardTests: XCTestCase {
    private let image = Record(["id": "image-1", "kind": "image", "assetFile": "image-1.png"])
    private let text = Record(["id": "text-1", "kind": "text", "text": "hello"])

    private func sampleImage() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.setColor(.red, atX: 0, y: 0)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func testSingleImageIncludesStandardImagesAndCanvasData() async throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let sample = try sampleImage()
        let success = await CollageClipboard.copy([image], to: board) { _ in sample }
        XCTAssertTrue(success)
        XCTAssertEqual(try JSONDecoder().decode([Record].self, from: XCTUnwrap(board.data(forType: CollageClipboard.itemsType))), [image])
        XCTAssertNotNil(NSImage(data: try XCTUnwrap(board.data(forType: .png))))
        XCTAssertNotNil(NSImage(data: try XCTUnwrap(board.data(forType: .tiff))))
    }

    func testMultipleItemsKeepExistingCanvasCopy() async throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let success = await CollageClipboard.copy([image, text], to: board) { _ in XCTFail("Multiple items must not load an image"); return Data() }
        XCTAssertTrue(success)
        XCTAssertEqual(try JSONDecoder().decode([Record].self, from: XCTUnwrap(board.data(forType: CollageClipboard.itemsType))), [image, text])
        XCTAssertNil(board.data(forType: .png))
    }

    func testNewClipboardContentIsNotOverwrittenByDelayedImage() async throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let sample = try sampleImage()
        let success = await CollageClipboard.copy([image], to: board) { _ in
            board.clearContents(); board.setString("new clipboard content", forType: .string)
            return sample
        }
        XCTAssertTrue(success)
        XCTAssertEqual(board.string(forType: .string), "new clipboard content")
        XCTAssertNil(board.data(forType: .png))
    }

    func testUnreadableImageRetainsCanvasData() async throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let success = await CollageClipboard.copy([image], to: board) { _ in Data() }
        XCTAssertFalse(success)
        XCTAssertEqual(try JSONDecoder().decode([Record].self, from: XCTUnwrap(board.data(forType: CollageClipboard.itemsType))), [image])
    }
}
