import Foundation

/// Pure scheduling logic: which wall-clock instants get a chime.
///
/// Boundaries advance through real time and match wall-clock interval minutes, so
/// repeated DST hours retain their boundaries and nonexistent times are skipped.
struct ChimeRules: Equatable {
    var intervalMinutes: Int
    /// Inclusive (start, end) minutes since midnight. start > end wraps past midnight;
    /// start == end means the whole day.
    var activeHours: (Int, Int)?
    var weekdays: Set<Int>?
    var pausedUntil: Date?
    var skipped: Date?

    static func == (a: ChimeRules, b: ChimeRules) -> Bool {
        a.intervalMinutes == b.intervalMinutes && a.activeHours?.0 == b.activeHours?.0
            && a.activeHours?.1 == b.activeHours?.1 && a.weekdays == b.weekdays
            && a.pausedUntil == b.pausedUntil && a.skipped == b.skipped
    }

    /// The first interval boundary strictly after `date`.
    func nextBoundary(after date: Date, calendar: Calendar) -> Date {
        let interval = [15, 30, 60].contains(intervalMinutes) ? intervalMinutes : 60
        let components = calendar.dateComponents([.minute, .second], from: date)
        let seconds = (interval - (components.minute ?? 0) % interval) * 60 - (components.second ?? 0)
        var next = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970)).addingTimeInterval(Double(seconds))
        // A half-hour DST jump can land between wall-clock interval boundaries.
        // Walk real minutes until the next valid wall-clock minute, retaining repeated hours.
        while calendar.component(.minute, from: next) % interval != 0 {
            next = next.addingTimeInterval(60)
        }
        return next
    }

    /// Whether the time-of-day/weekday rules allow a chime at `date` (ignores pause/skip).
    func isInSchedule(_ date: Date, calendar: Calendar) -> Bool {
        guard let (start, end) = activeHours else { return true }
        let c = calendar.dateComponents([.hour, .minute, .weekday], from: date)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        var weekday = c.weekday ?? 1
        let inWindow: Bool
        if start == end {
            inWindow = true
        } else if start < end {
            inWindow = minute >= start && minute <= end
        } else {
            // Overnight window: the part after midnight belongs to the previous day.
            if minute <= end { weekday = weekday == 1 ? 7 : weekday - 1 }
            inWindow = minute >= start || minute <= end
        }
        guard inWindow else { return false }
        if let weekdays { return weekdays.contains(weekday) }
        return true
    }

    /// Whether a chime should actually sound at boundary `date`.
    func shouldChime(at date: Date, calendar: Calendar) -> Bool {
        if let pausedUntil, date < pausedUntil { return false }
        if let skipped, abs(skipped.timeIntervalSince(date)) < 1 { return false }
        return isInSchedule(date, calendar: calendar)
    }

    /// Next boundary that will actually chime, searching up to 8 days ahead.
    func nextChime(after date: Date, calendar: Calendar) -> Date? {
        var t = date
        let limit = date.addingTimeInterval(8 * 24 * 3600)
        while t < limit {
            t = nextBoundary(after: t, calendar: calendar)
            if shouldChime(at: t, calendar: calendar) { return t }
        }
        return nil
    }
}
