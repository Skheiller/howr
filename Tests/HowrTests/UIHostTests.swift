import XCTest
@testable import Howr

/// Transport and process lifecycle between the agent and the UI process, using small
/// shell scripts as stand-in UI processes.
@MainActor
final class UIHostTests: XCTestCase {
    private func line(_ m: [String: Any]) -> Data {
        var d = try! JSONSerialization.data(withJSONObject: m)
        d.append(0x0A)
        return d
    }

    /// Everything written before EOF arrives, in order, before onClose.
    func testChannelDeliversEverythingBeforeClose() throws {
        let pipe = Pipe()
        var got: [Int] = []
        var closedAfter = -1
        let closed = expectation(description: "closed")
        let channel = Channel(read: pipe.fileHandleForReading, write: FileHandle.nullDevice,
                              onMessage: { got.append($0["n"] as? Int ?? -1) },
                              onClose: { closedAfter = got.count; closed.fulfill() })
        for n in 0..<500 { try pipe.fileHandleForWriting.write(contentsOf: line(["n": n])) }
        try pipe.fileHandleForWriting.close()
        wait(for: [closed], timeout: 5)
        XCTAssertEqual(got, Array(0..<500))
        XCTAssertEqual(closedAfter, 500)
        withExtendedLifetime(channel) {}
    }

    /// A UI that sends its last messages and exits at once: nothing is lost, then onExit.
    func testFinalMessagesSurviveImmediateExit() {
        let script = #"read l; printf '{"op":"set","key":"volume","value":0.3}\n{"op":"quit"}\n'; exit 0"#
        let host = UIHost(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
        var ops: [String] = []
        let exited = expectation(description: "exited")
        host.onMessage = { ops.append($0["op"] as? String ?? "?") }
        host.onExit = { exited.fulfill() }
        host.send(["op": "toggle"])
        wait(for: [exited], timeout: 5)
        XCTAssertEqual(ops, ["set", "quit"])
        XCTAssertFalse(host.isRunning)
    }

    /// idle with the latest command seen: the agent retires it and replies close.
    func testIdleHandshakeClosesWhenUpToDate() {
        let script = #"read l; echo '{"op":"idle","seen":1}'; read c; case "$c" in *close*) exit 0;; esac; exit 3"#
        let host = UIHost(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
        let exited = expectation(description: "exited")
        host.onExit = { exited.fulfill() }
        host.send(["op": "settings"])
        wait(for: [exited], timeout: 5)
        XCTAssertFalse(host.isRunning)
    }

    /// idle that is out of date (a command is in flight): the agent keeps the process.
    func testStaleIdleIsIgnored() {
        let script = #"read a; read b; echo '{"op":"idle","seen":1}'; echo '{"op":"ack"}'; read c; exit 0"#
        let host = UIHost(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
        let acked = expectation(description: "acked")
        host.onMessage = { if $0["op"] as? String == "ack" { acked.fulfill() } }
        host.send(["op": "settings"])
        host.send(["op": "toggle", "anchor": [0, 0, 1, 1]])
        wait(for: [acked], timeout: 5)
        XCTAssertTrue(host.isRunning, "seq 2 was sent, so idle(seen: 1) must not retire the UI")
        host.terminate()
    }
}
