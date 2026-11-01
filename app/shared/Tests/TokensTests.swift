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

    func testNamedConstantsMatchTheTable() {
        XCTAssertEqual(Tokens.space1, Tokens.sizes["space-1"])
        XCTAssertEqual(Tokens.space7, Tokens.sizes["space-7"])
        XCTAssertEqual(Tokens.radiusMD, Tokens.sizes["radius-md"])
        XCTAssertEqual(Tokens.rowH, Tokens.sizes["row-h"])
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
