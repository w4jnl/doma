// Voice: where a pause ends what was said, a spoken line as a list item, and speech in English,
// Dutch and Slovak turned into words by the model the device has for each, from sound macOS
// spoke (make voice writes it with say into app/macos/build/voice). The simulator has no speech
// models, so that part runs on the Mac, and only while the sound is there.
import XCTest
@testable import Doma

final class VoiceTests: XCTestCase {
    let t0 = Date(timeIntervalSinceReferenceDate: 0)

    func testAPauseEndsALineOnceTheWordsAreSettled() {
        var h = Heard()
        h.got("two litres", final: false, at: t0)
        XCTAssertNil(h.line(at: t0 + 3, pause: 1.5)) // still unsettled
        XCTAssertTrue(h.unsettled(at: t0 + 3, pause: 1.5))
        h.got("Two litres of milk", final: true, at: t0 + 3)
        h.got("and a", final: false, at: t0 + 3.2)
        XCTAssertNil(h.line(at: t0 + 3.4, pause: 1.5))
        h.got("and a loaf of bread.", final: true, at: t0 + 4)
        XCTAssertNil(h.line(at: t0 + 5, pause: 1.5)) // no pause yet
        XCTAssertEqual(h.line(at: t0 + 5.6, pause: 1.5), "Two litres of milk and a loaf of bread.")
        XCTAssertNil(h.line(at: t0 + 9, pause: 1.5)) // taken
    }

    func testAPauseIsDueOncePerUtteranceWithEveryPieceTaken() {
        var h = Heard()
        XCTAssertFalse(h.pauseDue(at: t0 + 9, pause: 1.5)) // nothing said
        h.got("milk", final: false, at: t0)
        XCTAssertFalse(h.pauseDue(at: t0 + 2, pause: 1.5)) // unsettled words wait
        h.got("Milk.", final: true, at: t0 + 2)
        XCTAssertFalse(h.pauseDue(at: t0 + 4, pause: 1.5)) // settled, not taken yet
        XCTAssertEqual(h.take(), "Milk.")
        XCTAssertFalse(h.pauseDue(at: t0 + 3, pause: 1.5)) // too soon
        XCTAssertTrue(h.pauseDue(at: t0 + 3.6, pause: 1.5))
        XCTAssertFalse(h.pauseDue(at: t0 + 9, pause: 1.5)) // once
        h.got("Eggs.", final: true, at: t0 + 10)
        _ = h.take()
        XCTAssertTrue(h.pauseDue(at: t0 + 12, pause: 1.5))
    }

    func testWordsJoinWithOneSpaceAndNoneBeforePunctuation() {
        XCTAssertEqual(Heard.join("", "  Hello  there "), "Hello there")
        XCTAssertEqual(Heard.join("Hello", "there"), "Hello there")
        XCTAssertEqual(Heard.join("Hello", ", there"), "Hello, there")
        XCTAssertEqual(Heard.join("Hello", ""), "Hello")
        var h = Heard()
        h.got("Five euro", final: true, at: t0)
        h.got("a month", final: false, at: t0)
        XCTAssertEqual(h.rest(), "Five euro a month")
        XCTAssertEqual(h, Heard())
    }

    func testASpokenLineIsAnItemWithoutItsFullStop() {
        XCTAssertEqual(Heard.item("Milk."), "Milk")
        XCTAssertEqual(Heard.item(" Two litres of milk! "), "Two litres of milk")
        XCTAssertEqual(Heard.item("Dr. Oetker"), "Dr. Oetker")
        XCTAssertEqual(Heard.item("..."), "")
    }

    func testEachLanguageIsAskedInALocaleOfItsOwn() {
        for l in Language.allCases {
            XCTAssertEqual(l.locales.last?.language.languageCode?.identifier, l.rawValue)
        }
    }

    /// The three languages through the Listener, on a Mac after make voice; skipped elsewhere.
    @MainActor
    func testSpeechBecomesWords() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("the simulator has no speech models: make voice")
        #else
        let dir = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "macos/build/voice")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dir.appending(path: "en.aiff").path), "make voice writes the sound")
        let cases: [(Language, [String])] = [
            (.english, ["milk", "bread"]),
            (.dutch, ["melk", "brood"]),
            (.slovak, ["mlieka", "chlieb"]),
        ]
        for (language, expected) in cases {
            let module = await Listener.module(language)
            try XCTSkipUnless(module != nil, "no model for \(language.name) on this Mac")
            let listener = Listener()
            var words: [String] = []
            listener.words = { words.append($0) }
            await listener.play(dir.appending(path: "\(language.rawValue).aiff"), language)
            if case .failed(let why) = listener.state { XCTFail("\(language.name): \(why)") }
            let text = words.joined(separator: " ").lowercased()
            for w in expected {
                XCTAssertTrue(text.contains(w), "\(language.name): \(text)")
            }
        }
        #endif
    }
}
