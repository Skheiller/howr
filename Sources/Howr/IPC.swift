import Foundation
import Darwin

/// Private inherited pipes, with bounded frames and a timed serial writer off the main actor.
@MainActor
final class Channel {
    nonisolated static let maxFrameBytes = 64 * 1024
    private let reader: FileHandle
    private let writer: FileHandle
    private let output: Output
    private let writeQueue = DispatchQueue(label: "app.howr.ipc.write")
    private let onClose: @MainActor () -> Void
    private let onWriteFailure: @MainActor () -> Void
    private var buffer = Data()
    private var queuedBytes = 0
    private var isOpen = true
    private var canWrite = true

    private final class Output: @unchecked Sendable {
        private let fd: Int32
        private let lock = NSLock()
        private var cancelled = false
        init(_ source: Int32) {
            fd = dup(source)
            if fd >= 0 {
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                _ = fcntl(fd, F_SETNOSIGPIPE, 1)
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            }
        }
        deinit { if fd >= 0 { Darwin.close(fd) } }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        private var stopped: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func write(_ data: Data) -> Bool {
            guard fd >= 0 else { return false }
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            var offset = 0
            while offset < data.count {
                guard !stopped, ProcessInfo.processInfo.systemUptime < deadline else { return false }
                let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
                if n > 0 { offset += n; continue }
                if n < 0 && errno == EINTR { continue }
                guard n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) else { return false }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&descriptor, 1, 100) < 0 && errno != EINTR { return false }
            }
            return true
        }
    }

    init(read: FileHandle, write: FileHandle,
         onMessage: @escaping @MainActor ([String: Any]) -> Void,
         onClose: @escaping @MainActor () -> Void,
         onWriteFailure: @escaping @MainActor () -> Void = {}) {
        reader = read
        writer = write
        output = Output(write.fileDescriptor)
        self.onClose = onClose
        self.onWriteFailure = onWriteFailure
        read.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isOpen else { return }
                    if chunk.isEmpty { self.finish(); return }
                    self.buffer.append(chunk)
                    while let nl = self.buffer.firstIndex(of: 0x0A) {
                        let line = self.buffer[self.buffer.startIndex..<nl]
                        guard line.count <= Self.maxFrameBytes else { self.finish(); return }
                        let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
                        self.buffer.removeSubrange(self.buffer.startIndex...nl)
                        if let message { onMessage(message) }
                        if !self.isOpen { return }
                    }
                    if self.buffer.count > Self.maxFrameBytes { self.finish() }
                }
            }
        }
    }

    /// Acceptance into a bounded queue, never a blocking pipe write on the scheduler's actor.
    @discardableResult
    func send(_ message: [String: Any]) -> Bool {
        guard isOpen, canWrite, JSONSerialization.isValidJSONObject(message),
              var data = try? JSONSerialization.data(withJSONObject: message),
              data.count <= Self.maxFrameBytes else { return false }
        data.append(0x0A)
        guard queuedBytes + data.count <= Self.maxFrameBytes * 4 else { failWriting(); return false }
        queuedBytes += data.count
        let count = data.count, output = output
        writeQueue.async { [weak self, data] in
            let success = output.write(data)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.queuedBytes -= count
                    if !success { self.failWriting() }
                }
            }
        }
        return true
    }

    /// UI Quit must drain the final command before exiting its process.
    func flush(_ completion: @escaping @MainActor () -> Void) {
        writeQueue.async { DispatchQueue.main.async { MainActor.assumeIsolated { completion() } } }
    }

    private func finish() {
        guard isOpen else { return }
        close()
        onClose()
    }

    /// EPIPE is independent of inbound EOF: the peer may have written Quit just before exiting.
    private func failWriting() {
        guard canWrite else { return }
        canWrite = false
        output.cancel()
        onWriteFailure()
    }

    func close() {
        isOpen = false
        canWrite = false
        reader.readabilityHandler = nil
        output.cancel()
    }
}

/// Settings values over JSON: dates travel as {"date": seconds since 1970}, nil as null.
enum IPC {
    static func encode(_ value: Any?) -> Any {
        switch value {
        case nil: NSNull()
        case let d as Date: ["date": d.timeIntervalSince1970]
        case let v?: v
        }
    }

    static func decode(_ value: Any?) -> Any? {
        if value is NSNull { return nil }
        if let d = value as? [String: Any], let t = d["date"] as? Double {
            return t.isFinite ? Date(timeIntervalSince1970: t) : nil
        }
        return value
    }
}
