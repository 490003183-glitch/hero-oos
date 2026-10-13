import XCTest
@testable import OOSCore

final class CloudStateTests: XCTestCase {
    func testMergeIndependentFieldsAndDifferentEntities() throws {
        let base: JSON = ["tasks": [["id": "a", "title": "A", "notes": ""], ["id": "b", "title": "B"]]]
        let local: JSON = ["tasks": [["id": "a", "title": "New A", "notes": ""], ["id": "b", "title": "B"]]]
        let remote: JSON = ["tasks": [["id": "a", "title": "A", "notes": "remote"], ["id": "b", "title": "New B"]]]
        let result = try CloudStateMerge.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(result["tasks"].array[0]["title"], "New A")
        XCTAssertEqual(result["tasks"].array[0]["notes"], "remote")
        XCTAssertEqual(result["tasks"].array[1]["title"], "New B")
    }
    func testSameFieldAndDeleteEditConflict() {
        let base: JSON = ["tasks": [["id": "a", "title": "A"]]]
        let local: JSON = ["tasks": [["id": "a", "title": "Local"]]]
        XCTAssertThrowsError(try CloudStateMerge.merge(base: base, local: local, remote: ["tasks": [["id": "a", "title": "Remote"]]]))
        XCTAssertThrowsError(try CloudStateMerge.merge(base: base, local: local, remote: ["tasks": []]))
    }
    func testProjectionDoesNotUploadDeviceStateOrFalseTimestampConflict() {
        let projection = StateRuntime.cloudProjection(["meta": ["version": 2], "receipts": [["id": "r"]], "migrations": [],
            "tasks": [["id": "a", "updatedAt": "new", "createdAt": "old"]], "currentTruth": ["lastBuiltAt": "now", "horizonHours": 72]])
        XCTAssertEqual(projection["meta"], .null)
        XCTAssertEqual(projection["receipts"], .null)
        XCTAssertEqual(projection["tasks"].array[0]["updatedAt"], .null)
        XCTAssertEqual(projection["tasks"].array[0]["createdAt"], "old")
        XCTAssertEqual(projection["currentTruth"]["lastBuiltAt"], .null)
    }
    func testExplicitNullIsPreserved() throws {
        let result = try CloudStateMerge.merge(base: ["a": 1, "b": 1], local: ["a": nil, "b": 1], remote: ["a": 1, "b": 2])
        XCTAssertEqual(result.object["a"], .some(.null))
        XCTAssertEqual(result["b"], 2)
    }
    func testRuntimeCASInitializesWithoutOverwritingAndPreservesEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hero-cloud-core-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = StateRuntime(root: root)
        try runtime.initializeIfNeeded()
        let initial = try runtime.readState()
        try runtime.initializeIfNeeded()
        XCTAssertEqual(try runtime.readState(), initial)
        let base = try runtime.cloudState()
        var next = base; next["tasks"] = [["id": "a", "title": "private", "status": "ready"]]
        let written = try runtime.applyCloudState(next, expected: base)
        XCTAssertEqual(written["meta"]["version"], 2)
        XCTAssertEqual(written["meta"]["instanceId"], initial["meta"]["instanceId"])
        XCTAssertThrowsError(try runtime.applyCloudState(base, expected: base))
        XCTAssertEqual(try runtime.cloudState(), next)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("data/cloud-history").path).count, 1)
    }
    func testCrossDeviceCycleIsRejected() throws {
        let runtime = StateRuntime(root: URL(fileURLWithPath: "/unused"))
        let invalid: JSON = ["tasks": [["id": "a", "title": "A", "dependsOn": ["b"]], ["id": "b", "title": "B", "dependsOn": ["a"]]]]
        XCTAssertThrowsError(try runtime.validateCloudState(invalid))
    }
}
