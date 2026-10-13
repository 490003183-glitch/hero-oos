import XCTest
@testable import OOSCore

final class LocalWorkspaceImportTests: XCTestCase {
    private var directory: URL!
    private var source: StateRuntime!
    private var destination: StateRuntime!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("hero-local-import-test-" + UUID().uuidString, isDirectory: true)
        source = StateRuntime(root: directory.appendingPathComponent("original", isDirectory: true))
        destination = StateRuntime(root: directory.appendingPathComponent("account", isDirectory: true))
        try source.initializeIfNeeded(); try destination.initializeIfNeeded()
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func installTasks(_ tasks: JSON, in runtime: StateRuntime) throws {
        let existing = try runtime.cloudState(); var next = existing
        next["tasks"] = tasks
        _ = try runtime.applyCloudState(next, expected: existing)
    }
    private func installCollage(in runtime: StateRuntime, bytes: Data = Data("image fixture".utf8), assetName: String? = nil) throws -> String {
        let name: String
        if let assetName {
            try FileManager.default.createDirectory(at: runtime.file("collage-assets"), withIntermediateDirectories: true)
            try bytes.write(to: runtime.assetURL(assetName), options: .withoutOverwriting)
            name = assetName
        } else { name = try runtime.importAsset(bytes, name: "source.png", contentType: "image/png")["assetFile"].string }
        let before = try runtime.readCollages()
        let doc: JSON = ["version": 1, "activeCanvasId": "canvas-one", "canvases": [["id": "canvas-one", "name": "Local collage", "background": "#000000", "items": [
            ["id": "image-one", "kind": "image", "assetFile": .string(name), "width": 100, "height": 80,
             "naturalWidth": 200, "naturalHeight": 160, "x": 22, "y": 33, "rotation": 12, "z": 1],
            ["id": "text-one", "kind": "text", "text": "Only on device", "width": 90, "height": 50, "x": 9, "y": 4, "z": 2]
        ]]]]
        _ = try runtime.saveCollages(doc, expected: before)
        return name
    }
    private func assertNoMarker() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.file(LocalWorkspaceImport.markerName).path))
    }

    func testLocalOnlyCopyPreservesPrivateProvenanceSourceAndIdempotence() throws {
        try installTasks([["id": "work", "title": "Work", "status": "ready", "taskSpace": "work", "updatedAt": "2026-09-01T01:00:00Z", "sourceRecord": ["keep": "provenance"]],
                          ["id": "private", "title": "Private", "status": "completed", "taskSpace": "personal"]], in: source)
        let name = try installCollage(in: source)
        let originalState = try Data(contentsOf: source.file("state.json"))
        let originalCollages = try Data(contentsOf: source.file("collages.json"))
        let originalAsset = try Data(contentsOf: source.assetURL(name))
        let report = try LocalWorkspaceImport.perform(source: source, destination: destination, expectedVersion: 1)
        XCTAssertEqual(report["counts"]["tasks"], 2)
        XCTAssertEqual(report["counts"]["privateTasks"], 1)
        XCTAssertEqual(report["counts"]["canvases"], 1)
        XCTAssertEqual(report["counts"]["images"], 1)
        XCTAssertEqual(report["counts"]["texts"], 1)
        let copied = try destination.readState()
        XCTAssertEqual(copied["tasks"], try source.readState()["tasks"])
        XCTAssertEqual(copied["tasks"].array.first?["sourceRecord"], ["keep": "provenance"])
        XCTAssertEqual(try destination.readCollages(), try source.readCollages())
        XCTAssertEqual(try Data(contentsOf: destination.assetURL(name)), originalAsset)
        XCTAssertEqual(try Data(contentsOf: source.file("state.json")), originalState)
        XCTAssertEqual(try Data(contentsOf: source.file("collages.json")), originalCollages)
        XCTAssertEqual(try Data(contentsOf: source.assetURL(name)), originalAsset)
        let repeated = try LocalWorkspaceImport.perform(source: source, destination: destination, expectedVersion: copied["meta"]["version"].number)
        XCTAssertEqual(repeated["duplicate"], true)
        XCTAssertEqual(try destination.readState(), copied)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.file("local-import-history").path).count, 1)
        let marker = try destination.readJSON(destination.file(LocalWorkspaceImport.markerName))
        XCTAssertEqual(Set(marker.object.keys), ["source", "counts"])
        XCTAssertEqual(try destination.readJSON(URL(fileURLWithPath: report["backup"].string).appendingPathComponent("state.json"))["tasks"], [])
    }

    func testTaskCollisionStopsBeforeCopyingAssetsOrChangingDestination() throws {
        try installTasks([["id": "same", "title": "original", "status": "ready"]], in: source)
        try installTasks([["id": "same", "title": "destination", "status": "ready"]], in: destination)
        let name = try installCollage(in: source), before = try destination.readState()
        XCTAssertThrowsError(try LocalWorkspaceImport.perform(source: source, destination: destination)) { error in
            XCTAssertEqual((error as? RuntimeError)?.code, "local_import_state_collision")
        }
        XCTAssertEqual(try destination.readState(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.file("collage-assets").appendingPathComponent(name).path))
        assertNoMarker()
    }

    func testAssetCollisionPreservesBothFilesAndDoesNotImportTasks() throws {
        try installTasks([["id": "one", "title": "one", "status": "ready"]], in: source)
        let name = try installCollage(in: source)
        try FileManager.default.createDirectory(at: destination.file("collage-assets"), withIntermediateDirectories: true)
        let otherBytes = Data("different image".utf8)
        try otherBytes.write(to: destination.assetURL(name), options: .withoutOverwriting)
        let before = try destination.readState()
        XCTAssertThrowsError(try LocalWorkspaceImport.perform(source: source, destination: destination)) { error in
            XCTAssertEqual((error as? RuntimeError)?.code, "local_import_asset_collision")
        }
        XCTAssertEqual(try Data(contentsOf: destination.assetURL(name)), otherBytes)
        XCTAssertEqual(try destination.readState(), before)
        XCTAssertEqual(try destination.readCollages(), StateRuntime.defaultCollages)
        assertNoMarker()
    }

    func testCollageCollisionStopsWithoutOverwriting() throws {
        _ = try installCollage(in: source)
        _ = try installCollage(in: destination)
        let before = try destination.readCollages()
        XCTAssertThrowsError(try LocalWorkspaceImport.perform(source: source, destination: destination)) { error in
            XCTAssertEqual((error as? RuntimeError)?.code, "local_import_collage_collision")
        }
        XCTAssertEqual(try destination.readCollages(), before)
        assertNoMarker()
    }

    func testMissingAssetStopsAndNoSuccessMarker() throws {
        let name = try installCollage(in: source)
        try FileManager.default.removeItem(at: source.assetURL(name))
        XCTAssertThrowsError(try LocalWorkspaceImport.perform(source: source, destination: destination))
        XCTAssertEqual(try destination.readState()["tasks"], [])
        assertNoMarker()
    }

    func testInvalidRawCollageReferenceIsNotSilentlyDropped() throws {
        let invalid: JSON = ["version": 1, "activeCanvasId": "one", "canvases": [["id": "one", "name": "one", "items": [["id": "image", "kind": "image", "assetFile": "../private.png"]]]]]
        try source.writeJSON(invalid, to: source.file("collages.json"))
        XCTAssertThrowsError(try LocalWorkspaceImport.perform(source: source, destination: destination)) { error in
            XCTAssertEqual((error as? RuntimeError)?.code, "local_import_invalid_asset")
        }
        assertNoMarker()
    }

    func testVersionMismatchAndSameRootAreRejected() throws {
        XCTAssertThrowsError(try LocalWorkspaceImport.perform(source: source, destination: destination, expectedVersion: 999))
        XCTAssertThrowsError(try LocalWorkspaceImport.perform(source: source, destination: source))
        assertNoMarker()
    }

    func testRetryAfterCollageCommitAndUnrelatedDestinationTaskPreservesBoth() throws {
        try installTasks([["id": "source", "title": "source", "status": "ready"]], in: source)
        try installTasks([["id": "destination", "title": "destination", "status": "ready"]], in: destination)
        let name = try installCollage(in: source)
        try FileManager.default.createDirectory(at: destination.file("collage-assets"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source.assetURL(name), to: destination.assetURL(name))
        _ = try destination.saveCollages(source.readCollages(), expected: destination.readCollages())
        let result = try LocalWorkspaceImport.perform(source: source, destination: destination)
        XCTAssertEqual(result["ok"], true)
        XCTAssertEqual(Set(try destination.readState()["tasks"].array.map { $0["id"].string }), ["source", "destination"])
        XCTAssertEqual(try destination.readCollages(), try source.readCollages())
    }

    func testMissingScheduleReferenceAndMalformedDestinationStop() throws {
        let before = try source.cloudState(); var state = before
        state["scheduleBlocks"] = [["id": "schedule", "title": "schedule", "taskId": "missing"]]
        _ = try source.applyCloudState(state, expected: before)
        XCTAssertThrowsError(try LocalWorkspaceImport.perform(source: source, destination: destination)) { error in
            XCTAssertEqual((error as? RuntimeError)?.code, "local_import_missing_reference")
        }
        assertNoMarker()
        try destination.writeJSON(["version": 1, "canvases": []], to: destination.file("collages.json"))
        XCTAssertThrowsError(try LocalWorkspaceImport.perform(source: source, destination: destination)) { error in
            XCTAssertEqual((error as? RuntimeError)?.code, "local_import_invalid_collages")
        }
        XCTAssertEqual(try destination.readJSON(destination.file("collages.json"))["canvases"], [])
    }
}
