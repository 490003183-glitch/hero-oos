import Foundation

/// A read-only daily projection: a valid time-blocking condition takes priority
/// over the deadline. No schedule copies are created or maintained.
public enum TaskAgenda {
    public enum Kind: String, CaseIterable, Sendable {
        case availableAt, due

        public var title: String { self == .availableAt ? "可开始" : "截止" }
    }

    public struct Milestone: Identifiable, Equatable, Sendable {
        public let kind: Kind
        public let date: Date
        public let isAllDay: Bool
        public var id: String { kind.rawValue }
    }

    public struct Entry: Identifiable, Equatable, Sendable {
        public let task: Record
        public let milestones: [Milestone]
        public var id: String { task.id }
    }

    /// The caller supplies authorized tasks, independently of other page filters.
    /// A task's date does not imply that its other blocking conditions are met.
    public static func entries(tasks: [Record], calendar: Calendar = .current) -> [Entry] {
        tasks.compactMap { task -> Entry? in
            guard !task.isClosed, !task.isArchived else { return nil }
            // Choose the source before testing its day. A task blocked until
            // the 20th with a deadline on the 22nd belongs only to the 20th.
            let milestone = Kind.allCases.lazy.compactMap { kind -> Milestone? in
                guard case .string(let text) = task[kind.rawValue],
                      let parsed = parseDate(text, allowsDateOnly: kind == .due, calendar: calendar) else { return nil }
                return Milestone(kind: kind, date: parsed.date, isAllDay: parsed.isAllDay)
            }.first
            guard let milestone else { return nil }
            return Entry(task: task, milestones: [milestone])
        }.sorted { lhs, rhs in
            let left = lhs.milestones[0], right = rhs.milestones[0]
            let leftDay = calendar.startOfDay(for: left.date), rightDay = calendar.startOfDay(for: right.date)
            if leftDay != rightDay { return leftDay < rightDay }
            if left.isAllDay != right.isAllDay { return left.isAllDay }
            if left.date != right.date { return left.date < right.date }
            if lhs.task.title != rhs.task.title { return lhs.task.title < rhs.task.title }
            return lhs.id < rhs.id
        }
    }

    public static func entries(tasks: [Record], on day: Date, calendar: Calendar = .current) -> [Entry] {
        entries(tasks: tasks, calendar: calendar).filter { calendar.isDate($0.milestones[0].date, inSameDayAs: day) }
    }

    /// Range end is exclusive, including for a date-only deadline at local midnight.
    public static func entries(tasks: [Record], in range: DateInterval, calendar: Calendar = .current) -> [Entry] {
        guard range.duration > 0 else { return [] }
        return entries(tasks: tasks, calendar: calendar).filter {
            let date = $0.milestones[0].date
            return date >= range.start && date < range.end
        }
    }

    static func parseDate(_ input: String, allowsDateOnly: Bool, calendar: Calendar) -> (date: Date, isAllDay: Bool)? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if allowsDateOnly, text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil {
            let parts = text.split(separator: "-").compactMap { Int($0) }
            guard let date = strictDate(year: parts[0], month: parts[1], day: parts[2], calendar: calendar) else { return nil }
            return (calendar.startOfDay(for: date), true)
        }
        // Foundation's ISO formatter can normalize invalid dates. Validate the
        // written components first so February 30 never reappears in March.
        // A time condition requires an instant, not an inferred time for a
        // date-only value or an assumed zone for a bare local timestamp.
        guard text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$"#,
                         options: .regularExpression) != nil else { return nil }
        let components = String(text.prefix(19)).split(whereSeparator: { "-T:".contains($0) }).compactMap { Int($0) }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(secondsFromGMT: 0)!
        guard strictDate(year: components[0], month: components[1], day: components[2], calendar: gregorian) != nil,
              (0...23).contains(components[3]), (0...59).contains(components[4]), (0...59).contains(components[5]) else { return nil }
        if !text.hasSuffix("Z") {
            let offset = text.suffix(5).split(separator: ":").compactMap { Int($0) }
            guard (0...23).contains(offset[0]), (0...59).contains(offset[1]) else { return nil }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = text.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        guard let date = formatter.date(from: text) else { return nil }
        return (date, false)
    }

    private static func strictDate(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        // Noon avoids nonexistent midnight in time zones whose DST starts then.
        let components = DateComponents(year: year, month: month, day: day, hour: 12)
        guard year > 0, let date = calendar.date(from: components) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        guard actual.year == year, actual.month == month, actual.day == day else { return nil }
        return date
    }
}
