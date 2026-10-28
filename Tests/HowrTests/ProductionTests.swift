import XCTest
import Darwin
@testable import Howr

@MainActor
final class ProductionTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "app.howr.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testCorruptedVolumeCannotReachLCDOrAudio() {
        let d = defaults()
        for value in [Double.nan, .infinity, -.infinity] {
            d.set(value, forKey: "volume")
            let s = Settings(defaults: d)
            XCTAssertEqual(s.volume, 0.6)
            s.apply("volume", value)
            XCTAssertTrue(s.volume.isFinite)
            XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: s.snapshot))
        }
        let s = Settings(defaults: d)
        s.apply("volume", -10.0); XCTAssertEqual(s.volume, 0)
        s.apply("volume", 10.0); XCTAssertEqual(s.volume, 1)
        s.apply("volume", "broken"); XCTAssertEqual(s.volume, 1)
        s.apply("pausedUntil", Date(timeIntervalSince1970: .infinity))
        XCTAssertNil(s.pausedUntil)
        XCTAssertNil(IPC.decode(["date": Double.nan]))
    }

    func testInitialSnapshotWinsOverStalePersistenceWithoutEcho() throws {
        let agent = Settings(defaults: defaults())
        agent.intervalMinutes = 15; agent.volume = 0.2; agent.lcdTheme = "night"
        agent.activeWeekdays = [1, 7]; agent.speakTime = true
        let uiDefaults = defaults(), ui = Settings(defaults: uiDefaults)
        var echoed = false
        ui.forward = { _, _ in echoed = true }
        let encoded = try JSONSerialization.data(withJSONObject: agent.snapshot)
        let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        ui.applySnapshot(snapshot)
        XCTAssertEqual(ui.intervalMinutes, 15); XCTAssertEqual(ui.volume, 0.2)
        XCTAssertEqual(ui.lcdTheme, "night"); XCTAssertEqual(ui.activeWeekdays, [1, 7])
        XCTAssertTrue(ui.speakTime); XCTAssertFalse(echoed)
        XCTAssertNil(uiDefaults.object(forKey: "volume"))
    }

    func testExclusiveAgentLockCanBeReacquiredAfterOwnerReleases() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var first = try AgentLock.acquire(at: url)
        XCTAssertNotNil(first)
        XCTAssertNil(try AgentLock.acquire(at: url))
        withExtendedLifetime(first) {}
        first = nil
        XCTAssertNotNil(try AgentLock.acquire(at: url))
    }

    func testAgentLockRejectsSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file"), link = root.appendingPathComponent("link")
        try Data().write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try AgentLock.acquire(at: link))
    }

    func testStalledOutputCannotBlockTheMainActor() {
        let incoming = Pipe(), stalled = Pipe()
        let closed = expectation(description: "bounded stalled writer fails")
        let responsive = expectation(description: "main actor remains responsive")
        let channel = Channel(read: incoming.fileHandleForReading, write: stalled.fileHandleForWriting,
            onMessage: { _ in }, onClose: {}, onWriteFailure: { closed.fulfill() })
        for _ in 0..<3 { XCTAssertTrue(channel.send(["blob": String(repeating: "x", count: 32_000)])) }
        DispatchQueue.main.async { responsive.fulfill() }
        wait(for: [responsive], timeout: 0.5)
        wait(for: [closed], timeout: 3)
        channel.close()
        withExtendedLifetime(channel) {}
    }

    func testOversizedIncomingFrameClosesConnection() {
        let incoming = Pipe()
        let closed = expectation(description: "oversized frame closes")
        let channel = Channel(read: incoming.fileHandleForReading, write: .nullDevice,
            onMessage: { _ in XCTFail("oversized frame accepted") }, onClose: { closed.fulfill() })
        DispatchQueue.global().async {
            try? incoming.fileHandleForWriting.write(contentsOf: Data(repeating: 65, count: Channel.maxFrameBytes + 1))
        }
        wait(for: [closed], timeout: 3)
        withExtendedLifetime(channel) {}
    }

    func testFlushDeliversQuitBeforeExit() {
        let incoming = Pipe(), outgoing = Pipe()
        let flushed = expectation(description: "flushed")
        let channel = Channel(read: incoming.fileHandleForReading, write: outgoing.fileHandleForWriting,
            onMessage: { _ in }, onClose: {})
        XCTAssertTrue(channel.send(["op": "quit"]))
        channel.flush { flushed.fulfill() }
        wait(for: [flushed], timeout: 2)
        XCTAssertTrue(String(decoding: outgoing.fileHandleForReading.availableData, as: UTF8.self).contains("quit"))
        channel.close()
    }

    func testFinalQuitSurvivesConcurrentStateWriteFailures() {
        for _ in 0..<100 {
            let script = #"read l; exec 0<&-; printf '{"op":"quit"}\n'; exit 0"#
            let host = UIHost(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
            let exited = expectation(description: "child exits after inbound drain")
            var quitReceived = false
            host.onMessage = { if $0["op"] as? String == "quit" { quitReceived = true } }
            host.onExit = { exited.fulfill() }
            host.send(["op": "settings"])
            for _ in 0..<20 { host.notify(["op": "state", "data": String(repeating: "x", count: 2048)]) }
            wait(for: [exited], timeout: 3)
            XCTAssertTrue(quitReceived, "write failure must not discard the peer's final Quit")
        }
    }

    func testEarlyStateExpiryCannotPlayTheSameBoundaryTwice() {
        let target = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(Scheduler.isDue(target, now: target.addingTimeInterval(-0.5), asleep: false))
        XCTAssertTrue(Scheduler.isDue(target, now: target, asleep: false))
        XCTAssertFalse(Scheduler.isDue(target, now: target.addingTimeInterval(6), asleep: false))
        XCTAssertFalse(Scheduler.isDue(target, now: target, asleep: true))
    }

    func testHalfHourDSTGapKeepsHourlyChimesOnTheHour() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Lord_Howe"))
        let rules = ChimeRules(intervalMinutes: 60)
        let before = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 1, minute: 50)))
        let next = rules.nextBoundary(after: before, calendar: calendar)
        XCTAssertEqual(calendar.component(.hour, from: next), 3)
        XCTAssertEqual(calendar.component(.minute, from: next), 0)
        let after = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 2, minute: 35)))
        XCTAssertEqual(rules.nextBoundary(after: after, calendar: calendar), next)
    }

    func testAudioReplacementWaitsForUnresponsiveChildAndKeepsLatestRequest() throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: log) }
        let script = #"trap '' TERM; print -r -- "$$:$1" >> "$2"; zmodload zsh/zselect; while true; do zselect -t 1000; done"#
        let runner = ChimeRunner(settings: Settings(defaults: defaults()), executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: { sound, _, _ in ["-c", script, "howr-test", sound, log.path] })
        defer { runner.stop(immediately: true) }
        func entries() -> [String] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
        func waitUntil(_ predicate: () -> Bool) {
            let deadline = Date().addingTimeInterval(3)
            while !predicate(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        runner.preview(soundID: "first", speak: false)
        waitUntil { entries().count == 1 }
        let first = try XCTUnwrap(entries().first)
        let pid = try XCTUnwrap(Int32(first.split(separator: ":")[0]))
        runner.preview(soundID: "discarded", speak: false)
        runner.preview(soundID: "latest", speak: false)
        waitUntil { entries().count >= 2 }
        XCTAssertEqual(entries().count, 2)
        XCTAssertTrue(entries().last?.hasSuffix(":latest") == true)
        XCTAssertEqual(kill(pid, 0), -1, "replacement starts only after the old process has exited")
    }
}
