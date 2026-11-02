// doma's design system in code (docs/design-system/README.md): every colour in its dark and light
// value, the glyphs and the sizes, as tokens.json has them. Views never name a colour, a glyph or
// a size; they ask Tokens. TokensTests reads tokens.json by path and fails when the two drift.
import CoreText
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum Tokens {
    /// The colour tokens: name to (dark, light), in tokens.json's order. shadow-drawer is the
    /// web pages' only; the apps use the system's sheets.
    nonisolated static let colors: [String: (dark: UInt32, light: UInt32)] = [
        "ground": (0x1418_1A, 0xF6F8_F8),
        "surface": (0x1A20_23, 0xFFFF_FF),
        "surface-sunk": (0x0F12_14, 0xEEF2_F2),
        "line": (0x2630_34, 0xDCE3_E4),
        "line-strong": (0x6B7A_7D, 0x7E8D_90),
        "ink": (0xF2F5_F5, 0x1418_1A),
        "ink-muted": (0x8A99_9C, 0x5A68_6B),
        "ink-faint": (0x5E6D_70, 0x98A5_A7),
        "accent": (0x3FD0_D4, 0x0B7A_7E),
        "on-accent": (0x0B12_14, 0xFFFF_FF),
        "accent-soft": (0x1734_37, 0xE8F6_F6),
        "focus": (0x3FD0_D4, 0x0B7A_7E),
        "mark": (0x3FD0_D4, 0x1299_9D),
        "brand": (0x1299_9D, 0x1299_9D),
        "have": (0x5FC4_7A, 0x1F7A_3A),
        "have-soft": (0x1630_1F, 0xE3F3_E8),
        "low": (0xE896_3C, 0x9A5A_0E),
        "low-soft": (0x3324_0F, 0xFBEE_DC),
        "out": (0xF064_5A, 0xC034_2B),
        "out-soft": (0x3A1A_18, 0xFBE4_E2),
        "on-out": (0x1C0B_09, 0xFFFF_FF),
        "unknown": (0x8A99_9C, 0x5A68_6B),
        "list-1": (0x3FD0_D4, 0x0B7A_7E),
        "list-2": (0x5AA9_F0, 0x1F63_B5),
        "list-3": (0xA48B_F2, 0x5F3F_B8),
        "list-4": (0xE07B_C5, 0x9A2E_7E),
        "list-5": (0xE8D1_5A, 0x7A64_00),
        "list-6": (0x9DC2_6B, 0x4F7A_1A),
    ]

    static let ground = color("ground")
    static let surface = color("surface")
    static let surfaceSunk = color("surface-sunk")
    static let line = color("line")
    static let lineStrong = color("line-strong")
    static let ink = color("ink")
    static let inkMuted = color("ink-muted")
    static let inkFaint = color("ink-faint")
    static let accent = color("accent")
    static let onAccent = color("on-accent")
    static let accentSoft = color("accent-soft")
    static let mark = color("mark")
    static let have = color("have")
    static let haveSoft = color("have-soft")
    static let low = color("low")
    static let lowSoft = color("low-soft")
    static let out = color("out")
    static let outSoft = color("out-soft")
    static let onOut = color("on-out")
    static let unknown = color("unknown")

    /// The six list colours, in the order the picker shows them.
    static let listColours = ["list-1", "list-2", "list-3", "list-4", "list-5", "list-6"]

    /// A list's colour from the name its events carry; anything else, the default list's empty
    /// name included, is the accent.
    static func listColor(_ name: String) -> Color {
        listColours.contains(name) ? color(name) : accent
    }

    /// The sizes in points, from the px values of tokens.json. The font stacks and the tile
    /// radius are the web pages' only.
    nonisolated static let sizes: [String: CGFloat] = [
        "space-1": 4, "space-2": 8, "space-3": 12, "space-4": 16, "space-5": 24, "space-6": 32, "space-7": 48,
        "radius-xs": 3, "radius-sm": 6, "radius-md": 10,
        "row-h": 44, "row-h-list": 52, "control-h": 32, "chip-h": 28, "thumb": 72, "content-max": 720, "mark-min": 16,
    ]

    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space5: CGFloat = 24
    static let space6: CGFloat = 32
    static let space7: CGFloat = 48
    static let radiusXS: CGFloat = 3
    static let radiusSM: CGFloat = 6
    static let radiusMD: CGFloat = 10
    static let rowH: CGFloat = 44
    /// Shop mode raises a row to 56pt (tokens.json, row-h's note).
    static let rowHList: CGFloat = 52
    static let controlH: CGFloat = 32
    static let chipH: CGFloat = 28
    static let thumb: CGFloat = 72
    static let contentMax: CGFloat = 720
    static let markMin: CGFloat = 16

    /// The glyphs, as tokens.json has them: every flag and list state is a glyph and a word,
    /// never colour alone.
    nonisolated static let glyphs: [String: String] = [
        "have": "●", "low": "◐", "out": "◆", "unknown": "◌", "open": "○", "done": "✓",
        "mark": "[⌂]", "mark-narrow": "⌈⌂⌉",
    ]

    enum Glyph {
        static let have = "●"
        static let low = "◐"
        static let out = "◆"
        static let unknown = "◌"
        static let open = "○"
        static let done = "✓"
        static let mark = "[⌂]"
        static let markNarrow = "⌈⌂⌉"
    }

    /// A colour that follows the system appearance: dark is the brand's home, light is complete.
    static func color(_ name: String) -> Color {
        #if os(macOS)
        Color(nsColor: nsColor(name))
        #else
        Color(uiColor: uiColor(name))
        #endif
    }

    #if os(macOS)
    static func nsColor(_ name: String) -> NSColor {
        let t = colors[name] ?? (0xFF00_FF, 0xFF00_FF)
        return NSColor(name: NSColor.Name("doma." + name)) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: dark ? t.dark : t.light)
        }
    }
    #else
    static func uiColor(_ name: String) -> UIColor {
        let t = colors[name] ?? (0xFF00_FF, 0xFF00_FF)
        return UIColor { traits in UIColor(hex: traits.userInterfaceStyle == .dark ? t.dark : t.light) }
    }
    #endif

    /// JetBrains Mono, bundled from docs/design-system/fonts, for what a person reads as data:
    /// quantities and units after an item, times and ages, the code under a QR. It follows
    /// Dynamic Type through the text style it is relative to. UI words are never mono. The
    /// system's monospaced face stands in when the bundled one is missing.
    static func mono(_ style: Font.TextStyle = .body, bold: Bool = false) -> Font {
        _ = fontsRegistered
        let name = bold ? "JetBrainsMono-Bold" : "JetBrainsMono-Regular"
        if hasFont(name) {
            return .custom(name, size: baseSize(style), relativeTo: style).monospacedDigit()
        }
        return .system(style, design: .monospaced).weight(bold ? .bold : .regular).monospacedDigit()
    }

    /// JetBrains Mono at a fixed size, for the places that do not scale (the mark's lockup).
    static func mono(fixed size: CGFloat, bold: Bool = false) -> Font {
        _ = fontsRegistered
        let name = bold ? "JetBrainsMono-Bold" : "JetBrainsMono-Regular"
        if hasFont(name) {
            return .custom(name, fixedSize: size).monospacedDigit()
        }
        return .system(size: size, weight: bold ? .bold : .regular, design: .monospaced).monospacedDigit()
    }

    private static func hasFont(_ name: String) -> Bool {
        #if os(macOS)
        NSFont(name: name, size: 12) != nil
        #else
        UIFont(name: name, size: 12) != nil
        #endif
    }

    /// The default point size of a text style at the large (default) Dynamic Type size.
    private static func baseSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline: 17
        case .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        case .caption2: 11
        @unknown default: 17
        }
    }

    private static let fontsRegistered: Bool = {
        for weight in ["400", "700"] {
            if let url = Bundle.main.url(forResource: "JetBrainsMono-" + weight, withExtension: "woff2", subdirectory: "fonts") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
        return true
    }()
}

#if os(macOS)
extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#else
extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
#endif
