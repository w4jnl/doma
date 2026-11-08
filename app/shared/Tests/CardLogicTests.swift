// The cards as the screens read and write them: add, edit, share with the family, remove; the
// colour in turn, the initials on a tile, and the shop table's suggestions.
import XCTest
@testable import Doma

@MainActor
final class CardLogicTests: XCTestCase {
    func session() throws -> Session {
        let store = try DomaStore.inMemory()
        try store.saveContext(ServerContext(serverID: "S1", baseURL: URL(string: "https://doma.example")!, credentialID: "C1", personID: "pa", displayName: "Jaro", createdAt: 1))
        try store.upsertHousehold(HouseholdRow(serverID: "S1", id: "H1", name: "De Vries", timezone: "Europe/Amsterdam", stalenessDays: nil, role: "owner"))
        return Session(store: store)
    }

    func cards(_ s: Session) throws -> [CardRow] {
        try s.store.read(s.scope!) { db, sc in try Queries.cards(db, sc) }
    }

    func testAddEditShareAndRemove() throws {
        let s = try session()
        let scope = try XCTUnwrap(s.scope)
        XCTAssertEqual(try cards(s), [])
        let ah = try XCTUnwrap(CardActions.add(name: " Albert Heijn ", format: "ean13", value: "2620 0000 00008", domain: "https://www.ah.nl/bonus", personal: false, colour: "list-1", in: s))
        let bieb = try XCTUnwrap(CardActions.add(name: "Bieb", format: "code128", value: "LIB-42", domain: nil, personal: true, colour: "list-2", in: s))
        var all = try cards(s)
        XCTAssertEqual(all.map(\.name), ["Albert Heijn", "Bieb"], "by name")
        XCTAssertEqual(all[0].value, "2620000000008", "spaces a person typed are gone")
        XCTAssertEqual(all[0].domain, "ah.nl", "the website is its domain")
        XCTAssertFalse(all[0].isPersonal)
        XCTAssertTrue(all[1].isPersonal)
        XCTAssertEqual(try s.store.read(scope) { db, sc in try Queries.cardCount(db, sc) }, 2)
        XCTAssertNil(try CardActions.add(name: "", format: "ean13", value: "1", domain: nil, personal: false, colour: "", in: s), "a card needs a name")
        XCTAssertNil(try CardActions.add(name: "x", format: "nope", value: "1", domain: nil, personal: false, colour: "", in: s), "and a format the schema knows")

        try CardActions.edit(all[1], name: "Bibliotheek", format: "code39", value: "LIB-43", domain: "bibliotheek.nl", in: s)
        let edited = try XCTUnwrap(try s.store.read(scope) { db, sc in try Queries.card(db, sc, id: bieb) })
        XCTAssertEqual([edited.name, edited.format, edited.value, edited.domain ?? "", edited.colour], ["Bibliotheek", "code39", "LIB-43", "bibliotheek.nl", "list-2"])
        XCTAssertTrue(edited.isPersonal, "an edit keeps the owner")

        let shared = try XCTUnwrap(CardActions.share(edited, in: s))
        all = try cards(s)
        XCTAssertEqual(all.map(\.id), [ah, shared], "the personal card is archived, the household one takes its place")
        XCTAssertFalse(all[1].isPersonal)
        XCTAssertEqual(all[1].value, "LIB-43")
        XCTAssertNil(try CardActions.share(all[1], in: s), "a household card is shared already")

        try CardActions.archive(all[0], in: s)
        XCTAssertEqual(try cards(s).map(\.id), [shared])
        XCTAssertNotNil(try s.store.read(scope) { db, sc in try Queries.card(db, sc, id: ah) }, "an archived card still reads by id; the screens list without it")
    }

    func testColoursInitialsAndOrder() throws {
        let s = try session()
        XCTAssertEqual(CardActions.nextColour([]), "list-1")
        let rows = (1...6).map { CardRow(id: "C\($0)", name: "S\($0)", colour: "list-\($0)", format: "qr", value: "x") }
        XCTAssertEqual(CardActions.nextColour(Array(rows.prefix(2))), "list-3")
        XCTAssertEqual(CardActions.nextColour(rows), "list-1", "with all six taken, around again")
        XCTAssertEqual(CardRow(id: "x", name: "Albert Heijn", format: "qr", value: "1").initials, "AH")
        XCTAssertEqual(CardRow(id: "x", name: "dm", format: "qr", value: "1").initials, "D")
        XCTAssertEqual(CardRow(id: "x", name: "Coop", format: "qr", value: "1").initials, "C")
        XCTAssertEqual(CardRow(id: "x", name: "Kaufland-Card", format: "qr", value: "1").initials, "KC")
        // under a test nothing is remembered, so the order is by name
        XCTAssertEqual(CardsShown.ordered([rows[2], rows[0]], session: s).map(\.id), ["C1", "C3"])
    }

    func testTheShopTableSuggestsTheRegionFirst() {
        let table = [
            Shop(name: "Albert Heijn", domains: ["ah.nl", "ah.be"], countries: ["be", "nl"]),
            Shop(name: "Albert", domains: ["albert.cz"], countries: ["cz"]),
            Shop(name: "Aldi", domains: ["aldi.nl"], countries: ["nl"]),
            Shop(name: "IKEA", domains: ["ikea.com"], countries: ["eu"]),
            Shop(name: "Tesco", domains: ["tescoplc.com", "itesco.sk", "tesco.sk", "tesco.ie"], countries: ["eu"]),
            Shop(name: "Hornbach Baumarkt", domains: ["hornbach.de"], countries: ["de", "nl"]),
        ]
        XCTAssertEqual(table[4].domain(for: "SK"), "tesco.sk", "the shortest domain of the country")
        XCTAssertEqual(table[4].domain(for: "IE"), "tesco.ie")
        XCTAssertEqual(table[4].domain(for: "NL"), "tescoplc.com", "no Dutch site: the main one")
        XCTAssertEqual(table[0].domain(for: "BE"), "ah.be")
        XCTAssertEqual(table[0].domain(for: nil), "ah.nl")
        XCTAssertEqual(Shops.suggest("al", region: "NL", in: table).map(\.name), ["Albert Heijn", "Aldi", "Albert"], "the Dutch ones first, then the rest")
        XCTAssertEqual(Shops.suggest("al", region: "CZ", in: table).map(\.name), ["Albert", "Albert Heijn", "Aldi"])
        XCTAssertEqual(Shops.suggest("bau", region: "NL", in: table).map(\.name), ["Hornbach Baumarkt"], "a later word matches too")
        XCTAssertEqual(Shops.suggest("ik", region: nil, in: table).map(\.domain), ["ikea.com"])
        XCTAssertEqual(Shops.suggest("  ", region: "NL", in: table), [])
        XCTAssertEqual(Shops.suggest("a", region: "NL", limit: 2, in: table).count, 2)
    }

    func testTheBundledTableIsThere() {
        let all = Shops.all
        XCTAssertGreaterThan(all.count, 1000, "the table from scripts/shops/gen.py is in the bundle")
        let ah = all.first { $0.name == "Albert Heijn" }
        XCTAssertEqual(ah?.domain, "ah.nl")
        XCTAssertEqual(ah?.countries, ["be", "nl"])
        XCTAssertEqual(all.first { $0.name == "Tesco" }?.domain(for: "SK"), "tesco.sk")
        XCTAssertEqual(all.first { $0.name == "Kaufland" }?.domain(for: "SK"), "kaufland.sk")
        XCTAssertTrue(all.contains { $0.name == "Tesco" && ($0.countries == ["eu"] || $0.countries.contains("sk")) }, "a chain found everywhere, or in Slovakia")
        XCTAssertTrue(all.contains { $0.name == "Kaufland" && $0.countries.contains("sk") })
    }
}
