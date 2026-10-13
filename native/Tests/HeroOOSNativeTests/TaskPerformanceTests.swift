import XCTest
import SwiftUI
import Combine
@testable import HeroOOSNative

@MainActor final class TaskPerformanceTests: XCTestCase {
    private func fixture() -> JSON {
        .object(["meta": .object(["version": 1]), "tasks": .array((0..<92).map { index in
            .object(["id": .string("task-\(index)"), "title": .string("任务 \(index)"),
                     "status": .string(index < 13 ? "ready" : "completed"),
                     "priority": 5, "note": .string(String(repeating: "项目执行记录\n", count: 8)),
                     "due": "2026-10-01", "dependsOn": .array([])])
        })])
    }

    func testTaskSnapshotFollowsNestedDraftChangesAndRemoteUpdates() {
        let store = OOSStore(recoverDrafts: false); store.state = fixture()
        XCTAssertEqual(store.task("task-0")?.title, "任务 0")
        store.pending["task-0"] = ["title": "本地标题"]
        XCTAssertEqual(store.task("task-0")?.title, "本地标题")
        store.pending["task-0"]?["title"] = "再次修改"
        XCTAssertEqual(store.tasks.first?.title, "再次修改")
        var updated = fixture()
        var records = updated["tasks"].array
        records[0]["title"] = "远端标题"
        records[0]["priority"] = 9
        updated["tasks"] = .array(records); updated["meta"]["version"] = 2
        XCTAssertTrue(store.acceptState(updated))
        XCTAssertEqual(store.task("task-0")?.title, "再次修改")
        XCTAssertEqual(store.task("task-0")?.number("priority"), 9)
        store.pending.removeAll()
        XCTAssertEqual(store.task("task-0")?.title, "远端标题")
        records.removeFirst(); updated["tasks"] = .array(records); store.state = updated
        XCTAssertNil(store.task("task-0"))
    }

    func testUnchangedPollingDoesNotPublishOrReplaceState() async {
        let snapshot = fixture()
        let api = OOSAPI(transport: { _, _, _, _ in .object(["state": snapshot]) })
        let store = OOSStore(api: api, recoverDrafts: false)
        await store.refresh()
        var publications = 0
        let subscription = store.objectWillChange.sink { publications += 1 }
        await store.refresh()
        XCTAssertEqual(publications, 0)
        XCTAssertFalse(store.acceptState(.object(["meta": .object(["version": 0])])))
        XCTAssertEqual(store.tasks.count, 92)
        withExtendedLifetime(subscription) {}
    }

    func testRelationshipChoicesMatchExistingValidationIncludingCyclesAndSpaces() {
        var tasks = (0..<30).map { index in
            Record(["id": .string("t\(index)"), "taskSpace": .string(index % 5 == 0 ? "personal" : "work"),
                    "status": .string(index % 3 == 0 ? "completed" : "ready"),
                    "parentId": .string(index > 0 ? "t\(index - 1)" : ""),
                    "dependsOn": .array(index > 1 ? [.string("t\(index - 2)")] : [])])
        }
        tasks[0]["parentId"] = "t3"; tasks[1]["dependsOn"] = ["t5"]
        for task in tasks {
            let choices = Relations.choices(for: task, tasks: tasks)
            let parents = tasks.filter { (!$0.isClosed || $0.id == task.text("parentId")) && Relations.canParent(task.id, under: $0.id, tasks: tasks) }
            let dependencies = tasks.filter { Relations.canDepend(task.id, on: $0.id, tasks: tasks) && !task["dependsOn"].array.map(\.string).contains($0.id) }
            XCTAssertEqual(choices.parents.map(\.id), parents.map(\.id))
            XCTAssertEqual(choices.dependencies.map(\.id), dependencies.map(\.id))
        }
    }

    func testRelationshipChoicesKeepUnlimitedDepth() {
        let tasks = (0..<220).map { index in
            Record(["id": .string("t\(index)"), "parentId": .string(index == 0 ? "" : "t\(index - 1)"),
                    "dependsOn": []])
        }
        let choices = Relations.choices(for: tasks[0], tasks: tasks)
        XCTAssertTrue(choices.parents.isEmpty)
        XCTAssertEqual(choices.dependencies.count, 219)
        XCTAssertTrue(Relations.choices(for: tasks[219], tasks: tasks).dependencies.isEmpty)
        XCTAssertEqual(Relations.choices(for: tasks[219], tasks: tasks).parents.count, 219)
    }

    func testInspectorLayoutBenchmark() throws {
        guard ProcessInfo.processInfo.environment["HERO_OOS_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in native layout benchmark")
        }
        _ = NSApplication.shared
        let store = OOSStore(recoverDrafts: false); store.state = fixture()
        var durations: [Double] = []
        for _ in 0..<6 {
            let start = CFAbsoluteTimeGetCurrent()
            let view = NSHostingView(rootView: TaskInspector(id: "task-0", close: {}, addChild: {}).environmentObject(store))
            view.frame = NSRect(x: 0, y: 0, width: 1120, height: 600)
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            durations.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        print("INSPECTOR_LAYOUT_MS \(durations.map { String(format: "%.1f", $0) }.joined(separator: ","))")
    }
}
