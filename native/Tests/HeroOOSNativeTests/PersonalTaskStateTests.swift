import XCTest
@testable import OOSCore

final class PersonalTaskStateTests: XCTestCase {
    private func runtime(_ body: (StateRuntime) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hero-personal-core-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = StateRuntime(root: root)
        try runtime.initializeIfNeeded()
        try body(runtime)
    }
    private func setState(_ content: JSON, on runtime: StateRuntime) throws {
        var next = try runtime.readState()
        for (key, value) in content.object { next[key] = value }
        try runtime.writeJSON(next, to: runtime.file("state.json"))
    }
    private func document(_ tasks: [JSON], tracks: [JSON] = []) -> JSON {
        ["tasks": .array(tasks), "tracks": .array(tracks), "taskPages": []]
    }
    private func task(_ id: String, title: String = "Private", space: String = "personal") -> JSON {
        ["id": .string(id), "title": .string(title), "taskSpace": .string(space)]
    }

    func testPrivateProjectionOnlyIncludesOwnerTasksAndSafeFields() throws {
        var personal = task("p")
        personal["dependsOn"] = ["p2", "work"]
        personal["trackId"] = "private-track"
        personal["codexThreadId"] = "secret"; personal["sourceRecord"] = ["secret": true]
        personal["localPath"] = "/private/asset"; personal["futureUnknown"] = ["secret": true]
        let state: JSON = ["tasks": .array([task("work", space: "work"), personal, task("p2")]),
            "tracks": [["id": "private-track", "name": "Private", "localPath": "/local"], ["id": "unused", "name": "Unused"]],
            "taskPages": [["id": .string("page-" + UUID().uuidString), "title": "Local page"]],
            "collages": [["id": "image", "file": "/private/photo.png"]], "memories": [["private": true]]]
        let result = StateRuntime.personalTaskProjection(state)
        XCTAssertEqual(Set(result.object.keys), ["tasks", "tracks", "taskPages"])
        XCTAssertEqual(result["tasks"].array.map { $0["id"].string }, ["p", "p2"])
        XCTAssertEqual(result["tasks"].array[0]["dependsOn"], ["p2"])
        for key in ["codexThreadId", "sourceRecord", "localPath", "futureUnknown"] { XCTAssertEqual(result["tasks"].array[0][key], .null) }
        XCTAssertEqual(result["tracks"].array, [["id": "private-track", "name": "Private"]])
        XCTAssertEqual(result["taskPages"], [])
        try runtime { try $0.validatePersonalTaskState(result) }
    }

    func testPersonalContractRejectsWorkCustomPagesAndUnknownFields() throws {
        try runtime { runtime in
            XCTAssertThrowsError(try runtime.validatePersonalTaskState(document([task("work", space: "work")])))
            XCTAssertThrowsError(try runtime.validatePersonalTaskState(document([task("custom", space: "page-" + UUID().uuidString)])))
            var unknown = task("p"); unknown["codexThreadId"] = "secret"
            XCTAssertThrowsError(try runtime.validatePersonalTaskState(document([unknown])))
            unknown = task("p"); unknown["peopleWaits"] = [["id": "person", "person": "A", "outcome": "", "resolved": false, "privateURL": "secret"]]
            XCTAssertThrowsError(try runtime.validatePersonalTaskState(document([unknown])))
            var forbidden = document([task("p")]); forbidden["collages"] = []
            XCTAssertThrowsError(try runtime.validatePersonalTaskState(forbidden))
            forbidden = document([task("p")]); forbidden["taskPages"] = [["id": .string("page-" + UUID().uuidString), "title": "Extra"]]
            XCTAssertThrowsError(try runtime.validatePersonalTaskState(forbidden))
        }
    }

    func testApplyPreservesOrganizationAndLocalPrivateMetadataAndCrossScopeEdges() throws {
        try runtime { runtime in
            var personal = task("p"); personal["dependsOn"] = ["work", "old-private"]
            personal["codexThreadId"] = "local-thread"; personal["sourceRecord"] = ["local": true]
            personal["peopleWaits"] = [["id": "wait", "person": "Friend", "outcome": "Reply", "resolved": false, "localNote": "local"]]
            let work = task("work", title: "Business", space: "work")
            try setState(["tasks": .array([work, personal, task("old-private")]), "memories": [["id": "m", "secret": true]],
                "futureRoot": ["unknown": true]], on: runtime)
            var updated = task("p", title: "Updated on another computer"); updated["dependsOn"] = []
            updated["peopleWaits"] = [["id": "wait", "person": "Friend", "outcome": "Reply", "resolved": true]]
            let incoming = document([updated])
            let next = try runtime.applyPersonalTaskState(incoming, expected: runtime.personalTaskState())
            XCTAssertEqual(next["tasks"].array[0], work)
            XCTAssertEqual(next["tasks"].array[1]["dependsOn"], ["work"])
            XCTAssertEqual(next["tasks"].array[1]["codexThreadId"], "local-thread")
            XCTAssertEqual(next["tasks"].array[1]["sourceRecord"], ["local": true])
            XCTAssertEqual(next["tasks"].array[1]["peopleWaits"].array[0]["localNote"], "local")
            XCTAssertEqual(next["memories"], [["id": "m", "secret": true]])
            XCTAssertEqual(next["futureRoot"], ["unknown": true])
            XCTAssertEqual(try runtime.personalTaskState(), incoming)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: runtime.file("cloud-history").path).count, 1)
        }
    }

    func testPersonalCASIgnoresOrganizationEditsAndPreservesThem() throws {
        try runtime { runtime in
            try setState(document([task("work", space: "work"), task("p")]), on: runtime)
            let expected = try runtime.personalTaskState()
            try setState(document([task("work", title: "Coworker change", space: "work"), task("p")]), on: runtime)
            let incoming = document([task("p", title: "Owner change")])
            let next = try runtime.applyPersonalTaskState(incoming, expected: expected)
            XCTAssertEqual(next["tasks"].array[0]["title"], "Coworker change")
            XCTAssertEqual(try runtime.personalTaskState(), incoming)
            XCTAssertThrowsError(try runtime.applyPersonalTaskState(expected, expected: expected)) { error in
                XCTAssertEqual((error as? RuntimeError)?.code, "cloud_local_conflict")
            }
        }
    }

    func testPersonalIDCannotReplaceOrganizationTask() throws {
        try runtime { runtime in
            try setState(document([task("same", space: "work")]), on: runtime)
            let before = try runtime.readState()
            XCTAssertThrowsError(try runtime.applyPersonalTaskState(document([task("same")]), expected: runtime.personalTaskState())) { error in
                XCTAssertEqual((error as? RuntimeError)?.code, "personal_organization_id_conflict")
            }
            XCTAssertEqual(try runtime.readState(), before)
        }
    }

    func testRemotePrivateDeletionCannotEraseLocalWorkDependency() throws {
        try runtime { runtime in
            var work = task("work", space: "work"); work["dependsOn"] = ["private"]
            try setState(document([work, task("private")]), on: runtime)
            let before = try runtime.readState()
            XCTAssertThrowsError(try runtime.applyPersonalTaskState(document([]), expected: runtime.personalTaskState())) { error in
                XCTAssertEqual((error as? RuntimeError)?.code, "personal_organization_dependency_conflict")
            }
            XCTAssertEqual(try runtime.readState(), before)
        }
    }

    func testPersonalApplyValidatesFullCrossScopeGraph() throws {
        try runtime { runtime in
            var p = task("p"); p["dependsOn"] = ["work"]
            var work = task("work", space: "work"); work["dependsOn"] = ["p2"]
            try setState(document([work, p, task("p2")]), on: runtime)
            let before = try runtime.readState()
            var p2 = task("p2"); p2["dependsOn"] = ["p"]
            XCTAssertThrowsError(try runtime.applyPersonalTaskState(document([task("p"), p2]), expected: runtime.personalTaskState())) { error in
                XCTAssertEqual((error as? RuntimeError)?.code, "relationship_cycle")
            }
            XCTAssertEqual(try runtime.readState(), before)
        }
    }

    func testSharedTrackMetadataConflictIsSymmetricAndNonDestructive() throws {
        try runtime { runtime in
            var work = task("work", space: "work"); work["trackId"] = "shared-track"
            var personal = task("p"); personal["trackId"] = "shared-track"
            let track: JSON = ["id": "shared-track", "name": "Original", "privateExtra": true]
            try setState(document([work, personal], tracks: [track]), on: runtime)
            let before = try runtime.readState()
            let changed: JSON = ["id": "shared-track", "name": "Renamed remotely"]
            XCTAssertThrowsError(try runtime.applyPersonalTaskState(document([personal], tracks: [changed]), expected: runtime.personalTaskState())) { error in
                XCTAssertEqual((error as? RuntimeError)?.code, "cloud_shared_track_conflict")
            }
            XCTAssertThrowsError(try runtime.applyOrganizationState(document([work], tracks: [changed]), expected: runtime.organizationState())) { error in
                XCTAssertEqual((error as? RuntimeError)?.code, "cloud_shared_track_conflict")
            }
            XCTAssertEqual(try runtime.readState(), before)
        }
    }

    func testOrganizationAndPersonalOrdinaryAppliesCommute() throws {
        try runtime { first in try runtime { second in
            var work = task("work", title: "Business", space: "work"); work["trackId"] = "work-track"
            var personal = task("p"); personal["trackId"] = "private-track"
            let initial = document([work, personal], tracks: [["id": "work-track", "name": "Business"], ["id": "private-track", "name": "Private"]])
            try setState(initial, on: first); try setState(initial, on: second)
            let orgExpected = try first.organizationState(), privateExpected = try first.personalTaskState()
            work["title"] = "Coworker edit"; personal["title"] = "Owner edit"
            let orgIncoming = document([work], tracks: [["id": "work-track", "name": "Business"]])
            let privateIncoming = document([personal], tracks: [["id": "private-track", "name": "Private"]])
            try first.applyOrganizationState(orgIncoming, expected: orgExpected)
            try first.applyPersonalTaskState(privateIncoming, expected: privateExpected)
            try second.applyPersonalTaskState(privateIncoming, expected: privateExpected)
            try second.applyOrganizationState(orgIncoming, expected: orgExpected)
            XCTAssertEqual(try first.organizationState(), orgIncoming)
            XCTAssertEqual(try first.personalTaskState(), privateIncoming)
            XCTAssertEqual(try first.organizationState(), try second.organizationState())
            XCTAssertEqual(try first.personalTaskState(), try second.personalTaskState())
            XCTAssertEqual(try first.readState()["tasks"], try second.readState()["tasks"])
            XCTAssertEqual(try first.readState()["tracks"], try second.readState()["tracks"])
        } }
    }

    func testSharedTrackArrayOrderCannotCauseOppositeScopeCASConflict() throws {
        try runtime { first in try runtime { second in
            var work1 = task("w1", space: "work"); work1["trackId"] = "z-shared"
            var work2 = task("w2", space: "work"); work2["trackId"] = "a-work"
            var private1 = task("p1"); private1["trackId"] = "z-shared"
            var private2 = task("p2"); private2["trackId"] = "a-private"
            let initial = document([work1, private1, work2, private2], tracks: [
                ["id": "z-shared", "name": "Shared"], ["id": "a-private", "name": "Private"], ["id": "a-work", "name": "Work"]])
            try setState(initial, on: first); try setState(initial, on: second)
            let orgExpected = try first.organizationState(), privateExpected = try first.personalTaskState()
            var orgIncoming = orgExpected, privateIncoming = privateExpected
            var works = orgIncoming["tasks"].array; works[0]["title"] = "Work edited"; orgIncoming["tasks"] = .array(works)
            var personals = privateIncoming["tasks"].array; personals[0]["title"] = "Private edited"; privateIncoming["tasks"] = .array(personals)
            try first.applyOrganizationState(orgIncoming, expected: orgExpected)
            XCTAssertEqual(try first.personalTaskState(), privateExpected)
            try first.applyPersonalTaskState(privateIncoming, expected: privateExpected)
            try second.applyPersonalTaskState(privateIncoming, expected: privateExpected)
            XCTAssertEqual(try second.organizationState(), orgExpected)
            try second.applyOrganizationState(orgIncoming, expected: orgExpected)
            XCTAssertEqual(try first.personalTaskState(), try second.personalTaskState())
            XCTAssertEqual(try first.organizationState(), try second.organizationState())
        } }
    }
}
