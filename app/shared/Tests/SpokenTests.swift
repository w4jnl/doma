// A spoken line into its items: the catalog's names first, longest first, then commas and the
// language's "and"; words before a known name stay with it; what nothing splits is one item.
import XCTest
@testable import Doma

final class SpokenTests: XCTestCase {
    let names = ["melk", "halfvolle melk", "eieren", "olive oil", "salt and pepper", "apples", "oranges", "chlieb", "mlieko"]

    func testSeparatorsSaidSplitUnknownItems() {
        XCTAssertEqual(Spoken.split("Peanut butter, jam and honey.", language: .english, names: names), ["Peanut butter", "jam", "honey"])
        XCTAssertEqual(Spoken.split("pindakaas en jam", language: .dutch, names: names), ["pindakaas", "jam"])
        XCTAssertEqual(Spoken.split("maslo a džem", language: .slovak, names: names), ["maslo", "džem"])
        XCTAssertEqual(Spoken.split("peanut butter en jam", language: .english, names: names), ["peanut butter en jam"], "another language's and is a word")
    }

    func testKnownNamesAreTornApartWithoutASeparator() {
        XCTAssertEqual(Spoken.split("apples oranges", language: .english, names: names), ["apples", "oranges"])
        XCTAssertEqual(Spoken.split("Halfvolle melk eieren", language: .dutch, names: names), ["Halfvolle melk", "eieren"], "the longest name wins")
        XCTAssertEqual(Spoken.split("olive oil", language: .english, names: names), ["olive oil"])
        XCTAssertEqual(Spoken.split("salt and pepper and apples", language: .english, names: names), ["salt and pepper", "apples"], "a known name keeps its and")
        XCTAssertEqual(Spoken.split("Mlieko chlieb", language: .slovak, names: names), ["Mlieko", "chlieb"])
    }

    func testWordsBeforeAKnownNameStayWithIt() {
        XCTAssertEqual(Spoken.split("2 kilos of apples and 3 oranges", language: .english, names: names), ["2 kilos of apples", "3 oranges"])
        XCTAssertEqual(Spoken.split("2 liter halfvolle melk", language: .dutch, names: names), ["2 liter halfvolle melk"])
    }

    func testWhatNothingSplitsIsOneItem() {
        XCTAssertEqual(Spoken.split("Sourdough bread.", language: .english, names: names), ["Sourdough bread"])
        XCTAssertEqual(Spoken.split("and", language: .english, names: names), [])
        XCTAssertEqual(Spoken.split(" , ", language: .english, names: names), [])
        XCTAssertEqual(Spoken.split("", language: .english, names: []), [])
    }

    func testNamesAreMatchedAsTheCatalogKeysThem() {
        XCTAssertEqual(Spoken.split("Éieren melk", language: .dutch, names: ["eieren", "melk"]), ["Éieren", "melk"], "accents and case fall away in the key, the words stay as said")
    }
}
