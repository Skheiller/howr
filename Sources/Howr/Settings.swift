import Foundation
import Combine

/// User preferences, persisted in UserDefaults. Every value is validated on load
/// so a corrupted or hand-edited plist can never put the scheduler in a bad state.
///
/// The agent owns persistence. In the UI process `forward` is set: edits are sent to the agent
/// instead of being written, and the agent's updates come back through `applyFromAgent`.
@MainActor
final class Settings: ObservableObject {
    static let allowedIntervals = [60, 30, 15]
    static let keys = ["interval", "sound", "speakTime", "volume", "activeHoursEnabled", "activeStart", "activeEnd", "activeWeekdays", "quietWhenLocked", "quietDuringCalls", "lcdTheme", "pausedUntil", "skippedChime"]

    static func validVolume(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0.6
    }

    static func validDate(_ value: Any?) -> Date? {
        guard let date = value as? Date, date.timeIntervalSince1970.isFinite else { return nil }
        return date
    }

    private let defaults: UserDefaults
    /// UI process only: receives each edit (key, plist value) instead of UserDefaults.
    var forward: ((String, Any?) -> Void)?
    private var applyingFromAgent = false

    @Published var intervalMinutes: Int { didSet { save("interval", intervalMinutes) } }
    @Published var soundID: String { didSet { save("sound", soundID) } }
    @Published var speakTime: Bool { didSet { save("speakTime", speakTime) } }
    /// 0...1
    @Published var volume: Double { didSet { save("volume", volume) } }

    @Published var activeHoursEnabled: Bool { didSet { save("activeHoursEnabled", activeHoursEnabled) } }
    /// Minutes since midnight, 0..<1440. Both ends are inclusive: 09:00–18:00 chimes at 09:00 and 18:00.
    @Published var activeStart: Int { didSet { save("activeStart", activeStart) } }
    @Published var activeEnd: Int { didSet { save("activeEnd", activeEnd) } }
    /// Calendar weekday numbers (1 = Sunday … 7 = Saturday).
    @Published var activeWeekdays: Set<Int> { didSet { save("activeWeekdays", activeWeekdays.sorted()) } }

    @Published var quietWhenLocked: Bool { didSet { save("quietWhenLocked", quietWhenLocked) } }
    @Published var quietDuringCalls: Bool { didSet { save("quietDuringCalls", quietDuringCalls) } }

    /// "auto" follows the system appearance; "day" / "night" are forced by the case's LIGHT button.
    @Published var lcdTheme: String { didSet { save("lcdTheme", lcdTheme) } }

    @Published var pausedUntil: Date? { didSet { save("pausedUntil", pausedUntil) } }
    @Published var skippedChime: Date? { didSet { save("skippedChime", skippedChime) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let d = defaults
        let interval = d.object(forKey: "interval") as? Int ?? 60
        intervalMinutes = Settings.allowedIntervals.contains(interval) ? interval : 60
        let sound = d.string(forKey: "sound") ?? SoundLibrary.defaultID
        // A system sound from another Mac (or a removed voice) falls back to the default.
        soundID = SoundLibrary.all.contains { $0.id == sound } ? sound : SoundLibrary.defaultID
        speakTime = d.object(forKey: "speakTime") as? Bool ?? false
        volume = Self.validVolume(d.object(forKey: "volume") as? Double ?? 0.6)
        activeHoursEnabled = d.object(forKey: "activeHoursEnabled") as? Bool ?? false
        activeStart = Settings.clampMinute(d.object(forKey: "activeStart") as? Int ?? 9 * 60)
        activeEnd = Settings.clampMinute(d.object(forKey: "activeEnd") as? Int ?? 18 * 60)
        let days = (d.array(forKey: "activeWeekdays") as? [Int] ?? [2, 3, 4, 5, 6]).filter { (1...7).contains($0) }
        activeWeekdays = Set(days)
        quietWhenLocked = d.object(forKey: "quietWhenLocked") as? Bool ?? false
        quietDuringCalls = d.object(forKey: "quietDuringCalls") as? Bool ?? false
        let theme = d.string(forKey: "lcdTheme") ?? "auto"
        lcdTheme = ["auto", "day", "night"].contains(theme) ? theme : "auto"
        pausedUntil = Self.validDate(d.object(forKey: "pausedUntil"))
        skippedChime = Self.validDate(d.object(forKey: "skippedChime"))
    }

    /// The case's LIGHT button: automatic → daylight → backlight → automatic.
    func cycleLCDTheme() {
        lcdTheme = ["auto": "day", "day": "night", "night": "auto"][lcdTheme] ?? "auto"
    }

    static func clampMinute(_ m: Int) -> Int { min(max(m, 0), 24 * 60 - 1) }

    private func save(_ key: String, _ value: Any?) {
        if let forward {
            if !applyingFromAgent { forward(key, value) }
            return
        }
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    /// Sets one value by its storage key, with the same validation as loading.
    /// The agent uses this for edits arriving from the UI process.
    func apply(_ key: String, _ value: Any?) {
        switch key {
        case "interval": if let v = value as? Int, Self.allowedIntervals.contains(v) { intervalMinutes = v }
        case "sound": if let v = value as? String, SoundLibrary.all.contains(where: { $0.id == v }) { soundID = v }
        case "speakTime": if let v = value as? Bool { speakTime = v }
        case "volume": if let v = value as? Double { volume = Self.validVolume(v) }
        case "activeHoursEnabled": if let v = value as? Bool { activeHoursEnabled = v }
        case "activeStart": if let v = value as? Int { activeStart = Self.clampMinute(v) }
        case "activeEnd": if let v = value as? Int { activeEnd = Self.clampMinute(v) }
        case "activeWeekdays": if let v = value as? [Int] { activeWeekdays = Set(v.filter { (1...7).contains($0) }) }
        case "quietWhenLocked": if let v = value as? Bool { quietWhenLocked = v }
        case "quietDuringCalls": if let v = value as? Bool { quietDuringCalls = v }
        case "lcdTheme": if let v = value as? String, ["auto", "day", "night"].contains(v) { lcdTheme = v }
        case "pausedUntil": pausedUntil = Self.validDate(value)
        case "skippedChime": skippedChime = Self.validDate(value)
        default: break
        }
    }

    /// The value as stored, in the same form `apply` and `forward` use.
    func storedValue(_ key: String) -> Any? {
        switch key {
        case "interval": intervalMinutes
        case "sound": soundID
        case "speakTime": speakTime
        case "volume": volume
        case "activeHoursEnabled": activeHoursEnabled
        case "activeStart": activeStart
        case "activeEnd": activeEnd
        case "activeWeekdays": activeWeekdays.sorted()
        case "quietWhenLocked": quietWhenLocked
        case "quietDuringCalls": quietDuringCalls
        case "lcdTheme": lcdTheme
        case "pausedUntil": pausedUntil
        case "skippedChime": skippedChime
        default: nil
        }
    }

    static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (x?, y?): (x as AnyObject).isEqual(y)
        default: false
        }
    }

    /// UI process: take the agent's value without sending it back.
    func applyFromAgent(_ key: String, _ value: Any?) {
        applyingFromAgent = true
        defer { applyingFromAgent = false }
        apply(key, value)
    }

    var snapshot: [String: Any] {
        Dictionary(uniqueKeysWithValues: Self.keys.map { ($0, IPC.encode(storedValue($0))) })
    }

    func applySnapshot(_ snapshot: [String: Any]) {
        for key in Self.keys {
            guard let encoded = snapshot[key] else { continue }
            let value = IPC.decode(encoded)
            if !Self.same(storedValue(key), value) { applyFromAgent(key, value) }
        }
    }

    var rules: ChimeRules {
        ChimeRules(
            intervalMinutes: intervalMinutes,
            activeHours: activeHoursEnabled ? (activeStart, activeEnd) : nil,
            weekdays: activeHoursEnabled ? activeWeekdays : nil,
            pausedUntil: pausedUntil,
            skipped: skippedChime
        )
    }
}
