import Foundation

/// One window of a report tab's range navigator: `offset` windows back from
/// the current one. Calendar windows (Cache, Cost) are whole local days;
/// rolling windows (History) end at the current moment.
struct RangeWindow: Equatable {
    let start: Date
    let end: Date
    /// 0 = the window that holds now.
    let offset: Int
    let label: String

    var isCurrent: Bool { offset == 0 }

    /// `days` local days, the newest `offset * days` days before today's.
    static func calendar(days: Int, offset: Int, now: Date = Date(), calendar: Calendar = .current) -> RangeWindow {
        let days = max(days, 1)
        let offset = max(offset, 0)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let end = calendar.date(byAdding: .day, value: -offset * days, to: tomorrow) ?? tomorrow
        let start = calendar.date(byAdding: .day, value: -days, to: end) ?? end
        let lastDay = calendar.date(byAdding: .day, value: -1, to: end) ?? start
        let label: String
        if days == 1 {
            let date = start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            if offset == 0 {
                label = String(localized: "Today · \(date)")
            } else if offset == 1 {
                label = String(localized: "Yesterday · \(date)")
            } else {
                label = date
            }
        } else {
            let span = dayRange(start, lastDay, calendar: calendar)
            label = offset == 0 ? String(localized: "\(span) · now") : span
        }
        return RangeWindow(start: start, end: end, offset: offset, label: label)
    }

    /// The `hours` hours ending `offset * hours` hours before `now`.
    static func rolling(hours: Int, offset: Int, now: Date = Date(), calendar: Calendar = .current) -> RangeWindow {
        let length = TimeInterval(max(hours, 1)) * 3600
        let offset = max(offset, 0)
        let end = now.addingTimeInterval(-Double(offset) * length)
        let start = end.addingTimeInterval(-length)
        let label: String
        if offset == 0 {
            switch hours {
            case 24: label = String(localized: "Last 24 hours · now")
            case 168: label = String(localized: "Last 7 days · now")
            case 720: label = String(localized: "Last 30 days · now")
            default: label = String(localized: "Last \(hours) hours · now")
            }
        } else if hours <= 48 {
            let style = Date.FormatStyle.dateTime.month(.abbreviated).day().hour(.twoDigits(amPM: .omitted)).minute()
            label = "\(start.formatted(style)) – \(end.formatted(style))"
        } else {
            label = dayRange(start, end, calendar: calendar)
        }
        return RangeWindow(start: start, end: end, offset: offset, label: label)
    }

    /// The local day keys (`CostRollup.dayKey`) the window covers, oldest first.
    func dayKeys(calendar: Calendar = .current) -> [String] {
        var keys: [String] = []
        var day = calendar.startOfDay(for: start)
        while day < end {
            keys.append(CostRollup.dayKey(day, calendar: calendar))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return keys
    }

    /// Whether an older window would still hold stored data starting at `oldest`.
    func canGoBack(oldest: Date?) -> Bool {
        guard let oldest else { return false }
        return start > oldest
    }

    /// The window starts before the oldest stored data, so it is only partly covered.
    func isPartial(oldest: Date?) -> Bool {
        guard let oldest else { return false }
        return start < oldest && end > oldest
    }

    /// "Nov 13 – 19", or "Oct 28 – Nov 3" across months.
    static func dayRange(_ first: Date, _ last: Date, calendar: Calendar) -> String {
        let monthDay = Date.FormatStyle.dateTime.month(.abbreviated).day()
        if calendar.isDate(first, equalTo: last, toGranularity: .month) {
            return "\(first.formatted(monthDay)) – \(last.formatted(.dateTime.day()))"
        }
        return "\(first.formatted(monthDay)) – \(last.formatted(monthDay))"
    }
}
