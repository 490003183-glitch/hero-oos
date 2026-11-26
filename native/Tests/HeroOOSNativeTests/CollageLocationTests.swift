import XCTest
@testable import OOSCore
@testable import HeroOOSNative

final class CollageLocationTests: SwiftIntegrationCase {
    func testMoveRetainsOriginalAndReopensAfterRuntimeRecreation() throws {
        let bytes = Data([137, 80, 78, 71, 1, 2, 3])
        let asset = try runtime.importAsset(bytes, name: "a.png", contentType: "image/png")
        let before = try runtime.readCollages()
        var next = before
        var canvas = next["canvases"].array[0]
        canvas["items"] = [["id": "image-1", "kind": "image", "assetFile": asset["assetFile"]]]
        next["canvases"] = .array([canvas])
        let original = try runtime.saveCollages(next, expected: before)
        let target = root.appendingPathComponent("chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try runtime.setCollageDirectory(target)
        let reopened = StateRuntime(root: root)
        XCTAssertEqual(try reopened.readCollages(), original)
        XCTAssertEqual(try Data(contentsOf: reopened.assetURL(asset["assetFile"].string)), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("data/collages.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("data/collage-assets/" + asset["assetFile"].string).path))
        try FileManager.default.moveItem(at: target, to: root.appendingPathComponent("offline"))
        XCTAssertThrowsError(try reopened.readCollages())
        XCTAssertThrowsError(try reopened.saveCollages(original, expected: original))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        try reopened.setCollageDirectory(root.appendingPathComponent("offline"), useExisting: true)
        XCTAssertEqual(try reopened.readCollages(), original)
    }

    func testExistingFilesAreNotOverwritten() throws {
        let target = root.appendingPathComponent("occupied", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let existing = Data("original".utf8)
        let document = target.appendingPathComponent("collages.json")
        try existing.write(to: document)
        XCTAssertThrowsError(try runtime.setCollageDirectory(target))
        XCTAssertEqual(try Data(contentsOf: document), existing)
        XCTAssertEqual(try runtime.collageDirectory(), runtime.dataDirectory)
    }

    func testDeleteOldFilesRefusesWhenEitherCopyChanged() throws {
        let old = try runtime.readCollages()
        _ = try runtime.saveCollages(old, expected: old)
        let target = root.appendingPathComponent("chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let move = try XCTUnwrap(runtime.setCollageDirectory(target))
        let sourceDocument = move.source.appendingPathComponent("collages.json")
        try Data("changed".utf8).write(to: sourceDocument)
        XCTAssertThrowsError(try runtime.trashOldCollage(move))
        XCTAssertEqual(try Data(contentsOf: sourceDocument), Data("changed".utf8))
        XCTAssertEqual(try runtime.readCollages(), old)
    }

    func testDeleteOldFilesRefusesWhenNewCopyChanged() throws {
        let old = try runtime.readCollages()
        _ = try runtime.saveCollages(old, expected: old)
        let target = root.appendingPathComponent("chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let move = try XCTUnwrap(runtime.setCollageDirectory(target))
        var changed = old; changed["future"] = "changed"
        _ = try runtime.saveCollages(changed, expected: old)
        XCTAssertThrowsError(try runtime.trashOldCollage(move))
        XCTAssertTrue(FileManager.default.fileExists(atPath: move.source.appendingPathComponent("collages.json").path))
        XCTAssertEqual(try runtime.readCollages(), changed)
    }
}
