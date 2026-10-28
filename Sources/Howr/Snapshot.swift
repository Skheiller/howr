import AppKit
import SwiftUI

/// `Howr --snapshot <dir>` renders every surface in both palettes to PNGs and exits.
/// `Howr --render-icon <dir.iconset>` writes the app icon at all iconset sizes.
/// Used by the build script and for design review without screen-recording access.
enum Snapshot {
    @MainActor
    static func run(_ args: [String]) -> Bool {
        if let i = args.firstIndex(of: "--snapshot"), args.count > i + 1 {
            renderUI(to: URL(fileURLWithPath: args[i + 1]))
            return true
        }
        if let i = args.firstIndex(of: "--render-icon"), args.count > i + 1 {
            renderIcon(to: URL(fileURLWithPath: args[i + 1]))
            return true
        }
        return false
    }

    @MainActor
    private static func renderUI(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suite = "app.howr.snapshot"
        UserDefaults().removePersistentDomain(forName: suite)
        let settings = Settings(defaults: UserDefaults(suiteName: suite)!)
        settings.activeHoursEnabled = true
        let player = PreviewClient(settings: settings) { _, _ in }
        let scheduler = ChimeStatus(settings: settings)

        for (name, scheme) in [("day", ColorScheme.light), ("night", .dark)] {
            settings.lcdTheme = name
            write(LCDThemed { PopoverView(player: player, openSettings: {}, close: {}, quit: {}) }
                .environmentObject(settings).environmentObject(scheduler).environment(\.colorScheme, scheme),
                  to: dir.appendingPathComponent("popover-\(name).png"))
            write(LCDThemed { SettingsView(player: player, close: {}, loginItem: LoginItem { _ in }) }
                .environmentObject(settings).environment(\.colorScheme, scheme),
                  to: dir.appendingPathComponent("settings-\(name).png"))
        }
        settings.pausedUntil = Date().addingTimeInterval(5400)
        settings.lcdTheme = "day"
        write(LCDThemed { PopoverView(player: player, openSettings: {}, close: {}, quit: {}) }
            .environmentObject(settings).environmentObject(scheduler),
              to: dir.appendingPathComponent("popover-paused.png"))
        UserDefaults().removePersistentDomain(forName: suite)
        print("Wrote snapshots to \(dir.path)")
    }

    @MainActor
    private static func write<V: View>(_ view: V, to url: URL, scale: CGFloat = 2) {
        let r = ImageRenderer(content: view.padding(24))
        r.scale = scale
        guard let cg = r.cgImage else { print("render failed: \(url.lastPathComponent)"); return }
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    @MainActor
    private static func renderIcon(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let suffix = scale == 2 ? "@2x" : ""
                let r = ImageRenderer(content: AppIcon().frame(width: CGFloat(base), height: CGFloat(base)))
                r.scale = CGFloat(scale)
                guard let cg = r.cgImage else { continue }
                let url = dir.appendingPathComponent("icon_\(base)x\(base)\(suffix).png")
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: url)
            }
        }
    }
}

/// App icon: the watch case with a daylight LCD showing the hour.
struct AppIcon: View {
    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width
            let lcd = LCDPalette.daylight
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.225, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.22), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: s * 0.19, style: .continuous)
                    .strokeBorder(Color(red: 0.2, green: 0.38, blue: 0.85), lineWidth: max(1, s * 0.018))
                    .padding(s * 0.05)
                VStack(spacing: s * 0.04) {
                    ZStack {
                        RoundedRectangle(cornerRadius: s * 0.07, style: .continuous).fill(lcd.glass)
                        VStack(spacing: s * 0.03) {
                            HStack {
                                Spacer()
                                PixelText("♪", dot: max(0.5, s * 0.022))
                            }
                            SevenSegment(text: "12", digitHeight: s * 0.32)
                            PixelText(":00", dot: max(0.5, s * 0.02))
                        }
                        .padding(s * 0.06)
                    }
                    .frame(width: s * 0.72, height: s * 0.62)
                    Capsule().fill(lcd.accent).frame(width: s * 0.14, height: max(1, s * 0.025))
                }
            }
            .environment(\.lcd, lcd)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
