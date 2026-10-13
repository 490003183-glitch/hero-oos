import XCTest
@testable import OOSCore

final class TaskAgendaTests: SwiftIntegrationCase {
    private func calendar(_ name: String = "Asia/Shanghai") -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: name)!
        return value
    }

    private func day(_ date: String, in calendar: Calendar) -> Date {
        let parts = date.split(separator: "-").map { Int($0)! }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))!
    }

    private func task(_ dates: [String: JSON]) -> Record { task("task", dates) }

    private func task(_ id: String, _ dates: [String: JSON]) -> Record {
        Record(["id": .string(id), "title": .string(id), "status": "ready"].merging(dates) { _, new in new })
    }

    func testUnrelatedDateFieldsAreIgnored() {
        let cal = calendar(), date = day("2026-10-20", in: calendar())
        let ignoredFields = ["reviewDate", "startDate", "mustExecuteAt", "createdAt", "updatedAt"]
        let otherDates = Dictionary(uniqueKeysWithValues: ignoredFields.map { ($0, JSON.string("2026-10-20T10:00:00+08:00")) })
        XCTAssertTrue(TaskAgenda.entries(tasks: [task(otherDates)], on: date, calendar: cal).isEmpty)
        var dated = task(otherDates)
        dated["availableAt"] = "2026-10-20T11:00:00+08:00"
        let entries = TaskAgenda.entries(tasks: [dated], on: date, calendar: cal)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].task, dated)
        XCTAssertEqual(entries[0].milestones.map(\.kind), [.availableAt])
        XCTAssertEqual(entries[0].milestones[0].id, "availableAt")
        XCTAssertEqual(entries[0].milestones[0].kind.title, "可开始")
        XCTAssertFalse(entries[0].milestones[0].isAllDay)
        dated["availableAt"] = "2026-10-21T11:00:00+08:00"
        XCTAssertTrue(TaskAgenda.entries(tasks: [dated], on: date, calendar: cal).isEmpty)
        XCTAssertEqual(TaskAgenda.entries(tasks: [dated], on: day("2026-10-21", in: cal), calendar: cal).count, 1)
    }

    func testTimeBlockPriorityIsChosenBeforeDailyFiltering() {
        let cal = calendar(), source = task(["availableAt": "2026-10-20T11:00:00+08:00", "due": "2026-10-22"])
        let entries = TaskAgenda.entries(tasks: [source], on: day("2026-10-20", in: cal), calendar: cal)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].milestones.map(\.kind), [.availableAt])
        XCTAssertTrue(TaskAgenda.entries(tasks: [source], on: day("2026-10-22", in: cal), calendar: cal).isEmpty)
        var sameDay = source
        sameDay["due"] = "2026-10-20"
        XCTAssertEqual(TaskAgenda.entries(tasks: [sameDay], on: day("2026-10-20", in: cal), calendar: cal)[0].milestones.count, 1)
    }

    func testRangeAndAllEntriesPreserveSourcePriorityAndExclusiveEnd() {
        let cal = calendar(), first = cal.startOfDay(for: day("2026-10-20", in: cal))
        let end = cal.startOfDay(for: day("2026-10-22", in: cal))
        let tasks = [task("outside-priority", ["availableAt": "2026-10-19T23:59:59+08:00", "due": "2026-10-20"]),
                     task("start", ["due": "2026-10-20"]),
                     task("inside", ["availableAt": "2026-10-21T20:00:00+08:00", "due": "2026-10-25"]),
                     task("end", ["availableAt": "2026-10-22T00:00:00+08:00", "due": "2026-10-21"]),
                     task("closed", ["status": "completed", "due": "2026-10-20"]), task("undated", [:])]
        XCTAssertEqual(TaskAgenda.entries(tasks: tasks, calendar: cal).map(\.id), ["outside-priority", "start", "inside", "end"])
        XCTAssertEqual(TaskAgenda.entries(tasks: tasks, in: DateInterval(start: first, end: end), calendar: cal).map(\.id), ["start", "inside"])
        XCTAssertTrue(TaskAgenda.entries(tasks: tasks, in: DateInterval(start: first, duration: 0), calendar: cal).isEmpty)
        let all = TaskAgenda.entries(tasks: tasks, calendar: cal)
        for entry in all {
            XCTAssertEqual(entry.milestones.count, 1)
            XCTAssertEqual(TaskAgenda.entries(tasks: [entry.task], on: entry.milestones[0].date, calendar: cal), [entry])
        }
    }

    func testTaskRangeFollowsDSTDayBoundaries() {
        let cal = calendar("America/Los_Angeles")
        let start = cal.startOfDay(for: day("2026-03-08", in: cal)), end = cal.startOfDay(for: day("2026-03-09", in: cal))
        XCTAssertEqual(end.timeIntervalSince(start), 23 * 3600)
        let tasks = [task("all-day", ["due": "2026-03-08"]),
                     task("late", ["availableAt": "2026-03-08T23:59:59-07:00"]),
                     task("after", ["availableAt": "2026-03-09T00:00:00-07:00"])]
        XCTAssertEqual(TaskAgenda.entries(tasks: tasks, in: DateInterval(start: start, end: end), calendar: cal).map(\.id), ["all-day", "late"])
        XCTAssertEqual(TaskAgenda.entries(tasks: tasks, on: day("2026-03-08", in: cal), calendar: cal).map(\.id), ["all-day", "late"])
    }

    func testMissingClearedAndInvalidTimeBlockFallBackToDeadline() {
        let cal = calendar(), date = day("2026-10-22", in: cal)
        for available: JSON in [nil, "", "  ", "2026-10-20", "2026-02-30T10:00:00Z", "invalid", 42] {
            let source = task(["availableAt": available, "due": "2026-10-22"])
            let entries = TaskAgenda.entries(tasks: [source], on: date, calendar: cal)
            XCTAssertEqual(entries.count, 1, "\(available)")
            XCTAssertEqual(entries[0].milestones.map(\.kind), [.due])
            XCTAssertTrue(entries[0].milestones[0].isAllDay)
        }
        XCTAssertEqual(TaskAgenda.entries(tasks: [task(["due": "2026-10-22"])], on: date, calendar: cal).count, 1)
        XCTAssertTrue(TaskAgenda.entries(tasks: [task([:])], on: date, calendar: cal).isEmpty)
    }

    func testDeadlineOnlyDatesUseLocalCalendarDaysAndRejectInvalidDates() {
        for zone in ["Asia/Shanghai", "America/Los_Angeles"] {
            let cal = calendar(zone), source = task(["due": "2026-10-20"])
            let entries = TaskAgenda.entries(tasks: [source], on: day("2026-10-20", in: cal), calendar: cal)
            XCTAssertEqual(entries.count, 1)
            XCTAssertTrue(entries[0].milestones[0].isAllDay)
            XCTAssertEqual(entries[0].milestones[0].kind.title, "截止")
            XCTAssertTrue(TaskAgenda.entries(tasks: [source], on: day("2026-10-19", in: cal), calendar: cal).isEmpty)
            XCTAssertTrue(TaskAgenda.entries(tasks: [source], on: day("2026-10-21", in: cal), calendar: cal).isEmpty)
            XCTAssertTrue(TaskAgenda.entries(tasks: [task(["due": "2026-02-30"])], on: day("2026-03-02", in: cal), calendar: cal).isEmpty)
            XCTAssertTrue(TaskAgenda.entries(tasks: [task(["due": "2026-02-29"])], on: day("2026-03-01", in: cal), calendar: cal).isEmpty)
            XCTAssertEqual(TaskAgenda.entries(tasks: [task(["due": "2028-02-29"])], on: day("2028-02-29", in: cal), calendar: cal).count, 1)
        }
        let cal = calendar(), timed = task(["due": "2026-10-19T16:00:00Z"])
        let entries = TaskAgenda.entries(tasks: [timed], on: day("2026-10-20", in: cal), calendar: cal)
        XCTAssertEqual(entries.count, 1)
        XCTAssertFalse(entries[0].milestones[0].isAllDay)
        XCTAssertTrue(TaskAgenda.entries(tasks: [timed], on: day("2026-10-19", in: cal), calendar: cal).isEmpty)
    }

    func testAbsoluteTimesFollowViewerTimeZoneAndMidnightBoundaries() {
        let cal = calendar(), tasks = [task("before", ["availableAt": "2026-10-19T15:59:59.999Z"]),
                                      task("midnight", ["availableAt": "2026-10-19T16:00:00Z"]),
                                      task("end", ["availableAt": "2026-10-20T23:59:59+08:00"]),
                                      task("after", ["availableAt": "2026-10-21T00:00:00+08:00"])]
        let entries = TaskAgenda.entries(tasks: tasks, on: day("2026-10-20", in: cal), calendar: cal)
        XCTAssertEqual(entries.map(\.id), ["midnight", "end"])
        XCTAssertTrue(entries.allSatisfy { !$0.milestones[0].isAllDay })
        let western = calendar("America/Los_Angeles")
        XCTAssertEqual(TaskAgenda.entries(tasks: [tasks[1]], on: day("2026-10-19", in: western), calendar: western).map(\.id), ["midnight"])
        XCTAssertTrue(TaskAgenda.entries(tasks: [tasks[1]], on: day("2026-10-20", in: western), calendar: western).isEmpty)
    }

    func testInvalidEmptyAndDateOnlyValuesNeverInferOrRollDates() {
        let invalid: [JSON] = [nil, "", "  ", 42, true, [], [:], "2026-10-20", "2026-2-20", "2026-02-30", "2026-13-01", "2026-00-01", "0000-01-01T10:00:00Z",
                               "2026-02-30T12:00:00Z", "2026-10-20T24:00:00Z", "2026-10-20T12:60:00Z", "2026-10-20T12:00:00+08:60",
                               "2026-10-20T12:00:00", "2026-10-20 trailing", "not-a-date"]
        let cal = calendar()
        for value in invalid {
            for date in ["2026-10-20", "2026-03-02", "2027-01-01"] {
                XCTAssertTrue(TaskAgenda.entries(tasks: [task(["availableAt": value])], on: day(date, in: cal), calendar: cal).isEmpty, "\(value)")
            }
        }
        XCTAssertEqual(TaskAgenda.entries(tasks: [task(["availableAt": "2028-02-29T12:00:00+08:00"])], on: day("2028-02-29", in: cal), calendar: cal).count, 1)
        XCTAssertTrue(TaskAgenda.entries(tasks: [task(["availableAt": "2026-02-29T12:00:00+08:00"])], on: day("2026-03-01", in: cal), calendar: cal).isEmpty)
    }

    func testSortingIsStableForEarliestTimeThenTitleAndID() {
        let cal = calendar(), date = day("2026-10-20", in: cal)
        let tasks = [task("late", ["availableAt": "2026-10-20T18:00:00+08:00"]),
                     task("c", ["availableAt": "2026-10-20T10:00:00+08:00", "title": "B"]),
                     task("early", ["availableAt": "2026-10-20T09:00:00+08:00"]),
                     task("b", ["availableAt": "2026-10-20T10:00:00+08:00", "title": "A"]),
                     task("a", ["availableAt": "2026-10-20T10:00:00+08:00", "title": "A"]),
                     task("all-day", ["due": "2026-10-20"])]
        let expected = ["all-day", "early", "a", "b", "c", "late"]
        XCTAssertEqual(TaskAgenda.entries(tasks: tasks, on: date, calendar: cal).map(\.id), expected)
        XCTAssertEqual(TaskAgenda.entries(tasks: tasks.reversed(), on: date, calendar: cal).map(\.id), expected)
    }

    func testAllAuthorizedSpacesAndChildrenAppearWithoutOtherPageFilters() {
        let cal = calendar(), custom = "page-08D61B38-2CBB-4543-9EB4-C7DA47B2CC60"
        let tasks = [task("work", ["taskSpace": "work", "availableAt": "2026-10-20T12:00:00+08:00"]),
                     task("personal", ["taskSpace": "personal", "availableAt": "2026-10-20T12:00:00+08:00"]),
                     task("custom", ["taskSpace": .string(custom), "availableAt": "2026-10-20T12:00:00+08:00"]),
                     task("child", ["parentId": "work", "availableAt": "2026-10-20T12:00:00+08:00"])]
        XCTAssertEqual(Set(TaskAgenda.entries(tasks: tasks, on: day("2026-10-20", in: cal), calendar: cal).map(\.id)), Set(tasks.map(\.id)))
        XCTAssertEqual(tasks[2].taskSpace.rawValue, custom)
    }

    func testClosedAndArchivedHiddenButWaitingPausedAndOtherBlockersUnchanged() {
        let cal = calendar(), date = day("2026-10-20", in: cal)
        let statuses = ["ready", "waiting", "blocked", "paused", "information", "completed", "cancelled"]
        let tasks = statuses.map { task($0, ["status": .string($0), "availableAt": "2026-10-20T11:00:00+08:00", "blockedBy": "alice", "dependsOn": ["unfinished"]]) }
            + [task("archived", ["archived": true, "availableAt": "2026-10-20T11:00:00+08:00"])]
        let before = tasks
        let entries = TaskAgenda.entries(tasks: tasks, on: date, calendar: cal)
        XCTAssertEqual(Set(entries.map(\.id)), Set(statuses.prefix(5)))
        XCTAssertEqual(tasks, before)
        XCTAssertTrue(entries.allSatisfy { $0.task.status == $0.id && $0.task.text("blockedBy") == "alice" && $0.task["dependsOn"] == ["unfinished"] })
        XCTAssertTrue(entries.allSatisfy { $0.milestones[0].date < date }, "Passing the clock condition must not complete a task or remove its people/task blockers.")
    }

    func testDateEditsClearUndoAndReopenRemainSourceDrivenWithoutScheduleCopies() throws {
        let cal = calendar(), oldDay = day("2026-10-20", in: cal), nextDay = day("2026-10-21", in: cal)
        _ = try mutate([["type": "task.create", "task": ["id": "dated", "title": "有阻断日期的任务", "availableAt": "2026-10-20T12:00:00+08:00", "due": "2026-10-20"]],
                        ["type": "schedule.create", "block": ["id": "manual", "title": "原手动日程", "start": "2026-10-20T10:00:00+08:00", "end": "2026-10-20T11:00:00+08:00"]]])
        let initial = try runtime.readState(), bytes = try Data(contentsOf: root.appendingPathComponent("data/state.json"))
        XCTAssertEqual(TaskAgenda.entries(tasks: initial["tasks"].records, on: oldDay, calendar: cal).count, 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("data/state.json")), bytes)
        _ = try mutate([["type": "task.update", "id": "dated", "changes": ["availableAt": "2026-10-21T13:00:00+08:00"]]])
        let changed = try runtime.readState()
        XCTAssertTrue(TaskAgenda.entries(tasks: changed["tasks"].records, on: oldDay, calendar: cal).isEmpty)
        XCTAssertEqual(TaskAgenda.entries(tasks: changed["tasks"].records, on: nextDay, calendar: cal).count, 1)
        let cleared = try mutate([["type": "task.update", "id": "dated", "changes": ["availableAt": ""]]])
        XCTAssertTrue(TaskAgenda.entries(tasks: try runtime.readState()["tasks"].records, on: nextDay, calendar: cal).isEmpty)
        XCTAssertEqual(TaskAgenda.entries(tasks: try runtime.readState()["tasks"].records, on: oldDay, calendar: cal)[0].milestones.map(\.kind), [.due])
        _ = try mutate([["type": "receipt.undo", "receiptId": cleared["receipt"]["id"]]], confirmed: true)
        let reopened = try StateRuntime(root: root).readState()
        XCTAssertEqual(TaskAgenda.entries(tasks: reopened["tasks"].records, on: nextDay, calendar: cal).count, 1)
        XCTAssertEqual(reopened["scheduleBlocks"], initial["scheduleBlocks"])
        XCTAssertEqual(reopened["tasks"].array[0]["due"], "2026-10-20")
        _ = try mutate([["type": "task.update", "id": "dated", "changes": ["availableAt": nil]]])
        XCTAssertTrue(TaskAgenda.entries(tasks: try runtime.readState()["tasks"].records, on: nextDay, calendar: cal).isEmpty)
        XCTAssertEqual(TaskAgenda.entries(tasks: try runtime.readState()["tasks"].records, on: oldDay, calendar: cal)[0].milestones.map(\.kind), [.due])
        XCTAssertEqual(try runtime.readState()["scheduleBlocks"], initial["scheduleBlocks"])
    }
}
