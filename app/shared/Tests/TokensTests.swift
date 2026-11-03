// The design tokens against their source of truth: docs/design-system/tokens.json, read by path
// from this file's place in the repository, so a change there fails here until Tokens.swift
// follows. Both apps run these.
import XCTest
@testable import Doma

final class TokensTests: XCTestCase {
    /// The repository root: app/shared/Tests/TokensTests.swift is three levels under it.
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func tokens() throws -> [String: Any] {
        let url = Self.root.appendingPathComponent("docs/design-system/tokens.json")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testColoursMatch() throws {
        let color = try XCTUnwrap(tokens()["color"] as? [String: Any])
        let list = try XCTUnwrap(color["tokens"] as? [[String: Any]])
        var seen = Set<String>()
        for t in list {
            let name = try XCTUnwrap(t["name"] as? String)
            let value = try XCTUnwrap(t["value"] as? [String: String])
            let dark = try XCTUnwrap(value["dark"]), light = try XCTUnwrap(value["light"])
            guard dark.hasPrefix("#") else { continue } // shadow-drawer: the web pages' only
            seen.insert(name)
            let have = try XCTUnwrap(Tokens.colors[name], "Tokens.colors lacks \(name)")
            XCTAssertEqual(have.dark, hex(dark), "\(name) dark")
            XCTAssertEqual(have.light, hex(light), "\(name) light")
        }
        XCTAssertEqual(Set(Tokens.colors.keys), seen, "Tokens.colors has names tokens.json does not")
    }

    func testSizesMatch() throws {
        let size = try XCTUnwrap(tokens()["size"] as? [String: Any])
        let list = try XCTUnwrap(size["tokens"] as? [[String: Any]])
        var seen = Set<String>()
        for t in list {
            let name = try XCTUnwrap(t["name"] as? String)
            let value = try XCTUnwrap(t["value"] as? String)
            guard value.hasSuffix("px"), let px = Double(value.dropLast(2)) else { continue }
            seen.insert(name)
            XCTAssertEqual(Tokens.sizes[name], CGFloat(px), name)
        }
        XCTAssertEqual(Set(Tokens.sizes.keys), seen)
    }

    func testMotionMatches() throws {
        let motion = try XCTUnwrap(tokens()["motion"] as? [String: Any])
        let list = try XCTUnwrap(motion["tokens"] as? [[String: Any]])
        var seen = Set<String>()
        for t in list {
            let name = try XCTUnwrap(t["name"] as? String)
            let value = try XCTUnwrap(t["value"] as? String)
            guard value.hasSuffix("ms"), let ms = Double(value.dropLast(2)) else { continue }
            seen.insert(name)
            XCTAssertEqual(Tokens.motions[name], ms, name)
        }
        XCTAssertEqual(Set(Tokens.motions.keys), seen)
        XCTAssertEqual(Tokens.motionQuick * 1000, Tokens.motions["motion-quick"])
        XCTAssertEqual(Tokens.motionBase * 1000, Tokens.motions["motion-base"])
        XCTAssertEqual(Tokens.motionSettle * 1000, Tokens.motions["motion-settle"])
    }

    func testGlyphsMatch() throws {
        let glyph = try XCTUnwrap(tokens()["glyph"] as? [String: Any])
        let list = try XCTUnwrap(glyph["tokens"] as? [[String: Any]])
        var seen = Set<String>()
        for t in list {
            let name = try XCTUnwrap(t["name"] as? String)
            seen.insert(name)
            XCTAssertEqual(Tokens.glyphs[name], t["value"] as? String, name)
        }
        XCTAssertEqual(Set(Tokens.glyphs.keys), seen)
    }

    /// The Mac's sidebar selection and focus ring take the accent from the asset catalogue, not
    /// from .tint, so each app ships an AccentColor set that must stay the accent token.
    func testAccentAssetMatchesTheToken() throws {
        try assetMatches("ios", "AccentColor", token: "accent")
        try assetMatches("macos", "AccentColor", token: "accent")
        // the phone's launch colour is the ground
        try assetMatches("ios", "LaunchBackground", token: "ground")
    }

    private func assetMatches(_ platform: String, _ set: String, token: String) throws {
        let accent = try XCTUnwrap(Tokens.colors[token])
        do {
            let url = Self.root.appendingPathComponent("app/\(platform)/Doma/Assets.xcassets/\(set).colorset/Contents.json")
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let colors = try XCTUnwrap(json["colors"] as? [[String: Any]])
            XCTAssertEqual(colors.count, 2, platform)
            for c in colors {
                let dark = (c["appearances"] as? [[String: Any]])?.contains { $0["value"] as? String == "dark" } ?? false
                let comps = try XCTUnwrap((c["color"] as? [String: Any])?["components"] as? [String: String])
                var value: UInt32 = 0
                for key in ["red", "green", "blue"] {
                    let hex = try XCTUnwrap(comps[key]).dropFirst(2)
                    value = value << 8 | UInt32(try XCTUnwrap(UInt8(hex, radix: 16)))
                }
                XCTAssertEqual(value, dark ? accent.dark : accent.light, "\(platform) \(set) \(dark ? "dark" : "light")")
            }
        }
    }

    func testNamedConstantsMatchTheTable() {
        XCTAssertEqual(Tokens.space1, Tokens.sizes["space-1"])
        XCTAssertEqual(Tokens.space7, Tokens.sizes["space-7"])
        XCTAssertEqual(Tokens.radiusMD, Tokens.sizes["radius-md"])
        XCTAssertEqual(Tokens.rowH, Tokens.sizes["row-h"])
        XCTAssertEqual(Tokens.rowHList, Tokens.sizes["row-h-list"])
        XCTAssertEqual(Tokens.rowHCompact, Tokens.sizes["row-h-compact"])
        XCTAssertEqual(Tokens.thumb, Tokens.sizes["thumb"])
        XCTAssertEqual(Tokens.Glyph.out, Tokens.glyphs["out"])
        XCTAssertEqual(Tokens.Glyph.done, Tokens.glyphs["done"])
    }

    func testCustomSymbolsAreInTheBundle() {
        for s in Symbol.allCases {
            #if canImport(UIKit)
            XCTAssertNotNil(UIImage(named: s.name), s.name)
            #else
            XCTAssertNotNil(NSImage(named: s.name), s.name)
            #endif
        }
    }

    func testFontsAreInTheBundle() {
        for weight in ["400", "700"] {
            XCTAssertNotNil(Bundle.main.url(forResource: "JetBrainsMono-" + weight, withExtension: "woff2", subdirectory: "fonts"), weight)
        }
    }

    private func hex(_ s: String) -> UInt32 {
        UInt32(s.dropFirst(), radix: 16) ?? 0
    }
}
