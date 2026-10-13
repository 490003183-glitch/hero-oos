import SwiftUI

extension AgendaCalendar.Mode {
    var title: String {
        switch self { case .week: return "周"; case .month: return "月"; case .year: return "年" }
    }
}

enum AgendaCalendarText {
    static let weekdays = ["一", "二", "三", "四", "五", "六", "日"]
    static func day(_ date: Date) -> String { format(date, "M月d日 EEEE") }
    static func period(_ date: Date, mode: AgendaCalendar.Mode) -> String {
        switch mode {
        case .year: return format(date, "yyyy年")
        case .month: return format(date, "yyyy年 M月")
        case .week:
            let interval = AgendaCalendar.interval(containing: date, mode: .week)
            return format(interval.start, "yyyy年 M月d日") + " — " + format(interval.end.addingTimeInterval(-1), "M月d日")
        }
    }
    static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = .current; formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

/// Presentation only. A task marker is not converted into a schedule or given a duration.
struct AgendaCalendarItem: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let task: TaskAgenda.Entry?
    let schedule: Record?
    var color: Color {
        guard let task else { return .purple }
        return task.milestones.first?.kind == .availableAt ? .orange : .blue
    }
    var sourceTitle: String {
        guard let task else { return "手动日程" }
        return task.milestones.first?.kind == .availableAt ? "阻断日期" : "截止日期"
    }
    var timeLabel: String { isAllDay ? "全天" : AgendaCalendarText.format(start, "HH:mm") }
    var help: String {
        let when = AgendaCalendarText.format(start, isAllDay ? "yyyy年M月d日" : "yyyy年M月d日 HH:mm")
        let until = schedule != nil && end > start ? " — " + AgendaCalendarText.format(end, "M月d日 HH:mm") : ""
        return "\(title)\n\(sourceTitle) · \(when)\(until)" + (task?.task.taskSpace == .personal ? " · 私人" : "")
    }
}

/// Parse each source once, then index by local day. The year view never reparses
/// the full task list once per calendar cell, and it never changes source data.
struct AgendaCalendarSnapshot {
    let calendar: Calendar
    let range: DateInterval
    private let byDay: [Date: [AgendaCalendarItem]]

    init(tasks: [Record], schedules: [Record], date: Date, mode: AgendaCalendar.Mode, calendar: Calendar = .current) {
        self.calendar = calendar
        if mode == .month {
            let grid = AgendaCalendar.monthGrid(containing: date, calendar: calendar)
            range = DateInterval(start: grid[0], end: calendar.date(byAdding: .day, value: 1, to: grid[41])!)
        } else { range = AgendaCalendar.interval(containing: date, mode: mode, calendar: calendar) }
        var index: [Date: [AgendaCalendarItem]] = [:]
        for entry in TaskAgenda.entries(tasks: tasks, in: range, calendar: calendar) {
            guard let marker = entry.milestones.first else { continue }
            let item = AgendaCalendarItem(id: "task:" + entry.id, title: entry.task.title, start: marker.date, end: marker.date,
                                          isAllDay: marker.isAllDay, task: entry, schedule: nil)
            index[calendar.startOfDay(for: marker.date), default: []].append(item)
        }
        for block in schedules {
            guard let interval = AgendaCalendar.scheduleInterval(block, calendar: calendar), interval.start < range.end,
                  interval.end > range.start || (interval.duration == 0 && interval.start >= range.start) else { continue }
            let item = AgendaCalendarItem(id: "schedule:" + block.id, title: block.title, start: interval.start, end: interval.end,
                                          isAllDay: false, task: nil, schedule: block)
            var day = calendar.startOfDay(for: max(interval.start, range.start))
            repeat {
                index[day, default: []].append(item)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
                day = next
            } while day < interval.end && day < range.end
        }
        byDay = index.mapValues { items in
            items.sorted {
                if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.title != $1.title { return $0.title < $1.title }
                return $0.id < $1.id
            }
        }
    }
    func items(on day: Date) -> [AgendaCalendarItem] { byDay[calendar.startOfDay(for: day)] ?? [] }
}

/// Minimum visual height is only for hit targets. Labels always show the actual
/// time; task markers do not acquire an implied one-hour duration.
struct AgendaWeekPlacement: Identifiable {
    let item: AgendaCalendarItem
    let minute: Double
    let bottom: Double
    var lane: Int = 0
    var laneCount: Int = 1
    var id: String { item.id }

    static func layout(_ items: [AgendaCalendarItem], on day: Date, calendar: Calendar = .current) -> [Self] {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        func minute(_ date: Date) -> Double {
            if date <= start { return 0 }; if date >= end { return 1440 }
            let c = calendar.dateComponents([.hour, .minute, .second], from: date)
            return Double(c.hour! * 60 + c.minute!) + Double(c.second!) / 60
        }
        var values: [AgendaWeekPlacement] = []
        for item in items where !item.isAllDay {
            let top = minute(item.start)
            // A late-night marker keeps its true start position and extends
            // into the timeline's 58pt footer, instead of becoming a 1px target.
            let bottom = max(top + 54.0, minute(item.end))
            values.append(AgendaWeekPlacement(item: item, minute: top, bottom: bottom))
        }
        values.sort { lhs, rhs in lhs.minute == rhs.minute ? lhs.id < rhs.id : lhs.minute < rhs.minute }
        var result: [Self] = [], group: [Self] = [], laneEnds: [Double] = [], groupEnd = -1.0
        func finishGroup() {
            result += group.map { var item = $0; item.laneCount = laneEnds.count; return item }
            group = []; laneEnds = []; groupEnd = -1
        }
        for var value in values {
            if value.minute >= groupEnd { finishGroup() }
            let lane = laneEnds.firstIndex { $0 <= value.minute } ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(value.bottom) } else { laneEnds[lane] = value.bottom }
            value.lane = lane; group.append(value); groupEnd = max(groupEnd, value.bottom)
        }
        finishGroup(); return result
    }
}

struct AgendaCalendarLegend: View {
    var body: some View {
        HStack(spacing: 12) {
            marker("阻断日期", .orange); marker("截止日期", .blue); marker("手动日程", .purple)
        }.foregroundStyle(.secondary)
    }
    private func marker(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) { Circle().fill(color).frame(width: 6, height: 6); Text(title) }
    }
}

struct AgendaCalendarContent: View {
    let date: Date
    let mode: AgendaCalendar.Mode
    let snapshot: AgendaCalendarSnapshot
    let selectDay: (Date) -> Void
    let selectMonth: (Date) -> Void
    let openItem: (AgendaCalendarItem) -> Void
    var body: some View {
        Group {
            switch mode {
            case .week: AgendaWeekView(date: date, snapshot: snapshot, selectDay: selectDay, openItem: openItem)
            case .month: AgendaMonthView(date: date, snapshot: snapshot, selectDay: selectDay, openItem: openItem)
            case .year: AgendaYearView(date: date, snapshot: snapshot, selectDay: selectDay, selectMonth: selectMonth)
            }
        }.taskDetailClickTarget()
    }
}

private struct AgendaChip: View {
    let item: AgendaCalendarItem
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(item.color).frame(width: 3)
                Text(item.timeLabel).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(item.color)
                Text(item.title).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 0)
            }.padding(.vertical, 3).padding(.horizontal, 3).frame(height: 23)
                .background(item.color.opacity(0.13), in: RoundedRectangle(cornerRadius: 4)).contentShape(Rectangle())
        }.buttonStyle(.plain).help(item.help).accessibilityLabel(item.help)
    }
}

private struct AgendaMonthView: View {
    let date: Date
    let snapshot: AgendaCalendarSnapshot
    let selectDay: (Date) -> Void
    let openItem: (AgendaCalendarItem) -> Void
    var body: some View {
        GeometryReader { geometry in
            let days = AgendaCalendar.monthGrid(containing: date)
            let cellHeight = max(76, (geometry.size.height - 28) / 6)
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(0..<7) { column in Text("周" + AgendaCalendarText.weekdays[column]).font(.caption).foregroundStyle(column > 4 ? .secondary : .primary).frame(maxWidth: .infinity) }
                    }.frame(height: 28)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 0), count: 7), spacing: 0) {
                        ForEach(days, id: \.self) { day in
                            monthCell(day, height: cellHeight)
                        }
                    }
                }
            }
        }
    }
    private func monthCell(_ day: Date, height: CGFloat) -> some View {
        let cal = snapshot.calendar
        let active = cal.isDate(day, inSameDayAs: date)
        let currentMonth = cal.isDate(day, equalTo: date, toGranularity: .month)
        let items = snapshot.items(on: day)
        let capacity = max(1, min(5, Int((height - 30) / 25)))
        let shown = items.count > capacity ? max(0, capacity - 1) : capacity
        return ZStack(alignment: .topLeading) {
            Button { selectDay(day) } label: {
                Rectangle().fill(active ? Color.accentColor.opacity(0.12) : Color.primary.opacity(currentMonth ? 0.015 : 0.045))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(AgendaCalendarText.day(day))
            VStack(alignment: .leading, spacing: 2) {
                Button { selectDay(day) } label: {
                    HStack {
                        Text("\(cal.component(.day, from: day))").font(.system(size: 13, weight: active ? .bold : .medium))
                            .frame(width: 24, height: 24)
                            .foregroundStyle(cal.isDateInToday(day) ? Color.white : (currentMonth ? .primary : .secondary))
                            .background(cal.isDateInToday(day) ? Color.accentColor : .clear, in: Circle())
                        Spacer(minLength: 0)
                        if !items.isEmpty { Text("\(items.count)项").font(.system(size: 10)).foregroundStyle(.secondary) }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                ForEach(items.prefix(shown)) { item in AgendaChip(item: item) { openItem(item) } }
                if items.count > shown {
                    Button("+\(items.count - shown) 项 · 查看当天") { selectDay(day) }
                        .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(Color.accentColor).lineLimit(1)
                }
                Spacer(minLength: 0)
            }.padding(4)
        }.frame(height: height).clipped()
            .overlay(Rectangle().stroke(Color.primary.opacity(0.09), lineWidth: 0.5).allowsHitTesting(false))
            .overlay(Rectangle().stroke(active ? Color.accentColor.opacity(0.8) : .clear, lineWidth: 1.5).padding(1).allowsHitTesting(false))
    }
}

private struct AgendaWeekView: View {
    let date: Date
    let snapshot: AgendaCalendarSnapshot
    let selectDay: (Date) -> Void
    let openItem: (AgendaCalendarItem) -> Void
    private let hourHeight: CGFloat = 64
    private var days: [Date] { AgendaCalendar.days(in: AgendaCalendar.interval(containing: date, mode: .week)) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Text("全天").font(.caption).foregroundStyle(.secondary).frame(width: 48).padding(.top, 53)
                ForEach(days, id: \.self) { day in
                    VStack(spacing: 3) {
                        Button { selectDay(day) } label: {
                            VStack(spacing: 3) {
                                Text(AgendaCalendarText.format(day, "EEE")).font(.caption)
                                Text(AgendaCalendarText.format(day, "M/d")).font(.headline)
                            }.frame(maxWidth: .infinity).padding(.vertical, 5)
                                .background(Calendar.current.isDate(day, inSameDayAs: date) ? Color.accentColor.opacity(0.17) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(alignment: .top) { if Calendar.current.isDateInToday(day) { Capsule().fill(Color.accentColor).frame(height: 2) } }
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).help(AgendaCalendarText.day(day) + " · 查看当天明细")
                        let allDay = snapshot.items(on: day).filter(\.isAllDay)
                        ForEach(allDay.prefix(2)) { item in AgendaChip(item: item) { openItem(item) } }
                        if allDay.count > 2 { Button("+\(allDay.count - 2) 项") { selectDay(day) }.buttonStyle(.plain).font(.caption) }
                    }.frame(maxWidth: .infinity, minHeight: 80, alignment: .top).padding(.horizontal, 2)
                }
            }.padding(.vertical, 5)
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            ForEach(0..<24) { hour in
                                HStack(alignment: .top, spacing: 0) {
                                    Text(String(format: "%02d:00", hour)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(width: 46, alignment: .trailing).padding(.trailing, 2)
                                    Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 0.5)
                                }.frame(height: hourHeight, alignment: .top).id(hour)
                            }
                        }
                        HStack(spacing: 0) {
                            Color.clear.frame(width: 48)
                            ForEach(days, id: \.self) { day in weekColumn(day) }
                        }
                    }.frame(height: hourHeight * 24 + 58)
                }.onAppear { proxy.scrollTo(initialHour, anchor: .top) }
            }
        }
    }
    private var initialHour: Int {
        let earliest = days.flatMap { AgendaWeekPlacement.layout(snapshot.items(on: $0), on: $0) }.map(\.minute).min()
        return max(0, Int((earliest ?? 540) / 60) - 1)
    }
    private func weekColumn(_ day: Date) -> some View {
        let placements = AgendaWeekPlacement.layout(snapshot.items(on: day), on: day)
        return GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Calendar.current.isDate(day, inSameDayAs: date) ? Color.accentColor.opacity(0.035) : .clear)
                Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 0.5)
                ForEach(placements) { placement in
                    let width = max(1, geometry.size.width / CGFloat(placement.laneCount))
                    weekEvent(placement.item, on: day)
                        .frame(width: max(1, width - 4), height: CGFloat(placement.bottom - placement.minute) / 60 * hourHeight - 2, alignment: .topLeading)
                        .clipped()
                        .offset(x: CGFloat(placement.lane) * width + 2, y: CGFloat(placement.minute) / 60 * hourHeight)
                }
            }
        }.frame(maxWidth: .infinity)
    }
    private func weekEvent(_ item: AgendaCalendarItem, on day: Date) -> some View {
        let dayStart = Calendar.current.startOfDay(for: day)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)!
        let startLabel = item.start < dayStart ? "续 00:00" : item.timeLabel
        let endLabel = item.end >= dayEnd ? "24:00" : AgendaCalendarText.format(item.end, "HH:mm")
        return Button { openItem(item) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(startLabel + (item.schedule != nil ? "–" + endLabel : " · " + item.sourceTitle))
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(item.color).lineLimit(1)
                Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.padding(5).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(item.color.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(item.color).frame(width: 3) }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(item.help).accessibilityLabel(item.help)
    }
}

private struct AgendaYearView: View {
    let date: Date
    let snapshot: AgendaCalendarSnapshot
    let selectDay: (Date) -> Void
    let selectMonth: (Date) -> Void
    var body: some View {
        GeometryReader { geometry in
            let columnCount = max(1, min(4, Int((geometry.size.width - 14) / 243)))
            ScrollView {
                let year = AgendaCalendar.interval(containing: date, mode: .year)
                let months = (0..<12).compactMap { Calendar.current.date(byAdding: .month, value: $0, to: year.start) }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 18), count: columnCount), spacing: 18) {
                    ForEach(months, id: \.self) { month in miniMonth(month) }
                }.padding(16)
            }
        }
    }
    private func miniMonth(_ month: Date) -> some View {
        let calendar = snapshot.calendar
        return VStack(spacing: 6) {
            Button { selectMonth(month) } label: {
                HStack {
                    Text(AgendaCalendarText.format(month, "M月")).font(.headline)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help("打开" + AgendaCalendarText.period(month, mode: .month))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 2), count: 7), spacing: 3) {
                ForEach(0..<7) { i in Text(AgendaCalendarText.weekdays[i]).font(.system(size: 10)).foregroundStyle(.secondary).frame(height: 16) }
                ForEach(AgendaCalendar.monthGrid(containing: month), id: \.self) { day in
                    if calendar.isDate(day, equalTo: month, toGranularity: .month) {
                        miniDay(day)
                    } else { Color.clear.frame(height: 27).accessibilityHidden(true) }
                }
            }
        }.padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
    private func miniDay(_ day: Date) -> some View {
        let items = snapshot.items(on: day)
        let selected = snapshot.calendar.isDate(day, inSameDayAs: date)
        let today = snapshot.calendar.isDateInToday(day)
        return Button { selectDay(day) } label: {
            VStack(spacing: 2) {
                Text("\(snapshot.calendar.component(.day, from: day))").font(.system(size: 12, weight: items.isEmpty ? .regular : .bold))
                HStack(spacing: 2) {
                    if items.contains(where: { $0.task?.milestones.first?.kind == .availableAt }) { Circle().fill(.orange).frame(width: 3, height: 3) }
                    if items.contains(where: { $0.task?.milestones.first?.kind == .due }) { Circle().fill(.blue).frame(width: 3, height: 3) }
                    if items.contains(where: { $0.schedule != nil }) { Circle().fill(.purple).frame(width: 3, height: 3) }
                }.frame(height: 3)
            }.frame(maxWidth: .infinity).frame(height: 27)
                .foregroundStyle(today ? Color.white : Color.primary)
                .background(today ? Color.accentColor : (selected ? Color.accentColor.opacity(0.25) : (items.isEmpty ? .clear : Color.primary.opacity(0.07))), in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Color.accentColor : .clear, lineWidth: 1.5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(AgendaCalendarText.day(day) + " · \(items.count) 项")
            .accessibilityLabel(AgendaCalendarText.format(day, "yyyy年M月d日") + " · \(items.count) 项")
    }
}
