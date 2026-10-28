import AVFoundation
import AppKit

struct SoundOption: Identifiable, Hashable {
    let id: String
    let name: String
}

enum SoundLibrary {
    static let defaultID = "synth:chirp"
    static let noneID = "none"

    /// Built-in synthesized chimes first, then whatever system alert sounds exist on this Mac.
    static let all: [SoundOption] = {
        var list = Synth.Voice.allCases.map { SoundOption(id: "synth:\($0.rawValue)", name: $0.displayName) }
        let dir = URL(fileURLWithPath: "/System/Library/Sounds")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let names = files.filter { $0.pathExtension == "aiff" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
        list += names.map { SoundOption(id: "system:\($0)", name: $0) }
        list.append(SoundOption(id: noneID, name: "None"))
        return list
    }()

    static func name(for id: String) -> String { all.first { $0.id == id }?.name ?? "None" }
}

/// Agent side: plays each chime in a short-lived child process (`Howr --play …`), so the audio
/// and speech frameworks are loaded there and freed when it exits, never in the agent.
/// A new chime or preview stops the previous one, so sounds never overlap.
@MainActor
final class ChimeRunner {
    private let settings: Settings
    private let executable: URL?
    private let arguments: (String, Double, String?) -> [String]
    private var current: Process?
    private var pending: (sound: String, volume: Double, text: String?)?

    init(settings: Settings, executable: URL? = Bundle.main.executableURL,
         arguments: @escaping (String, Double, String?) -> [String] = { sound, volume, text in
             ["--play", sound, String(volume)] + (text.map { [$0] } ?? [])
         }) {
        self.settings = settings
        self.executable = executable
        self.arguments = arguments
    }

    func chime(at date: Date) {
        play(soundID: settings.soundID, speak: settings.speakTime ? Self.spokenTime(date) : nil)
    }

    /// Preview bypasses quiet rules, but never overlaps the previous audio process.
    func preview(soundID: String?, speak: Bool?) {
        let speakIt = speak ?? settings.speakTime
        play(soundID: soundID ?? settings.soundID, speak: speakIt ? Self.spokenTime(Date()) : nil)
    }

    func stop(immediately: Bool = false) {
        pending = nil
        guard let p = current else { return }
        if p.isRunning {
            if immediately { kill(p.processIdentifier, SIGKILL) }
            else {
                p.terminate()
                // A stopped or unresponsive child must not block subsequent chimes forever.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak p] in
                    MainActor.assumeIsolated {
                        if let p, self?.current === p, p.isRunning { kill(p.processIdentifier, SIGKILL) }
                    }
                }
            }
        }
    }

    private func play(soundID: String, speak text: String?) {
        stop()
        guard settings.volume.isFinite, settings.volume > 0,
              soundID != SoundLibrary.noneID || text != nil else { return }
        pending = (soundID, settings.volume, text)
        startPending()
    }

    private func startPending() {
        guard current == nil, let request = pending, let executable else { return }
        pending = nil
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments(request.sound, request.volume, request.text)
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.current === proc else { return }
                    self.current = nil
                    self.startPending()
                }
            }
        }
        do { try p.run(); current = p } catch { NSLog("Howr: could not play chime: \(error)") }
    }

    static func spokenTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.timeStyle = .short
        f.dateStyle = .none
        let time = f.string(from: date)
        return Locale.autoupdatingCurrent.language.languageCode == .english ? "It's \(time)" : time
    }
}

/// `Howr --play <soundID> <volume> [text]`: plays one chime (the sound, then the spoken text)
/// and exits. Started by `ChimeRunner`.
enum ChimeProcess {
    @MainActor
    static func run(_ args: [String]) -> Never {
        guard args.count >= 2, let volume = Float(args[1]), volume.isFinite, (0...1).contains(volume),
              SoundLibrary.all.contains(where: { $0.id == args[0] }),
              args.count < 3 || args[2].count <= 256 else { exit(2) }
        let player = ChimePlayer(volume: volume) { exit(0) }
        player.play(soundID: args[0], speak: args.count > 2 ? args[2] : nil)
        // Never linger, whatever happens to the audio callbacks. The timer also keeps the run loop alive.
        RunLoop.main.add(Timer(timeInterval: 30, repeats: false) { _ in exit(0) }, forMode: .default)
        withExtendedLifetime(player) { RunLoop.main.run() }
        exit(0)
    }
}

/// Plays the sound, then (optionally) speaks the text, then calls `done`.
@MainActor
final class ChimePlayer: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    private let volume: Float
    private let done: () -> Void
    private var player: AVAudioPlayer?
    private var speech: AVSpeechSynthesizer?
    private var pendingSpeech: String?

    init(volume: Float, done: @escaping () -> Void) {
        self.volume = volume.isFinite ? min(max(volume, 0), 1) : 0
        self.done = done
    }

    func play(soundID: String, speak text: String?) {
        pendingSpeech = text
        guard volume > 0 else { return done() }
        if let p = Self.makePlayer(for: soundID) {
            p.volume = volume
            p.delegate = self
            player = p
            if p.play() { return }
            player = nil
        }
        speakPending()
    }

    private static func makePlayer(for id: String) -> AVAudioPlayer? {
        if id.hasPrefix("synth:"), let voice = Synth.Voice(rawValue: String(id.dropFirst(6))) {
            return try? AVAudioPlayer(data: Synth.wav(for: voice))
        }
        if id.hasPrefix("system:") {
            let url = URL(fileURLWithPath: "/System/Library/Sounds/\(id.dropFirst(7)).aiff")
            return try? AVAudioPlayer(contentsOf: url)
        }
        return nil
    }

    private func speakPending() {
        guard let text = pendingSpeech else { return done() }
        pendingSpeech = nil
        let synth = AVSpeechSynthesizer()
        synth.delegate = self
        speech = synth
        let u = AVSpeechUtterance(string: text)
        u.volume = volume
        synth.speak(u)
    }

    // MARK: Delegates

    // Delegate callbacks may arrive off the main thread; hop over before touching state.

    nonisolated func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully _: Bool) {
        Task { @MainActor in self.speakPending() }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_: AVAudioPlayer, error _: Error?) {
        Task { @MainActor in self.speakPending() }
    }

    nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didFinish _: AVSpeechUtterance) {
        Task { @MainActor in self.done() }
    }

    nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didCancel _: AVSpeechUtterance) {
        Task { @MainActor in self.done() }
    }
}
