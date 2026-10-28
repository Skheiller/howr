import SwiftUI

// MARK: - Palette

/// Two looks of the same reflective LCD: daylight (light mode) and the blue-green
/// electroluminescent backlight (dark mode).
struct LCDPalette {
    var glass: Color        // LCD background
    var glassEdge: Color    // inner shadow at the glass edge
    var ink: Color          // lit segments
    var ghost: Color        // unlit segments, faintly visible
    var bezel: Color        // resin case
    var bezelText: Color    // printed labels on the case
    var accent: Color       // the case's colored stripe

    static let daylight = LCDPalette(
        glass: Color(red: 0.69, green: 0.73, blue: 0.62),
        glassEdge: Color(red: 0.52, green: 0.56, blue: 0.47),
        ink: Color(red: 0.10, green: 0.12, blue: 0.10),
        ghost: Color(red: 0.10, green: 0.12, blue: 0.10).opacity(0.05),
        bezel: Color(red: 0.10, green: 0.10, blue: 0.11),
        bezelText: Color(white: 0.78),
        accent: Color(red: 0.86, green: 0.30, blue: 0.22)
    )

    static let backlight = LCDPalette(
        glass: Color(red: 0.36, green: 0.80, blue: 0.82),
        glassEdge: Color(red: 0.17, green: 0.52, blue: 0.58),
        ink: Color(red: 0.03, green: 0.12, blue: 0.16),
        ghost: Color(red: 0.03, green: 0.12, blue: 0.16).opacity(0.09),
        bezel: Color(red: 0.06, green: 0.06, blue: 0.07),
        bezelText: Color(white: 0.70),
        accent: Color(red: 0.86, green: 0.30, blue: 0.22)
    )
}

private struct LCDPaletteKey: EnvironmentKey { static let defaultValue = LCDPalette.daylight }
extension EnvironmentValues {
    var lcd: LCDPalette {
        get { self[LCDPaletteKey.self] }
        set { self[LCDPaletteKey.self] = newValue }
    }
}

/// Picks daylight or backlight from the system appearance, unless the LIGHT button forced one.
struct LCDThemed<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var settings: Settings
    @ViewBuilder var content: Content

    var body: some View {
        let night = settings.lcdTheme == "night" || (settings.lcdTheme == "auto" && scheme == .dark)
        content.environment(\.lcd, night ? .backlight : .daylight)
    }
}

// MARK: - Seven-segment digits

/// Classic seven-segment glyphs, drawn as hexagonal bars with unlit ghost segments behind them.
struct SevenSegment: View {
    var text: String          // digits, " ", "-", ":" are supported
    var digitHeight: CGFloat = 40
    var colonLit = true
    @Environment(\.lcd) private var lcd

    private static let map: [Character: UInt8] = [
        // bits: a b c d e f g  (a = top, then clockwise, g = middle)
        "0": 0b1111110, "1": 0b0110000, "2": 0b1101101, "3": 0b1111001, "4": 0b0110011,
        "5": 0b1011011, "6": 0b1011111, "7": 0b1110000, "8": 0b1111111, "9": 0b1111011,
        "-": 0b0000001, " ": 0,
    ]

    var body: some View {
        let w = digitHeight * 0.56
        HStack(spacing: digitHeight * 0.12) {
            ForEach(Array(text.enumerated()), id: \.offset) { _, ch in
                if ch == ":" {
                    Colon(height: digitHeight, lit: colonLit).frame(width: digitHeight * 0.16, height: digitHeight)
                } else {
                    Digit(mask: Self.map[ch] ?? 0, ink: lcd.ink, ghost: lcd.ghost)
                        .frame(width: w, height: digitHeight)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(text.trimmingCharacters(in: .whitespaces))
    }

    private struct Colon: View {
        var height: CGFloat
        var lit: Bool
        @Environment(\.lcd) private var lcd
        var body: some View {
            VStack(spacing: height * 0.26) {
                Rectangle().frame(width: height * 0.1, height: height * 0.1)
                Rectangle().frame(width: height * 0.1, height: height * 0.1)
            }
            .foregroundStyle(lit ? lcd.ink : lcd.ghost)
        }
    }

    private struct Digit: View {
        var mask: UInt8
        var ink: Color
        var ghost: Color

        var body: some View {
            Canvas { ctx, size in
                let t = size.height * 0.1          // bar thickness
                let slant = size.height * 0.06      // italic lean like a watch display
                for i in 0..<7 {
                    let lit = mask & (1 << (6 - i)) != 0
                    var path = Self.segment(i, in: size, t: t)
                    path = path.applying(CGAffineTransform(a: 1, b: 0, c: -slant / size.height, d: 1, tx: slant * 0.6, ty: 0))
                    ctx.fill(path, with: .color(lit ? ink : ghost))
                }
            }
        }

        static func segment(_ i: Int, in s: CGSize, t: CGFloat) -> Path {
            let w = s.width, h = s.height, g = t * 0.18, half = t / 2
            func horizontal(_ y: CGFloat) -> Path {
                Path { p in
                    p.move(to: CGPoint(x: half + g, y: y))
                    p.addLine(to: CGPoint(x: t + g, y: y - half))
                    p.addLine(to: CGPoint(x: w - t - g, y: y - half))
                    p.addLine(to: CGPoint(x: w - half - g, y: y))
                    p.addLine(to: CGPoint(x: w - t - g, y: y + half))
                    p.addLine(to: CGPoint(x: t + g, y: y + half))
                    p.closeSubpath()
                }
            }
            func vertical(_ x: CGFloat, _ y0: CGFloat, _ y1: CGFloat) -> Path {
                Path { p in
                    p.move(to: CGPoint(x: x, y: y0 + g))
                    p.addLine(to: CGPoint(x: x + half, y: y0 + half + g))
                    p.addLine(to: CGPoint(x: x + half, y: y1 - half - g))
                    p.addLine(to: CGPoint(x: x, y: y1 - g))
                    p.addLine(to: CGPoint(x: x - half, y: y1 - half - g))
                    p.addLine(to: CGPoint(x: x - half, y: y0 + half + g))
                    p.closeSubpath()
                }
            }
            let top = half, mid = h / 2, bottom = h - half
            switch i {
            case 0: return horizontal(top)
            case 1: return vertical(w - half, top, mid)
            case 2: return vertical(w - half, mid, bottom)
            case 3: return horizontal(bottom)
            case 4: return vertical(half, mid, bottom)
            case 5: return vertical(half, top, mid)
            default: return horizontal(mid)
            }
        }
    }
}

// MARK: - 5×7 dot-matrix text

/// Upper-case dot-matrix text, the way small watch LCDs render words.
/// Drawn in a single Canvas pass; VoiceOver reads the plain string.
struct PixelText: View {
    var text: String
    var dot: CGFloat = 2
    var ghost = false
    var color: Color?
    @Environment(\.lcd) private var lcd

    var label: String?

    /// `label` is what VoiceOver reads; by default the text itself (never re-cased, so "AM" stays "AM").
    init(_ text: String, dot: CGFloat = 2, ghost: Bool = false, color: Color? = nil, label: String? = nil) {
        self.label = label
        self.text = text.uppercased()
        self.dot = dot
        self.ghost = ghost
        self.color = color
    }

    private var glyphs: [[UInt8]] { text.map { PixelFont.glyph($0) } }
    private var width: CGFloat {
        let cols = glyphs.reduce(0) { $0 + ($1.isEmpty ? 3 : PixelFont.width($1) + 1) }
        return CGFloat(max(cols - 1, 0)) * dot
    }

    var body: some View {
        let ink = color ?? lcd.ink
        let ghostColor = lcd.ghost
        let glyphs = glyphs
        let dot = dot
        Canvas { ctx, _ in
            var x: CGFloat = 0
            for g in glyphs {
                if g.isEmpty { x += 3 * dot; continue }
                let w = PixelFont.width(g)
                for (row, bits) in g.enumerated() {
                    for col in 0..<w {
                        let on = bits & (1 << (4 - col)) != 0
                        guard on || ghost else { continue }
                        let r = CGRect(x: x + CGFloat(col) * dot, y: CGFloat(row) * dot, width: dot * 0.86, height: dot * 0.86)
                        ctx.fill(Path(r), with: .color(on ? ink : ghostColor))
                    }
                }
                x += CGFloat(w + 1) * dot
            }
        }
        .frame(width: width, height: 7 * dot)
        .accessibilityElement()
        .accessibilityLabel(label ?? text)
    }
}

/// The F-91W "alarm on" indicator: a bell with sound waves. Waves vanish when chimes are off.
struct BellIcon: View {
    var on: Bool
    var dot: CGFloat = 2.6
    @Environment(\.lcd) private var lcd

    private static let bell = [
        "......#......",
        ".....###.....",
        "....#####....",
        "....#####....",
        "....#####....",
        "...#######...",
        "...#######...",
        "......#......",
    ]
    private static let waves = [
        ".............",
        ".#.........#.",
        "#...........#",
        "#...........#",
        "#...........#",
        ".#.........#.",
        ".............",
        ".............",
    ]

    var body: some View {
        let ink = lcd.ink, ghost = lcd.ghost, dot = dot, on = on
        Canvas { ctx, _ in
            for (y, (b, w)) in zip(Self.bell, Self.waves).enumerated() {
                for (x, (bc, wc)) in zip(b, w).enumerated() {
                    let r = CGRect(x: CGFloat(x) * dot, y: CGFloat(y) * dot, width: dot * 0.86, height: dot * 0.86)
                    if bc == "#" { ctx.fill(Path(r), with: .color(on ? ink : ink.opacity(0.35))) }
                    else if wc == "#" { ctx.fill(Path(r), with: .color(on ? ink : ghost)) }
                }
            }
        }
        .frame(width: 13 * dot, height: 8 * dot)
        .accessibilityElement()
        .accessibilityLabel(on ? "Chimes on" : "Chimes off")
    }
}

enum PixelFont {
    /// Width of a glyph: narrow glyphs (":", ".", "1", "I") use fewer columns.
    static func width(_ g: [UInt8]) -> Int {
        let used = g.reduce(UInt8(0), |)
        if used == 0 { return 1 }
        var lo = 0, hi = 4
        while lo < 5 && used & (1 << (4 - lo)) == 0 { lo += 1 }
        while hi > 0 && used & (1 << (4 - hi)) == 0 { hi -= 1 }
        // Only trim glyphs that are left-aligned in the cell (narrow punctuation).
        return lo == 0 ? hi + 1 : 5
    }

    static func glyph(_ c: Character) -> [UInt8] {
        if let g = table[c] { return g }
        return c == " " ? [] : table["?"]!
    }

    private static func g(_ rows: String...) -> [UInt8] {
        rows.map { row in row.reduce(UInt8(0)) { ($0 << 1) | ($1 == "#" ? 1 : 0) } }
    }

    static let table: [Character: [UInt8]] = [
        "A": g(".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"),
        "B": g("####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."),
        "C": g(".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."),
        "D": g("####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####."),
        "E": g("#####", "#....", "#....", "####.", "#....", "#....", "#####"),
        "F": g("#####", "#....", "#....", "####.", "#....", "#....", "#...."),
        "G": g(".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".####"),
        "H": g("#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"),
        "I": g("###..", ".#...", ".#...", ".#...", ".#...", ".#...", "###.."),
        "J": g("..###", "...#.", "...#.", "...#.", "...#.", "#..#.", ".##.."),
        "K": g("#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"),
        "L": g("#....", "#....", "#....", "#....", "#....", "#....", "#####"),
        "M": g("#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"),
        "N": g("#...#", "#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#"),
        "O": g(".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."),
        "P": g("####.", "#...#", "#...#", "####.", "#....", "#....", "#...."),
        "Q": g(".###.", "#...#", "#...#", "#...#", "#.#.#", "#..#.", ".##.#"),
        "R": g("####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"),
        "S": g(".####", "#....", "#....", ".###.", "....#", "....#", "####."),
        "T": g("#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."),
        "U": g("#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."),
        "V": g("#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#.."),
        "W": g("#...#", "#...#", "#...#", "#.#.#", "#.#.#", "##.##", "#...#"),
        "X": g("#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"),
        "Y": g("#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.."),
        "Z": g("#####", "....#", "...#.", "..#..", ".#...", "#....", "#####"),
        "0": g(".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."),
        "1": g(".#...", "##...", ".#...", ".#...", ".#...", ".#...", "###.."),
        "2": g(".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"),
        "3": g("#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###."),
        "4": g("...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."),
        "5": g("#####", "#....", "####.", "....#", "....#", "#...#", ".###."),
        "6": g("..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."),
        "7": g("#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."),
        "8": g(".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."),
        "9": g(".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."),
        ":": g(".", "#", "#", ".", "#", "#", ".").map { $0 << 4 },
        ".": g(".", ".", ".", ".", ".", "#", "#").map { $0 << 4 },
        ",": g(".", ".", ".", ".", ".", "#", "#").map { $0 << 4 },
        "'": g("#", "#", ".", ".", ".", ".", ".").map { $0 << 4 },
        "-": g(".....", ".....", ".....", "####.", ".....", ".....", "....."),
        "+": g(".....", "..#..", "..#..", "#####", "..#..", "..#..", "....."),
        "/": g("....#", "....#", "...#.", "..#..", ".#...", "#....", "#...."),
        "%": g("##...", "##..#", "...#.", "..#..", ".#...", "#..##", "...##"),
        "?": g(".###.", "#...#", "....#", "...#.", "..#..", ".....", "..#.."),
        "!": g("#", "#", "#", "#", "#", ".", "#").map { $0 << 4 },
        "▶": g("#....", "##...", "###..", "####.", "###..", "##...", "#...."),
        "◀": g("...#.", "..##.", ".###.", "####.", ".###.", "..##.", "...#."),
        "▮": g("####.", "####.", "####.", "####.", "####.", "####.", "####."),
        "▯": g("####.", "#..#.", "#..#.", "#..#.", "#..#.", "#..#.", "####."),
        "♪": g("..#..", ".###.", ".###.", ".###.", "#####", ".....", "..#.."),  // bell
        "⚙": g("..#..", "#.#.#", ".###.", "##.##", ".###.", "#.#.#", "..#.."),
        "⏻": g("..#..", "#.#.#", "#.#.#", "#...#", "#...#", ".###.", "....."),
        ">": g("#...", ".#..", "..#.", "...#", "..#.", ".#..", "#...").map { $0 << 1 },
        "×": g(".....", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "....."),
        "·": g(".", ".", ".", "#", ".", ".", ".").map { $0 << 4 },
        "~": g(".....", ".....", ".#..#", "#.#.#", "#..#.", ".....", "....."),
        "(": g(".#", "#.", "#.", "#.", "#.", "#.", ".#").map { $0 << 3 },
        ")": g("#.", ".#", ".#", ".#", ".#", ".#", "#.").map { $0 << 3 },
        "[": g("##", "#.", "#.", "#.", "#.", "#.", "##").map { $0 << 3 },
        "]": g("##", ".#", ".#", ".#", ".#", ".#", "##").map { $0 << 3 },
    ]
}
