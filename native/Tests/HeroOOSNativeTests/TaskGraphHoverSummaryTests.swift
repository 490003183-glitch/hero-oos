import XCTest
@testable import OOSCore
@testable import HeroOOSNative

final class TaskGraphHoverSummaryTests: XCTestCase {
    private let now = RuntimeDate.parse("2026-10-13T12:00:00+08:00")!
    private func task(_ fields: [String: JSON] = [:]) -> OOSCore.Record {
        var result = OOSCore.Record(["id": "task", "title": "测试任务", "status": "ready", "taskSpace": "personal"])
        for (key, value) in fields { result[key] = value }
        return result
    }
    private func summary(_ source: OOSCore.Record, other: [OOSCore.Record] = []) -> TaskGraphHoverSummary {
        TaskGraphHoverSummary(task: source, spaceTitle: "私人任务", dependencies: TaskDependencies([source] + other), at: now)
    }

    func testEmptyBackgroundHasHonestPlaceholderAndNoNotesFallback() {
        let source = task(["background": " \n ", "notes": "不应当作为背景展示的原始备注", "note": "秘密路径", "token": "私有令牌"])
        let value = summary(source)
        XCTAssertTrue(value.backgroundIsEmpty)
        XCTAssertEqual(value.background, "未填写任务基础背景")
        XCTAssertFalse(value.backgroundIsTruncated)
        XCTAssertEqual(value.statusTitle, "待办")
        XCTAssertEqual(value.spaceTitle, "私人任务")
        XCTAssertTrue(value.fields.isEmpty)
        XCTAssertEqual(value.emptyConditionsText, "无未解除条件 · 可开始")
    }

    func testUnicodeBackgroundIsBoundedWithoutSplittingComposedCharacters() {
        let grapheme = "👨‍👩‍👧‍👦"
        let source = task(["background": .string(String(repeating: grapheme, count: 400))])
        let value = summary(source)
        XCTAssertEqual(value.background, String(repeating: grapheme, count: 350) + "…")
        XCTAssertEqual(value.background.count, 351)
        XCTAssertTrue(value.backgroundIsTruncated)
        XCTAssertFalse(value.backgroundIsEmpty)
    }

    func testExplicitNewlinesAreCappedAndTruncationMarked() {
        let source = task(["background": .string((1...20).map { "第 \($0) 行" }.joined(separator: "\n"))])
        let value = summary(source)
        XCTAssertEqual(value.background.components(separatedBy: .newlines).count, 8)
        XCTAssertTrue(value.backgroundIsTruncated)
        XCTAssertTrue(value.background.hasSuffix("第 8 行…"))
    }

    func testThreeConcurrentBlockingKindsAreAllIncludedAndResolvedEntriesExcluded() {
        let source = task(["status": "waiting", "peopleWaits": [
            ["id": "p1", "person": "alice", "outcome": "确认票据", "resolved": false],
            ["id": "p2", "person": "已解决的人", "outcome": "不用展示", "resolved": true]],
            "availableAt": "2026-10-20T12:00:00+08:00", "due": "2026-10-22",
            "dependsOn": ["pending", "done"], "background": "基本情况", "project": "项目甲", "nextAction": "等待结算"])
        let value = summary(source, other: [OOSCore.Record(["id": "pending", "title": "开具发票", "status": "waiting"]),
                                            OOSCore.Record(["id": "done", "title": "已经交付", "status": "completed"])])
        XCTAssertEqual(value.statusTitle, "等待")
        XCTAssertEqual(value.conditionGroups.map(\.id), ["person", "time", "task"])
        XCTAssertEqual(value.conditionGroups.map(\.count), [1, 1, 1])
        XCTAssertEqual(value.conditionGroups[0].value, "alice · 确认票据")
        XCTAssertEqual(value.conditionGroups[1].value, "尚未到可开始时间")
        XCTAssertEqual(value.conditionGroups[2].value, "开具发票")
        XCTAssertEqual(value.fields.map(\.id), ["availableAt", "due", "project", "nextAction"])
        XCTAssertEqual(value.fields.first(where: { $0.id == "due" })?.value, "2026/10/22")
        XCTAssertEqual(value.backgroundLineLimit, 3)
        XCTAssertTrue(value.isDense)
        XCTAssertEqual(value.conditionLineLimit, 1)
    }

    func testMissingPredecessorDoesNotExposeIDAndDoesNotReadUnrelatedTask() {
        let source = task(["dependsOn": ["private-token-shaped-id", "private-token-shaped-id"]])
        let value = summary(source, other: [OOSCore.Record(["id": "unrelated", "title": "不应展示的其他任务", "status": "ready"])])
        XCTAssertEqual(value.conditionGroups.count, 1)
        XCTAssertEqual(value.conditionGroups[0].count, 1)
        XCTAssertEqual(value.conditionGroups[0].value, "前置任务不可用")
    }

    func testReadOnlyProjectionPreservesEverySourceFieldAndDoesNotResolveTime() {
        let source = task(["status": "waiting", "blockedBy": "alice", "availableAt": "2026-10-13T12:00:00+08:00",
                           "background": "多行\n背景", "unknown": ["keep": true], "notes": "保留备注"])
        let original = source
        let dependencies = TaskDependencies([source])
        let originalRecords = dependencies.records
        let value = TaskGraphHoverSummary(task: source, spaceTitle: "私人任务", dependencies: dependencies, at: now)
        XCTAssertEqual(source, original)
        XCTAssertEqual(dependencies.records, originalRecords)
        XCTAssertEqual(value.statusTitle, "等待")
        XCTAssertEqual(value.conditionGroups.map(\.id), ["person"])
        XCTAssertEqual(value.fields.map(\.id), ["availableAt"])
        XCTAssertEqual(value.background, "多行\n背景")
    }

    func testManyConditionsAndLongMetadataStayBoundedAndShowCounts() {
        let people: [JSON] = (0..<20).map { ["id": .string("p\($0)"), "person": .string("人\($0)"), "outcome": "确认", "resolved": false] }
        let source = task(["peopleWaits": .array(people), "title": .string(String(repeating: "题", count: 500)),
                           "nextAction": .string(String(repeating: "做", count: 400)), "project": "项目\n很长\n很多行"])
        let value = summary(source)
        XCTAssertEqual(value.title.count, 121)
        XCTAssertEqual(value.conditionGroups[0].count, 20)
        XCTAssertTrue(value.conditionGroups[0].value.contains("另 18 项"))
        XCTAssertLessThanOrEqual(value.conditionGroups[0].value.count, 101)
        XCTAssertEqual(value.fields.first(where: { $0.id == "nextAction" })?.value.count, 101)
        XCTAssertEqual(value.fields.first(where: { $0.id == "project" })?.value, "项目…")
        XCTAssertLessThanOrEqual(value.backgroundLineLimit, 8)
        XCTAssertFalse(value.isDense)
        XCTAssertEqual(value.conditionLineLimit, 2)
    }

    func testDateProjectionRejectsInvalidDatesAndStillShowsBothFieldsForClosedTask() {
        for date in ["2026-02-30", "2026-02-29", "2026-13-01", "2026-02-30T10:00:00+08:00"] {
            XCTAssertTrue(summary(task(["due": .string(date)])).fields.isEmpty, date)
        }
        XCTAssertTrue(summary(task(["availableAt": "2026-10-20"])).fields.isEmpty)
        let value = summary(task(["status": "completed", "availableAt": "2026-10-20T12:00:00+08:00", "due": "2026-10-22"]))
        XCTAssertEqual(value.fields.map(\.id), ["availableAt", "due"])
        XCTAssertEqual(value.fields.last?.value, "2026/10/22")
    }

    func testClosedAndLegacyWaitingTasksAreNotMisreportedAsReady() {
        XCTAssertEqual(summary(task(["status": "completed"])).emptyConditionsText, "任务已结束")
        XCTAssertEqual(summary(task(["status": "completed", "blockedBy": "alice"])).conditionHeading, "保留的未解除条件")
        XCTAssertEqual(summary(task(["status": "waiting"])).emptyConditionsText, "无未解除的阻断条件")
        XCTAssertEqual(summary(task(["status": "future-new-status"])).statusTitle, "未设置状态")
        XCTAssertTrue(summary(task(["availableAt": "不是日期", "due": ""])).fields.isEmpty)
    }
}
