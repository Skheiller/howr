import XCTest
@testable import Howr

@MainActor
final class IPCTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "app.howr.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    /// Values survive the JSON trip, including dates and nil.
    func testValuesRoundTripThroughJSON() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000.5)
        let message: [String: Any] = ["a": IPC.encode(date), "b": IPC.encode(nil), "c": IPC.encode([2, 3]), "d": IPC.encode(0.6)]
        let data = try JSONSerialization.data(withJSONObject: message)
        let back = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(IPC.decode(back["a"]) as? Date, date)
        XCTAssertNil(IPC.decode(back["b"]))
        XCTAssertEqual(IPC.decode(back["c"]) as? [Int], [2, 3])
        XCTAssertEqual(IPC.decode(back["d"]) as? Double, 0.6)
    }

    /// The agent validates edits from the UI the same way it validates loaded values.
    func testApplyValidates() {
        let s = Settings(defaults: freshDefaults())
        s.apply("interval", 45); XCTAssertEqual(s.intervalMinutes, 60)
        s.apply("interval", 15); XCTAssertEqual(s.intervalMinutes, 15)
        s.apply("volume", 3.0); XCTAssertEqual(s.volume, 1)
        s.apply("sound", "system:NoSuchSound"); XCTAssertEqual(s.soundID, SoundLibrary.defaultID)
        s.apply("activeEnd", 99_999); XCTAssertEqual(s.activeEnd, 24 * 60 - 1)
        s.apply("activeWeekdays", [0, 1, 7, 9]); XCTAssertEqual(s.activeWeekdays, [1, 7])
        s.apply("lcdTheme", "neon"); XCTAssertEqual(s.lcdTheme, "auto")
        let until = Date().addingTimeInterval(600)
        s.apply("pausedUntil", until); XCTAssertEqual(s.pausedUntil, until)
        s.apply("pausedUntil", nil); XCTAssertNil(s.pausedUntil)
    }

    /// In the UI process edits are forwarded, never written; the agent's updates are not echoed back.
    func testForwardingModeNeverWritesAndDoesNotEcho() {
        let d = freshDefaults()
        let s = Settings(defaults: d)
        var sent: [String] = []
        s.forward = { key, _ in sent.append(key) }
        s.volume = 0.2
        XCTAssertEqual(sent, ["volume"])
        XCTAssertNil(d.object(forKey: "volume"))
        s.applyFromAgent("pausedUntil", Date().addingTimeInterval(60))
        XCTAssertNotNil(s.pausedUntil)
        XCTAssertEqual(sent, ["volume"])
    }

    /// An agent-side edit (no forward) persists, so a fresh UI process loads it.
    func testAgentApplyPersists() {
        let d = freshDefaults()
        Settings(defaults: d).apply("speakTime", true)
        XCTAssertTrue(Settings(defaults: d).speakTime)
    }
}
