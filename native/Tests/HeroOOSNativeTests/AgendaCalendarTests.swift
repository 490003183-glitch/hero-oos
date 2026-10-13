import XCTest
@testable import OOSCore

final class AgendaCalendarTests: XCTestCase {
    private func calendar(_ zone: String = "Asia/Shanghai") -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        value.firstWeekday = 1 // The agenda must use Monday even for a Sunday-first locale.
        return value
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func schedule(_ id: String, start: JSON, end: JSON, title: String? = nil) -> Record {
        Record(["id": .string(id), "title": .string(title ?? id), "start": start, "end": end])
    }

    func testWeekIntervalAlwaysStartsMondayAndCanCrossYearBoundary() {
        let cal = calendar()
        let expected = DateInterval(start: date(2025, 12, 29, in: cal), end: date(2026, 1, 5, in: cal))
        for selected in [date(2025, 12, 29, in: cal), date(2026, 1, 1, 14, 30, in: cal), date(2026, 1, 4, 23, 59, in: cal)] {
            XCTAssertEqual(AgendaCalendar.interval(containing: selected, mode: .week, calendar: cal), expected)
        }
        XCTAssertEqual(AgendaCalendar.interval(containing: expected.end, mode: .week, calendar: cal).start, expected.end)
    }

    func testMonthAndYearIntervalsUseCalendarBoundariesAndLeapYears() {
        let cal = calendar(), leapDay = date(2028, 2, 29, 17, 40, in: cal)
        let month = AgendaCalendar.interval(containing: leapDay, mode: .month, calendar: cal)
        XCTAssertEqual(month, DateInterval(start: date(2028, 2, 1, in: cal), end: date(2028, 3, 1, in: cal)))
        XCTAssertEqual(AgendaCalendar.days(in: month, calendar: cal).count, 29)
        let year = AgendaCalendar.interval(containing: leapDay, mode: .year, calendar: cal)
        XCTAssertEqual(year, DateInterval(start: date(2028, 1, 1, in: cal), end: date(2029, 1, 1, in: cal)))
        XCTAssertEqual(AgendaCalendar.days(in: year, calendar: cal).count, 366)
        let december = AgendaCalendar.interval(containing: date(2026, 12, 31, 23, 59, in: cal), mode: .month, calendar: cal)
        XCTAssertEqual(december.end, date(2027, 1, 1, in: cal))
    }

    func testDaysIncludesPartialStartingDayButExcludesAnExactEndingMidnight() {
        let cal = calendar(), first = date(2026, 10, 19, in: cal), second = date(2026, 10, 20, in: cal)
        let partial = DateInterval(start: date(2026, 10, 19, 15, 30, in: cal), end: date(2026, 10, 21, in: cal))
        XCTAssertEqual(AgendaCalendar.days(in: partial, calendar: cal), [first, second])
        let sameDay = DateInterval(start: date(2026, 10, 19, 15, in: cal), end: date(2026, 10, 19, 16, in: cal))
        XCTAssertEqual(AgendaCalendar.days(in: sameDay, calendar: cal), [first])
        XCTAssertTrue(AgendaCalendar.days(in: DateInterval(start: first, duration: 0), calendar: cal).isEmpty)
    }

    func testDaysAdvanceByLocalCalendarDayAcrossBothDSTTransitions() {
        let cal = calendar("America/Los_Angeles")
        let spring = AgendaCalendar.days(in: DateInterval(start: date(2026, 3, 7, in: cal), end: date(2026, 3, 10, in: cal)), calendar: cal)
        XCTAssertEqual(spring, [date(2026, 3, 7, in: cal), date(2026, 3, 8, in: cal), date(2026, 3, 9, in: cal)])
        XCTAssertEqual(spring[2].timeIntervalSince(spring[1]), 23 * 60 * 60)
        let autumn = AgendaCalendar.days(in: DateInterval(start: date(2026, 10, 31, in: cal), end: date(2026, 11, 3, in: cal)), calendar: cal)
        XCTAssertEqual(autumn, [date(2026, 10, 31, in: cal), date(2026, 11, 1, in: cal), date(2026, 11, 2, in: cal)])
        XCTAssertEqual(autumn[2].timeIntervalSince(autumn[1]), 25 * 60 * 60)
        XCTAssertTrue((spring + autumn).allSatisfy { $0 == cal.startOfDay(for: $0) })
    }

    func testMonthGridHas42MondayFirstDaysAndContainsEntireMonth() {
        let cal = calendar()
        for (year, month) in [(2026, 2), (2026, 3), (2026, 12), (2028, 2)] {
            let selected = date(year, month, 15, 13, in: cal)
            let grid = AgendaCalendar.monthGrid(containing: selected, calendar: cal)
            XCTAssertEqual(grid.count, 42)
            XCTAssertEqual(Set(grid).count, 42)
            XCTAssertEqual(cal.component(.weekday, from: grid[0]), 2)
            XCTAssertTrue(grid.allSatisfy { $0 == cal.startOfDay(for: $0) })
            for index in 1..<grid.count {
                XCTAssertEqual(grid[index], cal.date(byAdding: .day, value: 1, to: grid[index - 1]))
            }
            let monthDays = AgendaCalendar.days(in: AgendaCalendar.interval(containing: selected, mode: .month, calendar: cal), calendar: cal)
            XCTAssertTrue(Set(monthDays).isSubset(of: Set(grid)))
        }
        let february = AgendaCalendar.monthGrid(containing: date(2026, 2, 1, in: cal), calendar: cal)
        XCTAssertEqual(february.first, date(2026, 1, 26, in: cal))
        XCTAssertEqual(february.last, date(2026, 3, 8, in: cal))
        let december = AgendaCalendar.monthGrid(containing: date(2026, 12, 31, in: cal), calendar: cal)
        XCTAssertEqual(december.first, date(2026, 11, 30, in: cal))
        XCTAssertEqual(december.last, date(2027, 1, 10, in: cal))
    }

    func testShiftingClampsMissingMonthDaysAndPreservesLocalTime() {
        let cal = calendar(), january = date(2026, 1, 31, 15, 45, in: cal)
        XCTAssertEqual(AgendaCalendar.shifted(january, by: 1, mode: .month, calendar: cal), date(2026, 2, 28, 15, 45, in: cal))
        XCTAssertEqual(AgendaCalendar.shifted(january, by: -1, mode: .month, calendar: cal), date(2025, 12, 31, 15, 45, in: cal))
        XCTAssertEqual(AgendaCalendar.shifted(january, by: 2, mode: .month, calendar: cal), date(2026, 3, 31, 15, 45, in: cal))
        XCTAssertEqual(AgendaCalendar.shifted(date(2028, 1, 31, 15, 45, in: cal), by: 1, mode: .month, calendar: cal), date(2028, 2, 29, 15, 45, in: cal))
        let leap = date(2028, 2, 29, 15, 45, in: cal)
        XCTAssertEqual(AgendaCalendar.shifted(leap, by: 1, mode: .year, calendar: cal), date(2029, 2, 28, 15, 45, in: cal))
        XCTAssertEqual(AgendaCalendar.shifted(leap, by: -4, mode: .year, calendar: cal), date(2024, 2, 29, 15, 45, in: cal))
        for mode in AgendaCalendar.Mode.allCases {
            XCTAssertEqual(AgendaCalendar.shifted(leap, by: 0, mode: mode, calendar: cal), leap)
        }
    }

    func testWeekShiftPreservesWallClockAcrossDSTRatherThanAddingFixedSeconds() {
        let cal = calendar("America/Los_Angeles"), before = date(2026, 3, 1, 15, 45, in: cal), after = date(2026, 3, 8, 15, 45, in: cal)
        XCTAssertEqual(AgendaCalendar.shifted(before, by: 1, mode: .week, calendar: cal), after)
        XCTAssertEqual(AgendaCalendar.shifted(after, by: -1, mode: .week, calendar: cal), before)
        XCTAssertEqual(after.timeIntervalSince(before), 7 * 24 * 60 * 60 - 60 * 60)
    }

    func testScheduleIntervalsIntersectEachDayWithoutIncludingEndingMidnight() {
        let cal = calendar(), event = schedule("overnight", start: "2026-10-19T23:00:00+08:00", end: "2026-10-21T00:00:00+08:00")
        XCTAssertTrue(AgendaCalendar.schedules(on: date(2026, 10, 18, 12, in: cal), from: [event], calendar: cal).isEmpty)
        for day in [19, 20] {
            XCTAssertEqual(AgendaCalendar.schedules(on: date(2026, 10, day, 12, in: cal), from: [event], calendar: cal), [event])
        }
        XCTAssertTrue(AgendaCalendar.schedules(on: date(2026, 10, 21, in: cal), from: [event], calendar: cal).isEmpty)
        let allDay = schedule("all-day", start: "2026-10-20", end: "2026-10-21")
        XCTAssertEqual(AgendaCalendar.schedules(on: date(2026, 10, 20, in: cal), from: [allDay], calendar: cal), [allDay])
        XCTAssertTrue(AgendaCalendar.schedules(on: date(2026, 10, 21, in: cal), from: [allDay], calendar: cal).isEmpty)
    }

    func testPointScheduleAppearsOnlyOnItsLocalDayIncludingMidnight() {
        let cal = calendar(), event = schedule("point", start: "2026-10-19T16:00:00Z", end: "2026-10-19T16:00:00Z")
        XCTAssertEqual(AgendaCalendar.scheduleInterval(event, calendar: cal), DateInterval(start: date(2026, 10, 20, in: cal), duration: 0))
        XCTAssertEqual(AgendaCalendar.schedules(on: date(2026, 10, 20, 12, in: cal), from: [event], calendar: cal), [event])
        XCTAssertTrue(AgendaCalendar.schedules(on: date(2026, 10, 19, in: cal), from: [event], calendar: cal).isEmpty)
        XCTAssertTrue(AgendaCalendar.schedules(on: date(2026, 10, 21, in: cal), from: [event], calendar: cal).isEmpty)
        let western = calendar("America/Los_Angeles")
        XCTAssertEqual(AgendaCalendar.schedules(on: date(2026, 10, 19, in: western), from: [event], calendar: western), [event])
        XCTAssertTrue(AgendaCalendar.schedules(on: date(2026, 10, 20, in: western), from: [event], calendar: western).isEmpty)
    }

    func testDateOnlySchedulesUseLocalMidnightInEveryViewerTimeZone() {
        let event = schedule("date", start: "2028-02-29", end: "2028-03-01")
        for zone in ["Asia/Shanghai", "America/Los_Angeles", "Pacific/Auckland"] {
            let cal = calendar(zone)
            XCTAssertEqual(AgendaCalendar.schedules(on: date(2028, 2, 29, 23, 59, in: cal), from: [event], calendar: cal), [event])
            XCTAssertTrue(AgendaCalendar.schedules(on: date(2028, 2, 28, 23, 59, in: cal), from: [event], calendar: cal).isEmpty)
            XCTAssertTrue(AgendaCalendar.schedules(on: date(2028, 3, 1, in: cal), from: [event], calendar: cal).isEmpty)
        }
    }

    func testSchedulesRespectShortAndLongDSTDays() {
        let cal = calendar("America/Los_Angeles")
        let spring = schedule("spring", start: "2026-03-08T00:00:00-08:00", end: "2026-03-09T00:00:00-07:00")
        let afterSpring = schedule("after-spring", start: "2026-03-09T00:30:00-07:00", end: "2026-03-09T00:45:00-07:00")
        XCTAssertEqual(AgendaCalendar.schedules(on: date(2026, 3, 8, 12, in: cal), from: [spring, afterSpring], calendar: cal), [spring])
        XCTAssertEqual(AgendaCalendar.schedules(on: date(2026, 3, 9, in: cal), from: [spring, afterSpring], calendar: cal), [afterSpring])
        let lateAutumn = schedule("late-autumn", start: "2026-11-01T23:30:00-08:00", end: "2026-11-02T00:00:00-08:00")
        XCTAssertEqual(AgendaCalendar.schedules(on: date(2026, 11, 1, in: cal), from: [lateAutumn], calendar: cal), [lateAutumn])
        XCTAssertTrue(AgendaCalendar.schedules(on: date(2026, 11, 2, in: cal), from: [lateAutumn], calendar: cal).isEmpty)
    }

    func testInvalidMissingAndReversedScheduleDatesAreExcludedWithoutMutation() {
        let cal = calendar(), selected = date(2026, 10, 20, in: cal)
        let invalid: [JSON] = [nil, "", "invalid", 42, true, [], [:], "2026-02-30", "2026-13-01", "2026-10-20T24:00:00Z", "2026-10-20T10:00:00", "2026-10-20 trailing"]
        var records: [Record] = []
        for (index, value) in invalid.enumerated() {
            records.append(schedule("bad-start-\(index)", start: value, end: "2026-10-21"))
            records.append(schedule("bad-end-\(index)", start: "2026-10-20", end: value))
        }
        records.append(Record(["id": "missing-end", "title": "No end", "start": "2026-10-20"]))
        records.append(Record(["id": "missing-start", "title": "No start", "end": "2026-10-21"]))
        records.append(schedule("reversed", start: "2026-10-20T12:00:00+08:00", end: "2026-10-20T11:00:00+08:00"))
        let original = records
        XCTAssertTrue(records.allSatisfy { AgendaCalendar.scheduleInterval($0, calendar: cal) == nil })
        XCTAssertTrue(AgendaCalendar.schedules(on: selected, from: records, calendar: cal).isEmpty)
        XCTAssertEqual(records, original)
        XCTAssertTrue(AgendaCalendar.schedules(on: date(2026, 3, 2, in: cal), from: [schedule("invalid-day", start: "2026-02-30", end: "2026-03-03")], calendar: cal).isEmpty)
    }

    func testScheduleSortingUsesStartThenTitleThenIDAndPreservesSourceRecords() {
        let cal = calendar(), day = date(2026, 10, 20, in: cal)
        let records = [schedule("late", start: "2026-10-20T18:00:00+08:00", end: "2026-10-20T19:00:00+08:00"),
                       schedule("c", start: "2026-10-20T10:00:00+08:00", end: "2026-10-20T11:00:00+08:00", title: "B"),
                       schedule("b", start: "2026-10-20T10:00:00+08:00", end: "2026-10-20T11:00:00+08:00", title: "A"),
                       schedule("a", start: "2026-10-20T02:00:00Z", end: "2026-10-20T03:00:00Z", title: "A"),
                       schedule("early", start: "2026-10-20T09:00:00+08:00", end: "2026-10-20T09:30:00+08:00"),
                       schedule("all-day", start: "2026-10-20", end: "2026-10-21")]
        let original = records, expected = ["all-day", "early", "a", "b", "c", "late"]
        XCTAssertEqual(AgendaCalendar.schedules(on: day, from: records, calendar: cal).map(\.id), expected)
        XCTAssertEqual(AgendaCalendar.schedules(on: day, from: records.reversed(), calendar: cal).map(\.id), expected)
        XCTAssertEqual(records, original)
        XCTAssertEqual(Set(AgendaCalendar.schedules(on: day, from: records, calendar: cal).map(\.id)), Set(records.map(\.id)))
    }
}
