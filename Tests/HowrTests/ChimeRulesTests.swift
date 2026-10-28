import XCTest
@testable import Howr

final class ChimeRulesTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    func rules(_ interval: Int = 60, hours: (Int, Int)? = nil, days: Set<Int>? = nil) -> ChimeRules {
        ChimeRules(intervalMinutes: interval, activeHours: hours, weekdays: days, pausedUntil: nil, skipped: nil)
    }

    func testNextBoundaryHourly() {
        XCTAssertEqual(rules().nextBoundary(after: date(2026, 10, 27, 14, 42), calendar: cal), date(2026, 10, 27, 15, 0))
        // Exactly on a boundary → the next one, never the same instant twice.
        XCTAssertEqual(rules().nextBoundary(after: date(2026, 10, 27, 15, 0), calendar: cal), date(2026, 10, 27, 16, 0))
    }

    func testNextBoundaryQuarter() {
        XCTAssertEqual(rules(15).nextBoundary(after: date(2026, 10, 27, 14, 42, 10), calendar: cal), date(2026, 10, 27, 14, 45))
        XCTAssertEqual(rules(30).nextBoundary(after: date(2026, 10, 27, 14, 31), calendar: cal), date(2026, 10, 27, 15, 0))
    }

    func testActiveHoursInclusive() {
        let r = rules(hours: (9 * 60, 18 * 60))
        XCTAssertTrue(r.isInSchedule(date(2026, 10, 27, 9, 0), calendar: cal))
        XCTAssertTrue(r.isInSchedule(date(2026, 10, 27, 18, 0), calendar: cal))
        XCTAssertFalse(r.isInSchedule(date(2026, 10, 27, 19, 0), calendar: cal))
        XCTAssertFalse(r.isInSchedule(date(2026, 10, 27, 8, 0), calendar: cal))
    }

    func testOvernightWindowBelongsToStartDay() {
        // 22:00–02:00 on Fridays only. 2026-10-30 is a Friday.
        let r = rules(hours: (22 * 60, 2 * 60), days: [6])
        XCTAssertTrue(r.isInSchedule(date(2026, 10, 30, 23, 0), calendar: cal))
        XCTAssertTrue(r.isInSchedule(date(2026, 10, 31, 1, 0), calendar: cal))   // Saturday 1 AM, Friday's window
        XCTAssertFalse(r.isInSchedule(date(2026, 10, 31, 23, 0), calendar: cal))
    }

    func testNextChimeSkipsToNextWorkday() {
        // Friday 18:30 with Mon–Fri 9–18 → Monday 9:00.
        let r = rules(hours: (9 * 60, 18 * 60), days: [2, 3, 4, 5, 6])
        XCTAssertEqual(r.nextChime(after: date(2026, 10, 30, 18, 30), calendar: cal), date(2026, 11, 2, 9, 0))
    }

    func testPauseAndSkip() {
        var r = rules()
        r.pausedUntil = date(2026, 10, 27, 16, 12)
        XCTAssertEqual(r.nextChime(after: date(2026, 10, 27, 14, 42), calendar: cal), date(2026, 10, 27, 17, 0))
        r.pausedUntil = nil
        r.skipped = date(2026, 10, 27, 15, 0)
        XCTAssertEqual(r.nextChime(after: date(2026, 10, 27, 14, 42), calendar: cal), date(2026, 10, 27, 16, 0))
    }

    func testNoWeekdaysMeansNoChime() {
        XCTAssertNil(rules(hours: (9 * 60, 18 * 60), days: []).nextChime(after: date(2026, 10, 27, 10, 0), calendar: cal))
    }

    func testDSTFallBackRepeatsRealHour() {
        // 2026-11-01 01:00 EDT → 01:00 EST. Each real hour gets a chime.
        let start = date(2026, 11, 1, 0, 30)
        let first = rules().nextChime(after: start, calendar: cal)!
        let second = rules().nextChime(after: first, calendar: cal)!
        XCTAssertEqual(second.timeIntervalSince(first), 3600)
        XCTAssertEqual(cal.component(.hour, from: first), 1)
        XCTAssertEqual(cal.component(.hour, from: second), 1)
    }

    func testDSTSpringForward() {
        // 2026-03-08 02:00 doesn't exist; after 01:00 comes 03:00.
        let next = rules().nextChime(after: date(2026, 3, 8, 1, 10), calendar: cal)!
        XCTAssertEqual(cal.component(.hour, from: next), 3)
    }

    func testSynthRendersAllVoices() {
        for v in Synth.Voice.allCases {
            let wav = Synth.wav(for: v)
            XCTAssertGreaterThan(wav.count, 44, "\(v)")
            XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        }
    }
}
