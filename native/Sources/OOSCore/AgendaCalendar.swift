import Foundation

/// Calendar arithmetic for agenda views. All boundaries use calendar days,
/// never fixed 86,400-second offsets, so local DST transitions remain correct.
public enum AgendaCalendar {
    public enum Mode: String, CaseIterable, Sendable {
        case week, month, year
    }

    public static func interval(containing date: Date, mode: Mode, calendar: Calendar = .current) -> DateInterval {
        var local = calendar
        local.firstWeekday = 2
        local.minimumDaysInFirstWeek = 4
        let component: Calendar.Component
        switch mode {
        case .week: component = .weekOfYear
        case .month: component = .month
        case .year: component = .year
        }
        return local.dateInterval(of: component, for: date)
            ?? DateInterval(start: local.startOfDay(for: date), duration: 0)
    }

    /// Returns each local day touched by a nonempty half-open interval. Each
    /// result represents that day's start, including a partially covered day.
    public static func days(in range: DateInterval, calendar: Calendar = .current) -> [Date] {
        guard range.duration > 0 else { return [] }
        var result: [Date] = [], cursor = calendar.startOfDay(for: range.start)
        while cursor < range.end {
            result.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else { break }
            cursor = calendar.startOfDay(for: next)
        }
        return result
    }

    /// Fixed six-row grid, starting on Monday and covering the complete month.
    public static func monthGrid(containing date: Date, calendar: Calendar = .current) -> [Date] {
        let first = interval(containing: date, mode: .month, calendar: calendar).start
        let monday = interval(containing: first, mode: .week, calendar: calendar).start
        return (0..<42).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: monday).map { calendar.startOfDay(for: $0) }
        }
    }

    /// Preserves the selected day and local clock when navigating. A missing
    /// day (January 31 -> February, leap day -> next year) clamps to month end.
    public static func shifted(_ date: Date, by amount: Int, mode: Mode, calendar: Calendar = .current) -> Date {
        guard amount != 0 else { return date }
        if mode == .week {
            return calendar.date(byAdding: .weekOfYear, value: amount, to: date) ?? date
        }
        let first = interval(containing: date, mode: .month, calendar: calendar).start
        let component: Calendar.Component = mode == .month ? .month : .year
        guard let target = calendar.date(byAdding: component, value: amount, to: first),
              let validDays = calendar.range(of: .day, in: .month, for: target) else { return date }
        let source = calendar.dateComponents([.day, .hour, .minute, .second, .nanosecond], from: date)
        var destination = calendar.dateComponents([.era, .year, .month], from: target)
        destination.day = min(source.day ?? validDays.lowerBound, validDays.upperBound - 1)
        destination.hour = source.hour; destination.minute = source.minute
        destination.second = source.second; destination.nanosecond = source.nanosecond
        return calendar.date(from: destination) ?? date
    }

    /// Invalid or reversed schedules are excluded; equal endpoints represent
    /// a point event rather than spanning both dates around a midnight.
    public static func scheduleInterval(_ record: Record, calendar: Calendar = .current) -> DateInterval? {
        guard case .string(let startText) = record["start"], case .string(let endText) = record["end"],
              let start = TaskAgenda.parseDate(startText, allowsDateOnly: true, calendar: calendar)?.date,
              let end = TaskAgenda.parseDate(endText, allowsDateOnly: true, calendar: calendar)?.date,
              end >= start else { return nil }
        return DateInterval(start: start, end: end)
    }

    public static func schedules(on day: Date, from records: [Record], calendar: Calendar = .current) -> [Record] {
        guard let dayRange = calendar.dateInterval(of: .day, for: day) else { return [] }
        return records.compactMap { record -> (record: Record, start: Date)? in
            guard let range = scheduleInterval(record, calendar: calendar) else { return nil }
            let appears = range.duration == 0
                ? range.start >= dayRange.start && range.start < dayRange.end
                : range.start < dayRange.end && range.end > dayRange.start
            return appears ? (record, range.start) : nil
        }.sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.record.title != rhs.record.title { return lhs.record.title < rhs.record.title }
            return lhs.record.id < rhs.record.id
        }.map(\.record)
    }
}
