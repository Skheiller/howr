import SwiftUI

/// The dropdown under the menu bar icon: a full watch face with a short action list.
struct PopoverView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var scheduler: ChimeStatus
    var player: PreviewClient
    var openSettings: () -> Void
    var close: () -> Void
    var quit: () -> Void

    @State private var focus: Int?
    @State private var hover: Int?
    @FocusState private var hasKeyFocus: Bool
    @State private var previewWork: DispatchWorkItem?
    @State private var flash: String?
    @State private var flashWork: DispatchWorkItem?
    @Environment(\.lcd) private var lcd

    private enum Item: Equatable {
        case pause1h, pauseTomorrow, resume, skip, unskip, test, volume, settings, quit
    }

    private var isPaused: Bool { (settings.pausedUntil ?? .distantPast) > Date() }

    private var items: [Item] {
        var list: [Item] = isPaused ? [.resume] : [.pause1h, .pauseTomorrow]
        if !isPaused { list.append(settings.skippedChime == nil ? .skip : .unskip) }
        list += [.test, .volume, .settings, .quit]
        return list
    }

    var body: some View {
        WatchCase(mode: openSettings) {
            VStack(alignment: .leading, spacing: 6) {
                face
                LCDDivider()
                VStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                        if item == .volume {
                            LCDDivider().padding(.vertical, 3)
                            volumeRow(index: i)
                            LCDDivider().padding(.vertical, 3)
                        } else {
                            actionRow(item, index: i)
                        }
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 300)
        .focusable()
        .focusEffectDisabled()
        .focused($hasKeyFocus)
        .onAppear { hasKeyFocus = true }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.leftArrow) { nudgeVolume(-0.1) }
        .onKeyPress(.rightArrow) { nudgeVolume(0.1) }
        .onKeyPress(.return) { activateFocused() }
        .onKeyPress(.space) { activateFocused() }
        .onKeyPress(.escape) { close(); return .handled }
        .onKeyPress(keys: [.tab]) { press in move(press.modifiers.contains(.shift) ? -1 : 1); return .handled }
        .onKeyPress("l") { settings.cycleLCDTheme(); return .handled }
        .onKeyPress(",") { openSettings(); return .handled }
    }

    // MARK: Face

    private var face: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let (time, ampm) = LCDFormat.clock(ctx.date)
            let colonOn = Calendar.current.component(.second, from: ctx.date) % 2 == 0
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    PixelText(LCDFormat.dayLabel(ctx.date), dot: 2.4,
                              label: ctx.date.formatted(.dateTime.weekday(.wide).day()))
                    Spacer()
                    // Like the watch's alarm indicator: waves while chimes are on.
                    BellIcon(on: !isPaused && scheduler.nextChime != nil, dot: 2.2)
                }
                HStack(alignment: .bottom, spacing: 6) {
                    Spacer(minLength: 0)
                    SevenSegment(text: time, digitHeight: 58, colonLit: colonOn)
                    if !ampm.isEmpty { PixelText(ampm, dot: 2.6).padding(.bottom, 2) }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Time \(LCDFormat.short(ctx.date))")
                HStack {
                    Spacer()
                    PixelText(flash ?? LCDFormat.status(next: scheduler.nextChime, pausedUntil: settings.pausedUntil, now: ctx.date), dot: 2.2,
                              label: flash ?? LCDFormat.statusSentence(next: scheduler.nextChime, pausedUntil: settings.pausedUntil, now: ctx.date))
                    Spacer()
                }
            }
        }
    }

    // MARK: Rows

    private func title(_ item: Item) -> String {
        switch item {
        case .pause1h: "[ PAUSE 1H ]"
        case .pauseTomorrow: "[ TIL TOMORROW ]"
        case .resume: "[ RESUME ]"
        case .skip: "[ SKIP NEXT ]"
        case .unskip: "[ UNDO SKIP ]"
        case .test: "[ TEST ]"
        case .settings: "SETTINGS"
        case .quit: "QUIT"
        case .volume: "VOL"
        }
    }

    private func accessibilityTitle(_ item: Item) -> String {
        switch item {
        case .pause1h: "Pause for 1 hour"
        case .pauseTomorrow: "Pause until tomorrow"
        case .resume: "Resume chimes"
        case .skip: "Skip next chime"
        case .unskip: "Undo skip"
        case .test: "Test chime"
        case .settings: "Settings"
        case .quit: "Quit Howr"
        case .volume: "Volume"
        }
    }

    /// Mouse hover inverts a row; keyboard focus draws a frame. Both can show at once.
    private func focusFrame(_ i: Int, inverted: Bool) -> some View {
        Rectangle().strokeBorder(inverted ? lcd.glass : lcd.ink, lineWidth: 2)
            .padding(inverted ? 2 : 0)
            .opacity(focus == i ? 1 : 0)
            .allowsHitTesting(false)
    }

    private func actionRow(_ item: Item, index i: Int) -> some View {
        LCDRow(highlighted: hover == i) { inv in
            HStack {
                PixelText(title(item), dot: 2.4, color: inv ? lcd.glass : lcd.ink)
                Spacer()
                if item == .settings || item == .quit {
                    PixelText(item == .settings ? "⚙" : "⏻", dot: 2.2, color: inv ? lcd.glass : lcd.ink)
                    PixelText(">", dot: 2.2, color: inv ? lcd.glass : lcd.ink).padding(.leading, 18)
                }
            }
        }
        .overlay(focusFrame(i, inverted: hover == i))
        .onHover { hover = $0 ? i : (hover == i ? nil : hover) }
        .onTapGesture { perform(item) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle(item))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { perform(item) }
    }

    private func volumeRow(index i: Int) -> some View {
        LCDRow(highlighted: hover == i) { inv in
            HStack(spacing: 8) {
                PixelText("VOL", dot: 2.2, color: inv ? lcd.glass : lcd.ink)
                VolumeBar(value: $settings.volume, inverted: inv, cell: CGSize(width: 13, height: 16)) { schedulePreview() }
                Spacer(minLength: 0)
                PixelText(settings.volume == 0 ? "OFF" : String(format: "%3d", Int(settings.volume * 100)), dot: 2.2, color: inv ? lcd.glass : lcd.ink)
            }
        }
        .overlay(focusFrame(i, inverted: hover == i))
        .onHover { hover = $0 ? i : (hover == i ? nil : hover) }
    }

    // MARK: Actions

    private func perform(_ item: Item) {
        switch item {
        case .pause1h: scheduler.pause(for: 3600)
        case .pauseTomorrow: scheduler.pauseUntilTomorrow()
        case .resume: scheduler.resume()
        case .skip: scheduler.skipNext()
        case .unskip: settings.skippedChime = nil
        case .test: if !player.preview() { showFlash(settings.volume == 0 ? "MUTED · RAISE VOL" : "NO SOUND SELECTED") }
        case .settings: openSettings()
        case .quit: quit()
        case .volume: break
        }
    }

    private func move(_ delta: Int) {
        let n = items.count
        focus = ((focus ?? (delta > 0 ? -1 : n)) + delta + n) % n
    }

    private func activateFocused() -> KeyPress.Result {
        guard let f = focus, items.indices.contains(f) else { return .ignored }
        perform(items[f])
        return .handled
    }

    private func nudgeVolume(_ d: Double) -> KeyPress.Result {
        guard let f = focus, items.indices.contains(f), items[f] == .volume else { return .ignored }
        settings.volume = min(1, max(0, ((settings.volume + d) * 10).rounded() / 10))
        schedulePreview()
        return .handled
    }

    /// Briefly replaces the status line, e.g. when Test can't be heard.
    private func showFlash(_ text: String) {
        flashWork?.cancel()
        flash = text
        let work = DispatchWorkItem { flash = nil }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    /// Plays the current sound once the user stops adjusting the volume.
    private func schedulePreview() {
        previewWork?.cancel()
        let work = DispatchWorkItem { [player] in player.preview(speak: false) }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
}
