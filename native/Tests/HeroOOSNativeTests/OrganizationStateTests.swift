import XCTest
@testable import OOSCore

final class OrganizationStateTests: XCTestCase {
    private func runtime(_ body: (StateRuntime) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hero-organization-core-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = StateRuntime(root: root)
        try runtime.initializeIfNeeded()
        try body(runtime)
    }
    private func setState(_ content: JSON, on runtime: StateRuntime) throws {
        let old = try runtime.readState()
        var next = old
        for (key, value) in content.object { next[key] = value }
        try runtime.writeJSON(next, to: runtime.file("state.json"))
    }
    private func document(_ tasks: [JSON], tracks: [JSON] = [], pages: [JSON] = []) -> JSON {
        ["tasks": .array(tasks), "tracks": .array(tracks), "taskPages": .array(pages)]
    }
    private func task(_ id: String, title: String = "Shared", space: String = "work") -> JSON {
        ["id": .string(id), "title": .string(title), "taskSpace": .string(space)]
    }

    func testProjectionExcludesPrivateTasksCodexAndEveryUnrelatedCollection() throws {
        let personal: JSON = ["id": "private", "title": "Secret", "taskSpace": "personal", "codexThreadId": "secret-thread"]
        let work: JSON = ["id": "work", "title": "Business", "status": "waiting", "dependsOn": ["private", "work2"],
            "codexThreadId": "private-thread", "codexSummary": "secret", "localPath": "/private/file", "sourceRecord": ["password": "secret"],
            "futureSecret": "secret", "trackId": "referenced", "updatedAt": "volatile", "details": ["Deliver audio", ["secret": "nested"]],
            "peopleWaits": [["id": "p", "person": "alice", "outcome": "Payment", "resolved": false, "private": "secret"]]]
        let state: JSON = ["tasks": .array([personal, work, task("work2")]),
            "tracks": [["id": "referenced", "name": "Shared track", "navLabel": "Audio", "habitPlan": ["private": "yes"], "stages": ["A", "B"]],
                       ["id": "not-referenced", "name": "Secret track"]],
            "taskPages": [], "collages": [["secret": "yes"]], "memories": [["private": "yes"]], "futureRoot": ["secret": "yes"]]
        let projected = StateRuntime.organizationProjection(state)
        XCTAssertEqual(Set(projected.object.keys), ["tasks", "tracks", "taskPages"])
        XCTAssertEqual(projected["tasks"].array.count, 2)
        let shared = projected["tasks"].array[0]
        XCTAssertEqual(shared["taskSpace"], "work")
        XCTAssertEqual(shared["dependsOn"], ["work2"])
        XCTAssertEqual(shared["details"], ["Deliver audio"])
        for key in ["codexThreadId", "codexSummary", "localPath", "sourceRecord", "futureSecret", "updatedAt"] { XCTAssertEqual(shared[key], .null) }
        XCTAssertEqual(shared["peopleWaits"].array[0]["private"], .null)
        XCTAssertEqual(projected["tracks"].array.count, 1)
        XCTAssertEqual(projected["tracks"].array[0]["habitPlan"], .null)
        XCTAssertEqual(projected["tracks"].array[0]["stages"], ["A", "B"])
        try runtime { try $0.validateOrganizationState(projected) }
    }

    func testProjectionPreservesManagementAndLedgerFields() throws {
        let page = "page-" + UUID().uuidString
        var work = task("work", space: page)
        work["amountTaxInclusive"] = 6000; work["feeAmount"] = 3000; work["currency"] = "CNY"
        work["invoiceStatus"] = "部分开票"; work["paymentStatus"] = "待付款"; work["blockedBy"] = "alice"
        work["availableAt"] = "2026-10-20T09:00:00+08:00"; work["archived"] = true; work["note"] = "second invoice pending"
        let state = document([work], pages: [["id": .string(page), "title": "Projects", "createdAt": "today", "localPath": "secret"]])
        let projected = StateRuntime.organizationProjection(state)
        XCTAssertEqual(projected["tasks"].array[0], work)
        XCTAssertEqual(projected["taskPages"].array[0]["localPath"], .null)
        try runtime { try $0.validateOrganizationState(projected) }
    }

    func testRejectsUnknownFieldsIncludingNestedWaitAndPrivateTask() throws {
        try runtime { runtime in
            for (key, value) in [("codexThreadId", JSON.string("secret")), ("sourceRecord", JSON.object(["title": "secret"])), ("localPath", .string("/private"))] {
                var forbidden = task("a"); forbidden[key] = value
                XCTAssertThrowsError(try runtime.validateOrganizationState(document([forbidden])))
            }
            var unknownWait = task("a")
            unknownWait["peopleWaits"] = [["id": "p", "person": "A", "outcome": "", "resolved": false, "secret": "hidden"]]
            XCTAssertThrowsError(try runtime.validateOrganizationState(document([unknownWait])))
            XCTAssertThrowsError(try runtime.validateOrganizationState(document([task("private", space: "personal")])))
            var malformed = task("a"); malformed["note"] = ["secret": "nested"]
            XCTAssertThrowsError(try runtime.validateOrganizationState(document([malformed])))
            malformed = task("a"); malformed["details"] = [["private": "nested"]]
            XCTAssertThrowsError(try runtime.validateOrganizationState(document([malformed])))
            var forbiddenRoot = document([task("a")]); forbiddenRoot["collages"] = []
            XCTAssertThrowsError(try runtime.validateOrganizationState(forbiddenRoot))
        }
    }

    func testApplyRetainsPrivateTasksLocalMetadataAndPrivateDependencies() throws {
        try runtime { runtime in
            var local = task("work"); local["codexThreadId"] = "private-thread"; local["sourceRecord"] = ["private": "source"]
            local["dependsOn"] = ["private", "old-work"]
            local["peopleWaits"] = [["id": "wait", "person": "alice", "outcome": "Payment", "resolved": false, "localNote": "private"]]
            let personal = task("private", title: "Secret", space: "personal")
            try setState(["tasks": .array([local, personal, task("old-work")]), "memories": [["id": "m", "title": "Secret memory"]],
                "futureRoot": ["private": true]], on: runtime)
            let expected = try runtime.organizationState()
            var update = task("work", title: "Changed by coworker"); update["dependsOn"] = []
            update["peopleWaits"] = [["id": "wait", "person": "alice", "outcome": "Payment", "resolved": true]]
            let incoming = document([update])
            let result = try runtime.applyOrganizationState(incoming, expected: expected)
            let merged = result["tasks"].array[0]
            XCTAssertEqual(merged["title"], update["title"])
            XCTAssertEqual(merged["dependsOn"], ["private"])
            XCTAssertEqual(merged["codexThreadId"], "private-thread")
            XCTAssertEqual(merged["sourceRecord"], ["private": "source"])
            XCTAssertEqual(merged["peopleWaits"].array[0]["resolved"], true)
            XCTAssertEqual(merged["peopleWaits"].array[0]["localNote"], "private")
            XCTAssertEqual(result["tasks"].array[1], personal)
            XCTAssertEqual(result["memories"], [["id": "m", "title": "Secret memory"]])
            XCTAssertEqual(result["futureRoot"], ["private": true])
            XCTAssertEqual(try runtime.organizationState(), incoming)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: runtime.file("cloud-history").path).count, 1)
        }
    }

    func testCASIgnoresPrivateAndLocalOnlyEditsButRejectsSharedConcurrentEdit() throws {
        try runtime { runtime in
            try setState(document([task("a"), task("private", space: "personal")]), on: runtime)
            let expected = try runtime.organizationState()
            var edited = try runtime.readState()
            var tasks = edited["tasks"].array
            tasks[0]["codexThreadId"] = "locally-linked"; tasks[1]["title"] = "Locally edited secret"
            edited["tasks"] = .array(tasks)
            try setState(edited, on: runtime)
            let result = try runtime.applyOrganizationState(document([task("a", title: "Shared change")]), expected: expected)
            XCTAssertEqual(result["tasks"].array[0]["codexThreadId"], "locally-linked")
            XCTAssertEqual(result["tasks"].array[1]["title"], "Locally edited secret")
            XCTAssertThrowsError(try runtime.applyOrganizationState(expected, expected: expected)) { error in
                XCTAssertEqual((error as? RuntimeError)?.code, "cloud_local_conflict")
            }
        }
    }

    func testSharedIDCannotReplacePrivateTask() throws {
        try runtime { runtime in
            try setState(document([task("same", title: "Secret", space: "personal")]), on: runtime)
            let before = try runtime.readState()
            XCTAssertThrowsError(try runtime.applyOrganizationState(document([task("same")]), expected: runtime.organizationState())) { error in
                XCTAssertEqual((error as? RuntimeError)?.code, "organization_private_id_conflict")
            }
            XCTAssertEqual(try runtime.readState(), before)
        }
    }

    func testPrivateDependencyPreventsDestructiveRemoteDeletion() throws {
        try runtime { runtime in
            var personal = task("private", space: "personal"); personal["dependsOn"] = ["work"]
            try setState(document([task("work"), personal]), on: runtime)
            let before = try runtime.readState()
            XCTAssertThrowsError(try runtime.applyOrganizationState(document([]), expected: runtime.organizationState())) { error in
                XCTAssertEqual((error as? RuntimeError)?.code, "organization_private_dependency_conflict")
            }
            XCTAssertEqual(try runtime.readState(), before)
        }
    }

    func testCombinedPrivateAndRemoteCycleIsRejected() throws {
        try runtime { runtime in
            var a = task("a"); a["dependsOn"] = ["private"]
            var personal = task("private", space: "personal"); personal["dependsOn"] = ["b"]
            try setState(document([a, task("b"), personal]), on: runtime)
            let expected = try runtime.organizationState(), before = try runtime.readState()
            var b = task("b"); b["dependsOn"] = ["a"]
            // The org-only graph b -> a is acyclic; after restoring local edges it is not.
            XCTAssertThrowsError(try runtime.applyOrganizationState(document([task("a"), b]), expected: expected)) { error in
                XCTAssertEqual((error as? RuntimeError)?.code, "relationship_cycle")
            }
            XCTAssertEqual(try runtime.readState(), before)
        }
    }

    func testGraphRejectsMissingReferencesAndUnreferencedCollections() throws {
        try runtime { runtime in
            var missing = task("a"); missing["dependsOn"] = ["not-found"]
            XCTAssertThrowsError(try runtime.validateOrganizationState(document([missing])))
            missing = task("a"); missing["trackId"] = "not-found"
            XCTAssertThrowsError(try runtime.validateOrganizationState(document([missing])))
            let incoming = document([task("a")], tracks: [["id": "unused", "name": "Unused"]])
            XCTAssertThrowsError(try runtime.applyOrganizationState(incoming, expected: runtime.organizationState()))
        }
    }

    func testLocalTrackAndPageMetadataRemainWhileSharedLabelsUpdate() throws {
        try runtime { runtime in
            let page = "page-" + UUID().uuidString
            var work = task("work", space: page); work["trackId"] = "track"
            let local = document([work], tracks: [["id": "track", "name": "Before", "habitPlan": ["secret": true]], ["id": "local-only", "name": "Local"]],
                pages: [["id": .string(page), "title": "Before", "localPath": "/private"]])
            try setState(local, on: runtime)
            let incoming = document([work], tracks: [["id": "track", "name": "After"]], pages: [["id": .string(page), "title": "After"]])
            let result = try runtime.applyOrganizationState(incoming, expected: runtime.organizationState())
            XCTAssertEqual(result["tracks"].array[0]["habitPlan"], ["secret": true])
            XCTAssertEqual(result["tracks"].array[1]["id"], "local-only")
            XCTAssertEqual(result["taskPages"].array[0]["localPath"], "/private")
            XCTAssertEqual(try runtime.organizationState(), incoming)
        }
    }
}
