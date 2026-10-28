import Foundation

/// Formatting shared by every LCD surface, honoring the user's 12/24-hour preference.
enum LCDFormat {
    static var uses24h: Bool {
        !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .autoupdatingCurrent) ?? "").contains("a")
    }

    /// ("2:42", "PM") or ("14:42", "")
    static func clock(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> (String, String) {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return clock(minutes: (c.hour ?? 0) * 60 + (c.minute ?? 0))
    }

    static func clock(minutes: Int) -> (String, String) {
        let h = minutes / 60, m = minutes % 60
        if uses24h { return (String(format: "%02d:%02d", h, m), "") }
        let h12 = h % 12 == 0 ? 12 : h % 12
        return (String(format: "%2d:%02d", h12, m), h < 12 ? "AM" : "PM")   // leading blank digit shows as ghost segments
    }

    static func short(_ date: Date) -> String {
        let (t, ampm) = clock(date)
        let trimmed = t.trimmingCharacters(in: .whitespaces)
        return ampm.isEmpty ? trimmed : "\(trimmed) \(ampm)"
    }

    /// "TU 28" — two-letter weekday and day of month, like the watch.
    static func dayLabel(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let wd = calendar.component(.weekday, from: date)
        let sym = calendar.shortWeekdaySymbols[wd - 1].uppercased().prefix(2)
        return "\(sym) \(calendar.component(.day, from: date))"
    }

    static func weekday(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        calendar.shortWeekdaySymbols[calendar.component(.weekday, from: date) - 1].uppercased()
    }

    /// Status line: "NEXT 3:00 PM", "NEXT TUE 9:00 AM", "PAUSED TIL 4:12 PM", "NO CHIMES SET".
    static func status(next: Date?, pausedUntil: Date?, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> String {
        if let p = pausedUntil, p > now {
            if calendar.isDate(p, inSameDayAs: now) { return "PAUSED TIL \(short(p))" }
            return "PAUSED TIL \(weekday(p)) \(short(p))"
        }
        guard let next else { return "NO CHIMES SET" }
        if calendar.isDate(next, inSameDayAs: now) { return "NEXT \(short(next))" }
        return "NEXT \(weekday(next)) \(short(next))"
    }

    /// Natural-language status for VoiceOver and the menu bar tooltip.
    static func statusSentence(next: Date?, pausedUntil: Date?, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> String {
        func when(_ d: Date) -> String {
            if calendar.isDate(d, inSameDayAs: now) { return spoken(d) }
            if calendar.isDateInTomorrow(d) { return "tomorrow at \(spoken(d))" }
            return "\(calendar.weekdaySymbols[calendar.component(.weekday, from: d) - 1]) at \(spoken(d))"
        }
        if let p = pausedUntil, p > now { return "Paused until \(when(p))" }
        guard let next else { return "No chimes scheduled" }
        return "Next chime \(calendar.isDate(next, inSameDayAs: now) ? "at " : "")\(when(next))"
    }

    /// Localized short time ("3:00 PM" / "15:00") for VoiceOver.
    static func spoken(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func spoken(minutes: Int) -> String {
        let d = Calendar.autoupdatingCurrent.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        return spoken(d)
    }
}
