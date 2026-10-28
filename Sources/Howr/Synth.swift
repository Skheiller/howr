import Foundation

/// Tiny additive synthesizer for the built-in chimes. Sounds are rendered on demand into an
/// in-memory WAV (a few hundred KB at most) and released after playback, so nothing is bundled
/// and nothing stays resident between chimes.
enum Synth {
    static let sampleRate = 44_100.0

    enum Voice: String, CaseIterable {
        case chirp, beep, cuckoo, bell, westminster, bowl

        var displayName: String {
            switch self {
            case .chirp: "F-91W Chirp"
            case .beep: "Soft Beep"
            case .cuckoo: "Cuckoo"
            case .bell: "Bell"
            case .westminster: "Westminster"
            case .bowl: "Singing Bowl"
            }
        }
    }

    static func wav(for voice: Voice) -> Data {
        encodeWAV(render(voice))
    }

    static func render(_ voice: Voice) -> [Float] {
        switch voice {
        case .chirp:
            // The classic digital-watch hourly signal: two short piezo beeps around 4 kHz.
            var buf = silence(0.32)
            for start in [0.0, 0.13] { mixPiezo(into: &buf, at: start, freq: 4096, duration: 0.06, gain: 0.32) }
            return buf
        case .beep:
            var buf = silence(0.5)
            mixTone(into: &buf, at: 0, freq: 880, duration: 0.45, partials: [(1, 1), (2, 0.15)], attack: 0.01, decay: 9, gain: 0.5)
            return buf
        case .cuckoo:
            // Two pipe notes a minor third apart, played twice.
            var buf = silence(1.6)
            for (i, start) in [0.0, 0.7].enumerated() {
                let g: Float = i == 0 ? 0.55 : 0.5
                mixTone(into: &buf, at: start, freq: 784, duration: 0.3, partials: [(1, 1), (2, 0.25), (3, 0.08)], attack: 0.02, decay: 7, gain: g)
                mixTone(into: &buf, at: start + 0.3, freq: 659, duration: 0.42, partials: [(1, 1), (2, 0.25), (3, 0.08)], attack: 0.02, decay: 6, gain: g)
            }
            return buf
        case .bell:
            var buf = silence(3.2)
            mixBell(into: &buf, at: 0, freq: 392, duration: 3.2, gain: 0.5)
            return buf
        case .westminster:
            // First quarter of the Westminster Quarters: G#4 F#4 E4 B3.
            let notes: [Double] = [415.30, 369.99, 329.63, 246.94]
            var buf = silence(0.75 * 3 + 2.8)
            for (i, f) in notes.enumerated() {
                mixBell(into: &buf, at: Double(i) * 0.75, freq: f, duration: i == 3 ? 2.8 : 1.6, gain: 0.38)
            }
            return buf
        case .bowl:
            // Slightly detuned partial pairs give the slow "wah-wah" beating of a singing bowl.
            var buf = silence(4.5)
            let f = 262.0
            for (ratio, amp, decay) in [(1.0, 1.0, 0.9), (2.76, 0.45, 1.4), (5.4, 0.18, 2.2), (8.9, 0.06, 3.0)] {
                mixTone(into: &buf, at: 0, freq: f * ratio, duration: 4.5, partials: [(1, amp)], attack: 0.04, decay: decay, gain: 0.28)
                mixTone(into: &buf, at: 0, freq: f * ratio * 1.004, duration: 4.5, partials: [(1, amp)], attack: 0.04, decay: decay, gain: 0.28)
            }
            return buf
        }
    }

    // MARK: - Building blocks

    private static func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * sampleRate)) }

    /// Sum of harmonic partials with a linear attack and exponential decay.
    private static func mixTone(into buf: inout [Float], at start: Double, freq: Double, duration: Double,
                                partials: [(Double, Double)], attack: Double, decay: Double, gain: Float) {
        let s0 = Int(start * sampleRate)
        let n = min(Int(duration * sampleRate), buf.count - s0)
        guard n > 0 else { return }
        let release = min(0.02, duration / 4) * sampleRate
        for i in 0..<n {
            let t = Double(i) / sampleRate
            var env = exp(-decay * t)
            if t < attack { env *= t / attack }
            let remaining = Double(n - i)
            if remaining < release { env *= remaining / release }
            var v = 0.0
            for (mult, amp) in partials { v += amp * sin(2 * .pi * freq * mult * t) }
            buf[s0 + i] += Float(v * env) * gain
        }
    }

    /// Inharmonic church-bell spectrum (hum, prime, tierce, quint, nominal…).
    private static func mixBell(into buf: inout [Float], at start: Double, freq: Double, duration: Double, gain: Float) {
        let spectrum: [(Double, Double, Double)] = [
            (0.5, 0.35, 0.8), (1.0, 1.0, 1.2), (1.19, 0.55, 1.6), (1.5, 0.3, 2.0),
            (2.0, 0.5, 2.4), (2.52, 0.2, 3.2), (3.0, 0.15, 4.0), (4.07, 0.08, 5.5),
        ]
        for (ratio, amp, decay) in spectrum {
            mixTone(into: &buf, at: start, freq: freq * ratio, duration: duration, partials: [(1, amp)], attack: 0.002, decay: decay, gain: gain * 0.45)
        }
    }

    /// Soft-clipped square-ish tone, like a watch's piezo buzzer.
    private static func mixPiezo(into buf: inout [Float], at start: Double, freq: Double, duration: Double, gain: Float) {
        let s0 = Int(start * sampleRate)
        let n = min(Int(duration * sampleRate), buf.count - s0)
        guard n > 0 else { return }
        let edge = 0.004 * sampleRate
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let env = min(1, Double(i) / edge, Double(n - i) / edge)
            buf[s0 + i] += Float(tanh(2.5 * sin(2 * .pi * freq * t)) * env) * gain
        }
    }

    // MARK: - WAV

    static func encodeWAV(_ samples: [Float]) -> Data {
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        let scale: Float = peak > 0.98 ? 0.98 / peak : 1
        var data = Data(capacity: 44 + samples.count * 2)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let rate = UInt32(sampleRate)
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + samples.count * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(rate); u32(rate * 2); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(samples.count * 2))
        for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s * scale)) * 32767))) }
        return data
    }
}
