import SwiftUI

/// The Settings window, drawn entirely as one LCD watch face.
///
/// Mouse: click anything; ▶ previews a sound; click time digits to advance them (⌥-click goes back).
/// Keyboard: ↑↓/Tab move between rows, ←→ change the value, Space/Return toggles or selects,
/// L cycles the backlight, Esc closes.
///
/// Keyboard focus is a solid frame and mouse hover a thin one, so neither hides the other.
struct SettingsView: View {
    @EnvironmentObject var settings: Settings
    var player: PreviewClient
    var close: () -> Void
    @ObservedObject var loginItem: LoginItem

    @State private var focus: Row?
    @State private var hover: Row?
    @State private var hoverDay: Int?
    @State private var hoverPart: String?
    @State private var dayCursor = 0
    @State private var previewWork: DispatchWorkItem?
    @FocusState private var hasKeyFocus: Bool
    @Environment(\.lcd) private var lcd

    enum Row: Hashable {
        case interval, sound(String), macSound, speak, volume, active, start, end, days, quietCalls, quietLocked, login, loginApproval
    }

    /// Built-in chimes plus an explicit NONE (useful with "speak the time").
    private static let listIDs = Synth.Voice.allCases.map { "synth:\($0.rawValue)" } + [SoundLibrary.noneID]
    /// macOS alert sounds, reached through the ◀ ▶ cycler.
    private static let macIDs = SoundLibrary.all.map(\.id).filter { $0.hasPrefix("system:") }

    private var rowOrder: [Row] {
        var rows: [Row] = [.interval] + Self.listIDs.map(Row.sound) + [.macSound, .speak, .volume, .active]
        if settings.activeHoursEnabled { rows += [.start, .end, .days] }
        rows += [.quietCalls, .quietLocked, .login]
        if loginItem.state == .needsApproval { rows.append(.loginApproval) }
        return rows
    }

    private var calendar: Calendar { .autoupdatingCurrent }
    private var orderedWeekdays: [Int] { (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 } }

    var body: some View {
        WatchCase(mode: nil) {
            VStack(alignment: .leading, spacing: 7) {
                header
                LCDDivider()
                intervalRow
                LCDDivider()
                soundSection
                LCDDivider()
                volumeRow
                LCDDivider()
                activeSection
                LCDDivider()
                toggleRow(.quietCalls, "QUIET WHILE MIC IN USE", isOn: settings.quietDuringCalls) { settings.quietDuringCalls = $0 }
                    .help("Skip the chime while any app is recording from a microphone — calls, recordings, dictation")
                toggleRow(.quietLocked, "QUIET WHEN LOCKED", isOn: settings.quietWhenLocked) { settings.quietWhenLocked = $0 }
                    .help("Skip the chime while the screen is locked or asleep")
                LCDDivider()
                loginRow
                footer
            }
            .padding(16)
        }
        .frame(width: 470)
        .focusable()
        .focusEffectDisabled()
        .focused($hasKeyFocus)
        .onAppear { hasKeyFocus = true; loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in loginItem.refresh() }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.leftArrow) { adjust(-1) }
        .onKeyPress(.rightArrow) { adjust(1) }
        .onKeyPress(.space) { activate() }
        .onKeyPress(.return) { activate() }
        .onKeyPress(.escape) { close(); return .handled }
        .onKeyPress(keys: [.tab]) { press in move(press.modifiers.contains(.shift) ? -1 : 1); return .handled }
        .onKeyPress("l") { settings.cycleLCDTheme(); return .handled }
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            PixelText("HOWR SETTINGS", dot: 3)
            Spacer()
            PixelText("[×]", dot: 2.6)
                .frame(minWidth: 36, minHeight: 28)
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
                .help("Close (Esc)")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Close settings")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { close() }
        }
    }

    private var intervalRow: some View {
        row(.interval) { inv in
            HStack {
                label("INTERVAL", inv)
                Spacer()
                ForEach(Settings.allowedIntervals, id: \.self) { m in
                    let on = settings.intervalMinutes == m
                    LCDChip(text: on ? "[\(m)]" : "\(m)", on: on, inverted: false, dot: 2.6)
                        .frame(minWidth: 58, minHeight: 26)
                        .contentShape(Rectangle())
                        .highPriorityGesture(TapGesture().onEnded { settings.intervalMinutes = m })
                }
                PixelText("MIN", dot: 1.6)
            }
        }
        .onTapGesture { stepInterval(1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Interval")
        .accessibilityValue("Every \(settings.intervalMinutes) minutes")
        .accessibilityAdjustableAction { stepInterval($0 == .increment ? 1 : -1) }
    }

    private var soundSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            label("SOUND", false)
            ForEach(Self.listIDs, id: \.self) { id in soundRow(id) }
            macSoundRow
            toggleRow(.speak, "SPEAK THE TIME", isOn: settings.speakTime) { settings.speakTime = $0 }
                .help("After the sound, a voice says the time")
        }
    }

    private func soundRow(_ id: String) -> some View {
        let selected = settings.soundID == id
        let name = id == SoundLibrary.noneID ? "NONE" : SoundLibrary.name(for: id)
        return row(.sound(id), selected: selected) { inv in
            HStack {
                PixelText(name, dot: 2.4, color: inv ? lcd.glass : lcd.ink).padding(.leading, 12)
                if id == SoundLibrary.noneID { PixelText("(VOICE ONLY / SILENT)", dot: 1.5, color: inv ? lcd.glass : lcd.ink).opacity(0.75) }
                Spacer()
                if id != SoundLibrary.noneID { previewButton(id, inverted: inv) }
            }
        }
        .onTapGesture { select(id) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(id == SoundLibrary.noneID ? "No sound" : SoundLibrary.name(for: id))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select(id) }
        .accessibilityAction(named: "Preview") { player.preview(soundID: id, speak: false) }
    }

    /// One row that cycles through the macOS alert sounds, so the list stays short.
    private var macSoundRow: some View {
        let isMac = settings.soundID.hasPrefix("system:")
        let current = isMac ? settings.soundID : (Self.macIDs.first ?? SoundLibrary.noneID)
        return row(.macSound, selected: isMac) { inv in
            HStack(spacing: 4) {
                PixelText("MAC", dot: 2.4, color: inv ? lcd.glass : lcd.ink).padding(.leading, 12)
                arrowButton("◀", inverted: inv, help: "Previous Mac sound") { cycleMac(-1) }
                PixelText(SoundLibrary.name(for: current), dot: 2.4, color: inv ? lcd.glass : lcd.ink)
                    .frame(minWidth: 120)
                arrowButton("▶", inverted: inv, help: "Next Mac sound") { cycleMac(1) }
                Spacer()
                previewButton(current, inverted: inv)
            }
        }
        .onTapGesture { select(current) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mac sound")
        .accessibilityValue(SoundLibrary.name(for: current) + (isMac ? ", selected" : ""))
        .accessibilityAdjustableAction { cycleMac($0 == .increment ? 1 : -1) }
        .accessibilityAction { select(current) }
        .accessibilityAction(named: "Preview") { player.preview(soundID: current, speak: false) }
    }

    private func arrowButton(_ glyph: String, inverted: Bool, help: String, action: @escaping () -> Void) -> some View {
        HoverGlyph(glyph: glyph, inverted: inverted, action: action).help(help)
    }

    private func previewButton(_ id: String, inverted: Bool) -> some View {
        HoverGlyph(glyph: "▶", inverted: inverted) { player.preview(soundID: id, speak: false) }
            .help("Preview")
    }

    private var volumeRow: some View {
        row(.volume) { inv in
            HStack(spacing: 12) {
                label("VOLUME", inv)
                Spacer()
                VolumeBar(value: $settings.volume, inverted: inv, cell: CGSize(width: 17, height: 20)) { schedulePreview() }
                PixelText(settings.volume == 0 ? "OFF" : String(format: "%3d", Int(settings.volume * 100)), dot: 2.6, color: inv ? lcd.glass : lcd.ink)
                    .frame(minWidth: 44, alignment: .trailing)
            }
        }
    }

    private var activeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            toggleRow(.active, "ACTIVE HOURS", isOn: settings.activeHoursEnabled) { settings.activeHoursEnabled = $0 }
                .help("Only chime between these times, on the selected days")
            Group {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    timeField(.start, minutes: $settings.activeStart)
                    PixelText("-", dot: 4)
                    timeField(.end, minutes: $settings.activeEnd)
                    Spacer(minLength: 0)
                }
                HStack {
                    Spacer()
                    PixelText("CLICK DIGITS TO ADVANCE · OPT-CLICK TO GO BACK", dot: 1.5)
                        .opacity(0.8)
                    Spacer()
                }
                .accessibilityHidden(true)
                daysRow
            }
            .opacity(settings.activeHoursEnabled ? 1 : 0.28)
            .allowsHitTesting(settings.activeHoursEnabled)
            .accessibilityHidden(!settings.activeHoursEnabled)
        }
    }

    private func timeField(_ r: Row, minutes: Binding<Int>) -> some View {
        let m = minutes.wrappedValue
        let (text, ampm) = LCDFormat.clock(minutes: m)
        let parts = text.split(separator: ":").map(String.init)
        let key = r == .start ? "start" : "end"
        return HStack(alignment: .bottom, spacing: 4) {
            digitGroup(parts[0], id: "\(key).h") { stepTime(minutes, by: optionHeld ? -60 : 60) }
                .help("Hours: click +1 · ⌥-click −1")
            SevenSegment(text: ":", digitHeight: 44)
            digitGroup(parts[1], id: "\(key).m") { stepTime(minutes, by: optionHeld ? -15 : 15) }
                .help("Minutes: click +15 · ⌥-click −15")
            if !ampm.isEmpty { PixelText(ampm, dot: 2) }
        }
        .padding(5)
        .overlay(focusRing(r))
        .onHover { hover = $0 ? r : (hover == r ? nil : hover) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(r == .start ? "Start time" : "End time")
        .accessibilityValue(LCDFormat.spoken(minutes: m))
        .accessibilityAdjustableAction { stepTime(minutes, by: $0 == .increment ? 15 : -15) }
    }

    /// Hour or minute digits; hovering shows an underline so it's clear they are clickable.
    private func digitGroup(_ text: String, id: String, action: @escaping () -> Void) -> some View {
        SevenSegment(text: text, digitHeight: 44)
            .padding(.bottom, 4)
            .overlay(alignment: .bottom) {
                Rectangle().fill(lcd.ink).frame(height: 2).opacity(hoverPart == id ? 1 : 0)
            }
            .contentShape(Rectangle())
            .onHover { hoverPart = $0 ? id : (hoverPart == id ? nil : hoverPart) }
            .onTapGesture(perform: action)
    }

    private var daysRow: some View {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return HStack(spacing: 8) {
            Spacer(minLength: 0)
            ForEach(Array(orderedWeekdays.enumerated()), id: \.offset) { i, wd in
                let on = settings.activeWeekdays.contains(wd)
                let ringed = hoverDay == i || (focus == .days && dayCursor == i)
                PixelText(symbols[wd - 1], dot: 2.6, color: on ? lcd.glass : lcd.ink)
                    .frame(width: 34, height: 28)
                    .background(on ? lcd.ink : .clear)
                    .overlay(Rectangle().strokeBorder(lcd.ink, lineWidth: 1.5))
                    .overlay(Rectangle().strokeBorder(lcd.ink, lineWidth: 1.5).padding(-4).opacity(ringed ? 1 : 0))
                    .contentShape(Rectangle())
                    .onHover { hoverDay = $0 ? i : (hoverDay == i ? nil : hoverDay) }
                    .onTapGesture { toggleDay(wd) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(calendar.standaloneWeekdaySymbols[wd - 1])
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { toggleDay(wd) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var loginRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            toggleRow(.login, "LAUNCH AT LOGIN", isOn: loginItem.state == .on || loginItem.state == .needsApproval) { setLogin($0) }
            if loginItem.state == .needsApproval {
                PixelText("NEEDS APPROVAL · OPEN SYSTEM SETTINGS ▶", dot: 1.8)
                    .padding(.leading, 6)
                    .frame(minHeight: 22)
                    .contentShape(Rectangle())
                    .onTapGesture { LaunchAtLogin.openSystemSettings() }
                    .overlay { focusRing(.loginApproval) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Approve login item in System Settings")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { LaunchAtLogin.openSystemSettings() }
            } else if loginItem.state == .unavailable || loginItem.error != nil {
                PixelText(loginItem.error == nil ? "ONLY WORKS FROM HOWR.APP" : "COULD NOT CHANGE LOGIN ITEM", dot: 1.8)
                    .padding(.leading, 6)
                    .help(loginItem.error ?? "Move Howr.app to Applications and open it from there")
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            VStack(spacing: 4) {
                PixelText("UP/DN MOVE · ◀▶ CHANGE · SPACE SELECT", dot: 1.6)
                PixelText("L LIGHT · ESC CLOSE", dot: 1.6)
            }
            .opacity(0.8)
            Spacer()
        }
        .padding(.top, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Keyboard: arrow keys move and change values, Space selects, L switches the backlight, Escape closes.")
    }

    // MARK: Building blocks

    private func label(_ text: String, _ inverted: Bool) -> some View {
        PixelText(text, dot: 2.6, color: inverted ? lcd.glass : lcd.ink)
    }

    /// Keyboard focus = solid 2px frame; mouse hover = thin 1px frame. Both can show at once.
    private func focusRing(_ r: Row, selected: Bool = false) -> some View {
        let c = selected ? lcd.glass : lcd.ink
        return ZStack {
            Rectangle().strokeBorder(c, lineWidth: 2.5).padding(selected ? 2 : -3).opacity(focus == r ? 1 : 0)
            Rectangle().strokeBorder(c, lineWidth: 1).padding(selected ? 2 : -3).opacity(hover == r && focus != r ? 1 : 0)
        }
        .allowsHitTesting(false)
    }

    /// A row that shows focus/hover frames, and an inverted bar when `selected`.
    private func row<C: View>(_ r: Row, selected: Bool = false, @ViewBuilder content: @escaping (_ inverted: Bool) -> C) -> some View {
        LCDRow(highlighted: selected) { inv in content(inv) }
            .overlay(focusRing(r, selected: selected))
            .onHover { hover = $0 ? r : (hover == r ? nil : hover) }
    }

    /// Clicking ON or OFF sets that value; clicking elsewhere on the row toggles.
    private func toggleRow(_ r: Row, _ title: String, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        row(r) { inv in
            HStack {
                label(title, inv)
                Spacer()
                LCDChip(text: "ON", on: isOn, inverted: inv, dot: 2.4)
                    .frame(minWidth: 44, minHeight: 24).contentShape(Rectangle())
                    .highPriorityGesture(TapGesture().onEnded { set(true) })
                LCDChip(text: "OFF", on: !isOn, inverted: inv, dot: 2.4)
                    .frame(minWidth: 52, minHeight: 24).contentShape(Rectangle())
                    .highPriorityGesture(TapGesture().onEnded { set(false) })
            }
        }
        .onTapGesture { set(!isOn) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title.lowercased().capitalizingFirstLetter)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { set(!isOn) }
    }

    private var optionHeld: Bool { NSEvent.modifierFlags.contains(.option) }

    // MARK: Actions

    private func select(_ id: String) {
        settings.soundID = id
        if id != SoundLibrary.noneID { player.preview(soundID: id, speak: false) }
    }

    private func cycleMac(_ d: Int) {
        let ids = Self.macIDs
        guard !ids.isEmpty else { return }
        // From a built-in sound, either arrow lands on the first Mac sound.
        guard let cur = ids.firstIndex(of: settings.soundID) else { select(ids[0]); return }
        select(ids[(cur + d + ids.count) % ids.count])
    }

    private func stepInterval(_ d: Int) {
        let all = Settings.allowedIntervals
        let i = all.firstIndex(of: settings.intervalMinutes) ?? 0
        settings.intervalMinutes = all[(i + d + all.count) % all.count]
    }

    private func stepTime(_ b: Binding<Int>, by d: Int) {
        b.wrappedValue = ((b.wrappedValue + d) % 1440 + 1440) % 1440
    }

    private func toggleDay(_ wd: Int) {
        if settings.activeWeekdays.contains(wd) { settings.activeWeekdays.remove(wd) } else { settings.activeWeekdays.insert(wd) }
    }

    private func setLogin(_ on: Bool) {
        // Already registered but waiting for approval: the useful action is to go approve it.
        if on, loginItem.state == .needsApproval { LaunchAtLogin.openSystemSettings(); return }
        loginItem.set(on)
    }

    private func schedulePreview() {
        previewWork?.cancel()
        let work = DispatchWorkItem { [player] in player.preview(speak: false) }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func move(_ d: Int) {
        let rows = rowOrder
        let i = focus.flatMap { rows.firstIndex(of: $0) } ?? (d > 0 ? -1 : rows.count)
        focus = rows[(i + d + rows.count) % rows.count]
    }

    private func adjust(_ d: Int) -> KeyPress.Result {
        switch focus {
        case .interval: stepInterval(d)
        case .sound(let id):
            // ←→ walks the sound list, selecting (and previewing) as it goes.
            let ids = Self.listIDs
            let i = ids.firstIndex(of: id) ?? 0
            let next = ids[(i + d + ids.count) % ids.count]
            select(next)
            focus = .sound(next)
        case .macSound: cycleMac(d)
        case .volume:
            settings.volume = min(1, max(0, ((settings.volume + Double(d) * 0.1) * 10).rounded() / 10))
            schedulePreview()
        case .start: stepTime($settings.activeStart, by: d * 15)
        case .end: stepTime($settings.activeEnd, by: d * 15)
        case .days: dayCursor = (dayCursor + d + 7) % 7
        case .speak: settings.speakTime = d > 0
        case .active: settings.activeHoursEnabled = d > 0
        case .quietCalls: settings.quietDuringCalls = d > 0
        case .quietLocked: settings.quietWhenLocked = d > 0
        case .login: setLogin(d > 0)
        case .loginApproval: return .ignored
        case nil: return .ignored
        }
        return .handled
    }

    private func activate() -> KeyPress.Result {
        switch focus {
        case .sound(let id): select(id)
        case .macSound: select(settings.soundID.hasPrefix("system:") ? settings.soundID : (Self.macIDs.first ?? SoundLibrary.noneID))
        case .speak: settings.speakTime.toggle()
        case .active: settings.activeHoursEnabled.toggle()
        case .days: toggleDay(orderedWeekdays[dayCursor])
        case .quietCalls: settings.quietDuringCalls.toggle()
        case .quietLocked: settings.quietWhenLocked.toggle()
        case .login: setLogin(!(loginItem.state == .on || loginItem.state == .needsApproval))
        case .loginApproval: LaunchAtLogin.openSystemSettings()
        case .interval: stepInterval(1)
        case .volume: player.preview(speak: false)
        case .start, .end: return .ignored
        case nil: return .ignored
        }
        return .handled
    }
}

/// A small LCD glyph button (◀ ▶) with a ≥ 28×24 pt target that inverts on hover.
/// Uses a high-priority tap so it never also triggers the row underneath.
struct HoverGlyph: View {
    var glyph: String
    var inverted: Bool
    var action: () -> Void
    @State private var hover = false
    @Environment(\.lcd) private var lcd

    var body: some View {
        // On a normal row hover inverts to dark; on an already-inverted (selected) row it inverts to light.
        PixelText(glyph, dot: 2.4, color: hover != inverted ? lcd.glass : lcd.ink)
            .frame(minWidth: 28, minHeight: 24)
            .background(hover ? (inverted ? lcd.glass : lcd.ink) : .clear)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .highPriorityGesture(TapGesture().onEnded(action))
            .accessibilityHidden(true)   // the row exposes these as named actions
    }
}

extension String {
    var capitalizingFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}
