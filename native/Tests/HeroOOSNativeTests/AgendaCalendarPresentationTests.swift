import XCTest
@testable import OOSCore
@testable import HeroOOSNative

final class AgendaCalendarPresentationTests: XCTestCase {
    private func calendar(_ zone: String = "Asia/Shanghai") -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        return value
    }

    private func date(_ year: Int = 2026, _ month: Int = 10, _ day: Int, _ hour: Int = 12, _ minute: Int = 0, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func task(_ id: String, available: JSON = .null, due: JSON = .null, space: String = "work") -> Record {
        Record(["id": .string(id), "title": .string(id), "status": "ready", "taskSpace": .string(space), "availableAt": available, "due": due])
    }

    private func schedule(_ id: String, _ start: String, _ end: String) -> Record {
        Record(["id": .string(id), "title": .string(id), "start": .string(start), "end": .string(end)])
    }

    func testSnapshotChoosesSourceBeforeRangeAndGroupsEachTaskOnlyOnce() {
        let cal = calendar(), selected = date(2026, 10, 20, calendar: cal)
        let tasks = [task("priority", available: "2026-10-20T13:00:00+08:00", due: "2026-10-22"),
                     task("outside-priority", available: "2026-11-01T13:00:00+08:00", due: "2026-10-20"),
                     task("fallback", due: "2026-10-22", space: "personal"),
                     task("invalid-fallback", available: "invalid", due: "2026-10-20")]
        let original = tasks
        let snapshot = AgendaCalendarSnapshot(tasks: tasks, schedules: [], date: selected, mode: .week, calendar: cal)
        XCTAssertEqual(snapshot.items(on: selected).map(\.id), ["task:invalid-fallback", "task:priority"])
        XCTAssertEqual(snapshot.items(on: date(2026, 10, 22, calendar: cal)).map(\.id), ["task:fallback"])
        XCTAssertTrue(snapshot.items(on: date(2026, 11, 1, calendar: cal)).isEmpty)
        let items = AgendaCalendar.days(in: snapshot.range, calendar: cal).flatMap { snapshot.items(on: $0) }
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(Set(items.map(\.id)).count, 3)
        XCTAssertEqual(tasks, original)
        let marker = snapshot.items(on: selected).first { $0.id == "task:priority" }!
        XCTAssertEqual(marker.start, marker.end)
        XCTAssertEqual(marker.sourceTitle, "阻断日期")
        XCTAssertNil(marker.schedule)
        XCTAssertEqual(marker.task?.task, tasks[0])
    }

    func testSnapshotKeepsScheduleCrossDayMembershipAndExclusiveEnd() {
        let cal = calendar(), selected = date(2026, 10, 20, calendar: cal)
        let spanning = schedule("spanning", "2026-10-18T23:00:00+08:00", "2026-10-21T00:00:00+08:00")
        let endsAtRange = schedule("before", "2026-10-18T22:00:00+08:00", "2026-10-19T00:00:00+08:00")
        let point = schedule("point", "2026-10-21T00:00:00+08:00", "2026-10-21T00:00:00+08:00")
        let records = [spanning, endsAtRange, point]
        let snapshot = AgendaCalendarSnapshot(tasks: [], schedules: records, date: selected, mode: .week, calendar: cal)
        for day in [19, 20] {
            let items = snapshot.items(on: date(2026, 10, day, calendar: cal))
            XCTAssertEqual(items.map(\.id), ["schedule:spanning"])
            XCTAssertEqual(items[0].schedule, spanning)
            XCTAssertEqual(items[0].start, RuntimeDate.parse(spanning.text("start")))
            XCTAssertEqual(items[0].end, RuntimeDate.parse(spanning.text("end")))
            XCTAssertNil(items[0].task)
        }
        XCTAssertEqual(snapshot.items(on: date(2026, 10, 21, calendar: cal)).map(\.id), ["schedule:point"])
        XCTAssertTrue(snapshot.items(on: date(2026, 10, 22, calendar: cal)).isEmpty)
        XCTAssertTrue(snapshot.items(on: date(2026, 10, 18, calendar: cal)).isEmpty)
    }

    func testMonthSnapshotIncludesAll42VisibleCellsAndExcludesFollowingDay() {
        let cal = calendar(), selected = date(2026, 10, 20, calendar: cal)
        let tasks = [task("left-overflow", due: "2026-09-28"), task("right-overflow", due: "2026-11-08"),
                     task("too-early", due: "2026-09-27"), task("too-late", due: "2026-11-09")]
        let snapshot = AgendaCalendarSnapshot(tasks: tasks, schedules: [], date: selected, mode: .month, calendar: cal)
        XCTAssertEqual(snapshot.range.start, date(2026, 9, 28, 0, calendar: cal))
        XCTAssertEqual(snapshot.range.end, date(2026, 11, 9, 0, calendar: cal))
        XCTAssertEqual(AgendaCalendar.days(in: snapshot.range, calendar: cal).count, 42)
        XCTAssertEqual(snapshot.items(on: date(2026, 9, 28, calendar: cal)).map(\.id), ["task:left-overflow"])
        XCTAssertEqual(snapshot.items(on: date(2026, 11, 8, calendar: cal)).map(\.id), ["task:right-overflow"])
        XCTAssertTrue(snapshot.items(on: date(2026, 9, 27, calendar: cal)).isEmpty)
        XCTAssertTrue(snapshot.items(on: date(2026, 11, 9, calendar: cal)).isEmpty)
    }

    func testYearSnapshotIncludesLastDayPointsButNotNextYearMidnight() {
        let cal = calendar(), selected = date(2026, 10, 20, calendar: cal)
        let schedules = [schedule("first", "2026-01-01T00:00:00+08:00", "2026-01-01T00:00:00+08:00"),
                         schedule("last", "2026-12-31T23:59:59+08:00", "2026-12-31T23:59:59+08:00"),
                         schedule("next", "2027-01-01T00:00:00+08:00", "2027-01-01T00:00:00+08:00"),
                         schedule("past", "2025-12-31T12:00:00+08:00", "2026-01-01T00:00:00+08:00")]
        let tasks = [task("last-task", available: "2026-12-31T23:59:59+08:00"), task("next-task", due: "2027-01-01")]
        let snapshot = AgendaCalendarSnapshot(tasks: tasks, schedules: schedules, date: selected, mode: .year, calendar: cal)
        XCTAssertEqual(snapshot.items(on: date(2026, 1, 1, calendar: cal)).map(\.id), ["schedule:first"])
        XCTAssertEqual(Set(snapshot.items(on: date(2026, 12, 31, calendar: cal)).map(\.id)), ["schedule:last", "task:last-task"])
        XCTAssertTrue(snapshot.items(on: date(2027, 1, 1, calendar: cal)).isEmpty)
        XCTAssertEqual(AgendaCalendar.days(in: snapshot.range, calendar: cal).count, 365)
    }

    func testSnapshotUsesLocalDaysAcrossDSTAndKeepsIDsNamespaced() {
        let cal = calendar("America/Los_Angeles"), selected = date(2026, 3, 8, calendar: cal)
        let source = task("same", available: "2026-03-09T06:30:00Z")
        let manual = schedule("same", "2026-03-08T00:00:00-08:00", "2026-03-09T00:00:00-07:00")
        let snapshot = AgendaCalendarSnapshot(tasks: [source], schedules: [manual], date: selected, mode: .month, calendar: cal)
        let items = snapshot.items(on: selected)
        XCTAssertEqual(Set(items.map(\.id)), ["task:same", "schedule:same"])
        XCTAssertEqual(items.first { $0.task != nil }?.start, date(2026, 3, 8, 23, 30, calendar: cal))
        XCTAssertTrue(snapshot.items(on: date(2026, 3, 9, calendar: cal)).isEmpty)
    }

    func testWeekPlacementSeparatesConcurrentTaskMarkersAndLongSchedule() {
        let cal = calendar(), selected = date(2026, 10, 20, calendar: cal)
        let tasks = [task("one", available: "2026-10-20T10:00:00+08:00"), task("two", available: "2026-10-20T10:00:00+08:00")]
        let manual = schedule("long", "2026-10-20T09:00:00+08:00", "2026-10-20T13:00:00+08:00")
        let snapshot = AgendaCalendarSnapshot(tasks: tasks, schedules: [manual], date: selected, mode: .week, calendar: cal)
        let placements = AgendaWeekPlacement.layout(snapshot.items(on: selected), on: selected, calendar: cal)
        XCTAssertEqual(placements.count, 3)
        XCTAssertEqual(Set(placements.map(\.lane)).count, 3)
        XCTAssertTrue(placements.allSatisfy { $0.laneCount == 3 })
        XCTAssertTrue(placements.filter { $0.item.task != nil }.allSatisfy { $0.minute == 600 && $0.item.start == $0.item.end })
        let long = placements.first { $0.id == "schedule:long" }!
        XCTAssertEqual(long.minute, 540)
        XCTAssertEqual(long.bottom, 780)
    }

    func testWeekPlacementReusesLaneForAdjacentNonOverlappingSchedules() {
        let cal = calendar(), selected = date(2026, 10, 20, calendar: cal)
        let records = [schedule("first", "2026-10-20T09:00:00+08:00", "2026-10-20T10:00:00+08:00"),
                       schedule("second", "2026-10-20T10:00:00+08:00", "2026-10-20T11:00:00+08:00"),
                       schedule("third", "2026-10-20T11:00:00+08:00", "2026-10-20T12:00:00+08:00")]
        let snapshot = AgendaCalendarSnapshot(tasks: [], schedules: records, date: selected, mode: .week, calendar: cal)
        let placements = AgendaWeekPlacement.layout(snapshot.items(on: selected), on: selected, calendar: cal)
        XCTAssertEqual(placements.map(\.lane), [0, 0, 0])
        XCTAssertEqual(placements.map(\.laneCount), [1, 1, 1])
        XCTAssertEqual(placements.map(\.minute), [540, 600, 660])
        XCTAssertEqual(placements.map(\.bottom), [600, 660, 720])
    }

    func testWeekPlacementExcludesAllDayAndClampsCrossMidnightWithoutLosingHitTargets() {
        let cal = calendar(), selected = date(2026, 10, 20, calendar: cal)
        let tasks = [task("all-day", due: "2026-10-20"), task("late-point", available: "2026-10-20T23:59:00+08:00")]
        let records = [schedule("carry-in", "2026-10-19T23:00:00+08:00", "2026-10-20T02:00:00+08:00"),
                       schedule("carry-out", "2026-10-20T23:30:00+08:00", "2026-10-21T03:00:00+08:00"),
                       schedule("long-out", "2026-10-20T22:00:00+08:00", "2026-10-21T03:00:00+08:00")]
        let snapshot = AgendaCalendarSnapshot(tasks: tasks, schedules: records, date: selected, mode: .week, calendar: cal)
        XCTAssertEqual(snapshot.items(on: selected).first?.id, "task:all-day")
        let placements = AgendaWeekPlacement.layout(snapshot.items(on: selected), on: selected, calendar: cal)
        XCTAssertEqual(Set(placements.map(\.id)), ["task:late-point", "schedule:carry-in", "schedule:carry-out", "schedule:long-out"])
        XCTAssertTrue(placements.allSatisfy { $0.minute >= 0 && $0.bottom <= max(1440, $0.minute + 54) && $0.bottom >= $0.minute })
        let incoming = placements.first { $0.id == "schedule:carry-in" }!
        XCTAssertEqual(incoming.minute, 0)
        XCTAssertEqual(incoming.bottom, 120)
        let outgoing = placements.first { $0.id == "schedule:carry-out" }!
        XCTAssertEqual(outgoing.minute, 1410)
        XCTAssertEqual(outgoing.bottom, 1464, "Minimum visual hit area may extend past midnight; it does not change the underlying schedule.")
        XCTAssertEqual(outgoing.item.end, RuntimeDate.parse(records[1].text("end")))
        let long = placements.first { $0.id == "schedule:long-out" }!
        XCTAssertEqual(long.minute, 1320)
        XCTAssertEqual(long.bottom, 1440, "A cross-day interval's displayed duration stops at the selected day boundary.")
        XCTAssertEqual(long.item.end, RuntimeDate.parse(records[2].text("end")))
        let point = placements.first { $0.id == "task:late-point" }!
        XCTAssertEqual(point.minute, 1439)
        XCTAssertEqual(point.bottom, 1493)
        XCTAssertEqual(point.item.start, point.item.end)
        XCTAssertNotEqual(point.lane, outgoing.lane)
    }

    func testWeekPlacementSharesOverlapGroupWidthAndReusesFreedLane() {
        let cal = calendar(), selected = date(2026, 10, 20, calendar: cal)
        let records = [schedule("long", "2026-10-20T09:00:00+08:00", "2026-10-20T13:00:00+08:00"),
                       schedule("early-short", "2026-10-20T09:00:00+08:00", "2026-10-20T10:00:00+08:00"),
                       schedule("later-short", "2026-10-20T10:00:00+08:00", "2026-10-20T11:00:00+08:00"),
                       schedule("independent", "2026-10-20T14:00:00+08:00", "2026-10-20T15:00:00+08:00")]
        let snapshot = AgendaCalendarSnapshot(tasks: [], schedules: records, date: selected, mode: .week, calendar: cal)
        let placements = AgendaWeekPlacement.layout(snapshot.items(on: selected), on: selected, calendar: cal)
        let early = placements.first { $0.id == "schedule:early-short" }!
        let later = placements.first { $0.id == "schedule:later-short" }!
        let long = placements.first { $0.id == "schedule:long" }!
        XCTAssertEqual(early.lane, later.lane)
        XCTAssertNotEqual(early.lane, long.lane)
        XCTAssertTrue([early, later, long].allSatisfy { $0.laneCount == 2 })
        XCTAssertEqual(placements.first { $0.id == "schedule:independent" }?.laneCount, 1)
        XCTAssertEqual(placements.map(\.id), AgendaWeekPlacement.layout(snapshot.items(on: selected).reversed(), on: selected, calendar: cal).map(\.id))
    }
}
