import XCTest
@testable import OOSCore

final class SwiftRuntimeTests: SwiftIntegrationCase {
    func testVersionConflictAndIdempotentReplay() throws {
        let payload: JSON = ["expectedVersion": 1, "clientMutationId": "same", "ops": [["type": "task.create", "task": ["id": "one", "title": "测试", "future": ["keep": true]]]]]
        let first = try runtime.mutate(payload), replay = try runtime.mutate(payload)
        XCTAssertEqual(first["receipt"], replay["receipt"]); XCTAssertEqual(replay["duplicate"], true)
        var reused = payload; reused["ops"] = [["type": "capture.add", "text": "另一意图"]]
        assertError("mutation_id_reused") { _ = try runtime.mutate(reused) }
        var stale = payload; stale["clientMutationId"] = "other"
        assertError("state_conflict") { _ = try runtime.mutate(stale) }
        let state = try runtime.readState()
        XCTAssertEqual(state["tasks"].array.count, 1); XCTAssertEqual(state["tasks"].array[0]["future"], ["keep": true])
        XCTAssertEqual(state["futureRoot"], ["preserve": [1, true, nil]])
    }
    func testAtomicBatchRejectsAllOnInvalidOperation() throws {
        let before = try Data(contentsOf: root.appendingPathComponent("data/state.json"))
        XCTAssertThrowsError(try mutate([["type": "task.create", "task": ["id": "one", "title": "不能落盘"]], ["type": "unsupported.nope"]]))
        XCTAssertEqual(before, try Data(contentsOf: root.appendingPathComponent("data/state.json")))
    }
    func testUnlimitedHierarchyAndCycleValidationInDataLayer() throws {
        let ops: [JSON] = (0..<200).map { i in ["type": "task.create", "task": ["id": .string("t\(i)"), "title": .string("第\(i)层"), "parentId": i == 0 ? nil : .string("t\(i - 1)")]] }
        _ = try mutate(ops)
        assertError("relationship_cycle") { _ = try mutate([["type": "task.update", "id": "t0", "changes": ["parentId": "t199"]]]) }
        assertError("missing_dependency") { _ = try mutate([["type": "task.update", "id": "t0", "changes": ["dependsOn": ["missing"]]]]) }
        _ = try mutate([["type": "task.update", "id": "t0", "changes": ["dependsOn": ["t199"]]]])
        assertError("relationship_cycle") { _ = try mutate([["type": "task.update", "id": "t199", "changes": ["dependsOn": ["t0"]]]]) }
        XCTAssertEqual(try runtime.readState()["tasks"].array.count, 200)
    }
    func testParentCannotCompleteOrCancelWithOpenChildren() throws {
        _ = try mutate([["type": "task.create", "task": ["id": "parent", "title": "父"]], ["type": "task.create", "task": ["id": "child", "title": "子", "parentId": "parent"]]])
        for status in ["completed", "cancelled"] { assertError("parent_has_open_children") { _ = try mutate([["type": "task.update", "id": "parent", "changes": ["status": .string(status)]]]) } }
        _ = try mutate([["type": "task.complete", "id": "child"], ["type": "task.complete", "id": "parent"]])
        XCTAssertEqual(try runtime.readState()["tasks"].array[0]["status"], "completed")
    }
    func testDestructiveRiskAndRestore() throws {
        _ = try mutate([["type": "task.create", "task": ["id": "one", "title": "任务"]]])
        assertError("confirmation_required") { _ = try mutate([["type": "task.delete", "id": "one"]]) }
        let result = try mutate([["type": "task.delete", "id": "one"]], confirmed: true)
        XCTAssertTrue(try runtime.readState()["tasks"].array.isEmpty)
        _ = try mutate([["type": "receipt.undo", "receiptId": result["receipt"]["id"]]])
        XCTAssertEqual(try runtime.readState()["tasks"].array.first?["id"], "one")
    }
    func testUndoCannotClobberLaterEdit() throws {
        let created = try mutate([["type": "task.create", "task": ["id": "one", "title": "原文"]]])
        _ = try mutate([["type": "task.update", "id": "one", "changes": ["title": "外部编辑"]]])
        assertError("undo_conflict") { _ = try mutate([["type": "receipt.undo", "receiptId": created["receipt"]["id"]]]) }
    }
    func testUndoRemovesPreviouslyAbsentFields() throws {
        _ = try mutate([["type": "task.create", "task": ["id": "one", "title": "任务"]]])
        let result = try mutate([["type": "task.update", "id": "one", "changes": ["brandNew": "value"]]])
        _ = try mutate([["type": "receipt.undo", "receiptId": result["receipt"]["id"]]])
        XCTAssertNil(try runtime.readState()["tasks"].array[0].object["brandNew"])
    }
    func testWorkerMetricMemoryDecisionAndOnboarding() throws {
        let result = try mutate([["type": "capture.add", "id": "capture", "text": "记录"], ["type": "metric.record", "id": "metric", "trackId": "track-personal", "value": 2.5], ["type": "checkin.record", "id": "checkin", "trackId": "track-personal"], ["type": "memory.observe", "memory": ["id": "memory", "text": "观察"]], ["type": "decision.record", "decision": ["id": "decision", "title": "决策"]], ["type": "onboarding.step", "step": "done"]])
        let workerID = result["state"]["workerItems"].array[0]["id"]
        _ = try mutate([["type": "worker.resolve", "id": workerID], ["type": "memory.correct", "id": "memory", "changes": ["text": "校正"]], ["type": "decision.review", "id": "decision", "note": "复查"], ["type": "decision.outcome", "id": "decision", "outcome": "完成"]])
        XCTAssertEqual(try runtime.readState()["memories"].array[0]["text"], "校正")
        let deleted = try mutate([["type": "capture.delete", "id": "capture"], ["type": "metric.delete", "id": "metric"], ["type": "checkin.delete", "id": "checkin"], ["type": "memory.forget", "id": "memory"], ["type": "decision.delete", "id": "decision"]])
        _ = try mutate([["type": "receipt.undo", "receiptId": deleted["receipt"]["id"]]])
        let state = try runtime.readState()
        XCTAssertEqual(state["captures"].array.count, 1); XCTAssertEqual(state["workerItems"].array[0]["status"], "resolved")
        XCTAssertEqual(state["metrics"].array[0]["value"], 2.5); XCTAssertEqual(state["checkins"].array.count, 1)
        XCTAssertEqual(state["memories"].array[0]["status"], "active"); XCTAssertEqual(state["decisions"].array[0]["outcome"], "完成")
    }
    func testMigrationImportAndUndo() throws {
        let result = try mutate([["type": "migration.importTasks", "tasks": [["id": "import", "title": "旧记录", "unknown": [1, 2]]], "migration": ["id": "migration", "sourceSystem": "test", "cutover": true]]], confirmed: true)
        XCTAssertEqual(result["state"]["tasks"].array[0]["unknown"], [1, 2])
        _ = try mutate([["type": "receipt.undo", "receiptId": result["receipt"]["id"]]])
        XCTAssertTrue(try runtime.readState()["tasks"].array.isEmpty)
        XCTAssertTrue(try runtime.readState()["migrations"].array.isEmpty)
    }
    func testChangesAcknowledgmentAndTruth() throws {
        _ = try mutate([["type": "task.create", "task": ["title": "当前任务", "status": "active"]]])
        XCTAssertEqual(try runtime.changes(consumer: "test")["changes"].array.count, 1)
        _ = try runtime.acknowledge(consumer: "test", version: 2)
        XCTAssertTrue(try runtime.changes(consumer: "test")["changes"].array.isEmpty)
        assertError("invalid_ack_version") { _ = try runtime.acknowledge(consumer: "test", version: 1) }
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("CURRENT_TRUTH.md"), encoding: .utf8).contains("当前任务"))
    }
    func testInterruptedTransactionRecoveryBeforeAndAfterStateCommit() throws {
        for committed in [false, true] {
            let previous = try runtime.readState(); var next = previous
            next["meta"]["version"] = .number(previous["meta"]["version"].number + 1)
            let event: JSON = ["version": next["meta"]["version"], "mutationId": .string("recover-\(committed)"), "timestamp": .string(RuntimeDate.iso()), "affected": []]
            try runtime.writeJSON(["previousVersion": previous["meta"]["version"], "state": next, "event": event], to: root.appendingPathComponent("data/.pending-transaction.json"))
            if committed { try runtime.writeJSON(next, to: root.appendingPathComponent("data/state.json")) }
            try Data("swift:999999".utf8).write(to: root.appendingPathComponent("data/.state.lock"))
            XCTAssertEqual(try runtime.readState(), next)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("data/.pending-transaction.json").path))
        }
        XCTAssertEqual(try runtime.changes(consumer: "test")["changes"].array.count, 2)
    }
    func testInvalidNumbersDatesAndMissingVersions() throws {
        assertError("expected_version_required") { _ = try runtime.mutate(["clientMutationId": "x", "ops": [["type": "capture.add", "text": "x"]]]) }
        assertError("invalid_priority") { _ = try mutate([["type": "task.create", "task": ["title": "无效", "priority": 11]]]) }
        assertError("invalid_number") { _ = try mutate([["type": "task.create", "task": ["title": "无效", "effortHours": -1]]]) }
        assertError("invalid_schedule") { _ = try mutate([["type": "schedule.create", "block": ["title": "无效", "start": "bad", "end": "bad"]]]) }
    }
    func testCollageAssetsPreserveBytesAndPreventTraversal() throws {
        let bytes = Data([137, 80, 78, 71, 1, 2, 3])
        let asset = try runtime.importAsset(bytes, name: "测试&图.png", contentType: "image/png")
        XCTAssertEqual(try Data(contentsOf: runtime.assetURL(asset["assetFile"].string)), bytes)
        XCTAssertEqual(asset["originalName"], "测试&图.png")
        XCTAssertThrowsError(try runtime.assetURL("../state.json"))
        XCTAssertEqual(try runtime.cleanupAssets(), 0)
        let old = try runtime.readCollages(); var next = old; next["future"] = ["keep": true]
        _ = try runtime.saveCollages(next, expected: old)
        XCTAssertEqual(try runtime.readCollages()["future"], ["keep": true])
        assertError("collage_conflict") { _ = try runtime.saveCollages(old, expected: old) }
    }
    func testConcurrentCLIProcessesHaveOneWinnerAndReplay() throws {
        let executable = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HERO_OOS_TEST_CLI"] ?? FileManager.default.currentDirectoryPath + "/.build/debug/oos-state")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        let operations: JSON = [["type": "task.create", "task": ["title": "并发测试"]]]
        let file = root.appendingPathComponent("ops.json"); try operations.encoded().write(to: file)
        func runBatch(sameID: Bool, version: Int) throws -> [Int32] {
            var processes: [Process] = []
            for i in 0..<8 {
                let process = Process(); process.executableURL = executable
                process.arguments = ["op", "--root", root.path, "--file", file.path, "--expected-version", String(version), "--mutation-id", sameID ? "shared" : "unique-\(i)"]
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                try process.run(); processes.append(process)
            }
            return processes.map { $0.waitUntilExit(); return $0.terminationStatus }
        }
        XCTAssertEqual(try runBatch(sameID: false, version: 1).filter { $0 == 0 }.count, 1)
        XCTAssertEqual(try runBatch(sameID: true, version: 2).filter { $0 == 0 }.count, 8)
        XCTAssertEqual(try runtime.readState()["tasks"].array.count, 2)
        XCTAssertEqual(try runtime.readState()["meta"]["version"], 3)
    }
    private func assertError(_ code: String, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
        do { try body(); XCTFail("Expected \(code)", file: file, line: line) }
        catch let error as RuntimeError { XCTAssertEqual(error.code, code, file: file, line: line) }
        catch { XCTFail("Unexpected: \(error)", file: file, line: line) }
    }
}
