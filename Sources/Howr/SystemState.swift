import CoreAudio
import CoreGraphics

/// Point-in-time system checks, evaluated only when a chime is about to play.
enum SystemState {
    static var isScreenLockedOrAsleep: Bool {
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return true }
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (info["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// True when another process is actually capturing audio input (calls, recordings, dictation).
    /// Uses CoreAudio's per-process "is running input" state, so playback through a headset that
    /// is both input and output does not count. Reads state only; needs no microphone permission.
    static var isMicrophoneInUse: Bool {
        if #available(macOS 14.2, *) { return anyProcessCapturing() }
        return defaultInputRunning()
    }

    @available(macOS 14.2, *)
    private static func anyProcessCapturing() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return false }

        let me = ProcessInfo.processInfo.processIdentifier
        for process in processes {
            var running = UInt32(0)
            var rsize = UInt32(MemoryLayout<UInt32>.size)
            address.mSelector = kAudioProcessPropertyIsRunningInput
            guard AudioObjectGetPropertyData(process, &address, 0, nil, &rsize, &running) == noErr, running != 0 else { continue }
            var pid = pid_t(0)
            var psize = UInt32(MemoryLayout<pid_t>.size)
            address.mSelector = kAudioProcessPropertyPID
            if AudioObjectGetPropertyData(process, &address, 0, nil, &psize, &pid) == noErr, pid == me { continue }
            return true
        }
        return false
    }

    /// Fallback for macOS 14.0–14.1: the default input device is running for someone.
    private static func defaultInputRunning() -> Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return false }

        var running = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }
}
