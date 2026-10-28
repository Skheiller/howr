import SwiftUI

/// The black resin watch case around every LCD surface, with its printed labels.
/// LIGHT cycles the backlight (auto → day → night); MODE is an optional action.
struct WatchCase<Content: View>: View {
    var mode: (() -> Void)?
    @ViewBuilder var content: Content
    @EnvironmentObject private var settings: Settings
    @Environment(\.lcd) private var lcd

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                PixelText("HOWR · HOURLY CHIME", dot: 1.4, color: Color(red: 0.42, green: 0.62, blue: 0.95))
                HStack {
                    CaseButton(label: "LIGHT", stripe: lcd.accent, leading: true, help: lightHelp) { settings.cycleLCDTheme() }
                    Spacer()
                    if let mode { CaseButton(label: "MODE", stripe: Color(red: 0.28, green: 0.5, blue: 0.95), leading: false, help: "Open settings", action: mode) }
                }
                .padding(.top, 14)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            content
                .background(Glass())
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.black.opacity(0.55), lineWidth: 2))
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.17), lcd.bezel, Color(white: 0.05)], startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color(red: 0.2, green: 0.38, blue: 0.85).opacity(0.75), lineWidth: 1.5)
                        .padding(5)
                )
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        )
    }

    private var lightHelp: String {
        switch settings.lcdTheme {
        case "day": "Display: daylight · click (or press L) for backlight"
        case "night": "Display: backlight · click (or press L) for automatic"
        default: "Display: automatic · click (or press L) for daylight"
        }
    }

    private struct Glass: View {
        @Environment(\.lcd) private var lcd
        var body: some View {
            ZStack {
                lcd.glass
                // Reflective sheen and the dark rim where the glass meets the case.
                LinearGradient(colors: [.white.opacity(0.10), .clear, .black.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(lcd.glassEdge, lineWidth: 5)
                    .blur(radius: 4)
            }
        }
    }

    private struct CaseButton: View {
        var label: String
        var stripe: Color
        var leading: Bool
        var help: String
        var action: () -> Void
        @State private var hover = false
        @Environment(\.lcd) private var lcd

        var body: some View {
            Button(action: action) {
                HStack(spacing: 4) {
                    if leading { Capsule().fill(stripe).frame(width: 10, height: 3) }
                    PixelText(label, dot: 1.2, color: hover ? .white : lcd.bezelText)
                    if !leading { Capsule().fill(stripe).frame(width: 10, height: 3) }
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help(help)
            .accessibilityLabel(label == "LIGHT" ? "Light" : "Mode")
            .accessibilityHint(help)
        }
    }
}

/// A 2-pixel segment line separating LCD sections.
struct LCDDivider: View {
    @Environment(\.lcd) private var lcd
    var body: some View { Rectangle().fill(lcd.ink.opacity(0.85)).frame(height: 2) }
}

/// A full-width LCD row that inverts (dark bar, light text) when hovered or keyboard-focused.
struct LCDRow<Label: View>: View {
    var highlighted: Bool
    var label: (_ inverted: Bool) -> Label
    @Environment(\.lcd) private var lcd

    init(highlighted: Bool, @ViewBuilder label: @escaping (_ inverted: Bool) -> Label) {
        self.highlighted = highlighted
        self.label = label
    }

    var body: some View {
        label(highlighted)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? lcd.ink : .clear)
            .contentShape(Rectangle())
    }
}

/// Inverted "chip" for a selected option, e.g. [60] or ON.
struct LCDChip: View {
    var text: String
    var on: Bool
    var inverted = false     // when drawn inside an already-inverted row
    var dot: CGFloat = 2
    @Environment(\.lcd) private var lcd

    var body: some View {
        let fg = on != inverted ? lcd.glass : lcd.ink
        PixelText(text, dot: dot, color: fg)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(on ? (inverted ? lcd.glass : lcd.ink) : .clear)
    }
}

/// Ten-segment volume bar, like the mockup's "▮▮▮▮▮▮▮▯▯▯ 70".
struct VolumeBar: View {
    @Binding var value: Double          // 0...1
    var inverted = false
    var cell: CGSize = CGSize(width: 12, height: 16)
    var onCommit: () -> Void = {}
    @Environment(\.lcd) private var lcd

    var body: some View {
        let ink = inverted ? lcd.glass : lcd.ink
        let filled = Int((value * 10).rounded())
        HStack(spacing: 3) {
            ForEach(0..<10, id: \.self) { i in
                Rectangle()
                    .fill(i < filled ? ink : .clear)
                    .overlay(Rectangle().strokeBorder(ink, lineWidth: 1.5))
                    .frame(width: cell.width, height: cell.height)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let total = 10 * cell.width + 9 * 3
                    let v = min(max(g.location.x / total, 0), 1)
                    let stepped = (v * 10).rounded() / 10   // the far-left half-cell reaches 0 (mute)
                    if stepped != value { value = stepped }
                }
                .onEnded { _ in onCommit() }
        )
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(value * 100)) percent")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: value = min(1, value + 0.1)
            case .decrement: value = max(0, value - 0.1)
            @unknown default: break
            }
            onCommit()
        }
    }
}
