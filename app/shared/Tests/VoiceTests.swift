// Voice: where a pause ends what was said and a spoken line as a list item. The simulator has
// no speech models, so speech turned into words is checked by make voice, on the Mac.
import CoreMedia
import Speech
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

    /// Words the model timed a gap apart come with a comma between them, and the gap is also
    /// measured from where the result before ended; words close together, as inside one
    /// name, stay as they came, and so do words without a time.
    func testAShortSilenceBetweenWordsPartsThem() {
        func timed(_ words: [(String, Double, Double)]) -> AttributedString {
            var out = AttributedString()
            for (i, (w, from, to)) in words.enumerated() {
                var a = AttributedString(i == 0 ? w : " " + w)
                a.audioTimeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 1000), end: CMTime(seconds: to, preferredTimescale: 1000))
                out += a
            }
            return out
        }
        let list = timed([("apples", 0.0, 0.5), ("oranges", 1.0, 1.6), ("bread", 1.7, 2.1)])
        let (text, end) = Listener.parted(list, gap: 0.35, after: nil)
        XCTAssertEqual(text, "apples, oranges bread")
        XCTAssertEqual(end?.seconds, 2.1)
        let next = timed([("milk", 2.6, 3.0)])
        XCTAssertEqual(Listener.parted(next, gap: 0.35, after: end).0, ", milk", "the gap before a new result counts too")
        XCTAssertEqual(Heard.join("apples, oranges bread", Listener.parted(next, gap: 0.35, after: end).0), "apples, oranges bread, milk")
        let close = timed([("olive", 0.0, 0.4), ("oil", 0.5, 0.8)])
        XCTAssertEqual(Listener.parted(close, gap: 0.35, after: nil).0, "olive oil")
        var punctuated = timed([("apples", 0.0, 0.5)])
        punctuated += AttributedString(",")
        punctuated += timed([("pears", 1.0, 1.4)])
        XCTAssertEqual(Listener.parted(punctuated, gap: 0.35, after: nil).0, "apples,pears", "no second comma after the model's own")
        XCTAssertEqual(Listener.parted(AttributedString("plain words"), gap: 0.35, after: nil).0, "plain words")
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
}
