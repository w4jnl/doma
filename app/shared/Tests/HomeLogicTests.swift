// What the Homes, Home and Trip screens read and do, without the screens: flags and staples
// through the home queries, the out flag's entry on the default list, staleness, a home and
// its spots, a picture that waits on disk, and the trip derived from two homes' flags and
// committed by Arrived.
import XCTest
@testable import Doma

@MainActor
final class HomeLogicTests: XCTestCase {
    func session(staleness: Int64? = nil) throws -> Session {
        let store = try DomaStore.inMemory()
        try store.saveContext(ServerContext(serverID: "S1", baseURL: URL(string: "https://doma.example")!, credentialID: "C1", personID: "pa", displayName: "Jaro", createdAt: 1))
        try store.upsertHousehold(HouseholdRow(serverID: "S1", id: "H1", name: "De Vries", timezone: "Europe/Amsterdam", stalenessDays: staleness, role: "owner"))
        let s = Session(store: store)
        try s.record(Kind.listCreated, ListPayload(listID: "L1", name: "Shopping", isDefault: true))
        try s.record(Kind.homeCreated, HomePayload(homeID: "G", name: "Gouda"))
        return s
    }

    func rows(_ s: Session, _ home: String, days: Int64? = nil, now: Date = Date()) throws -> [FlagRow] {
        try s.store.read(s.scope!) { db, sc in try Queries.flagRows(db, sc, homeID: home, staleness: Staleness(days: days, now: now)) }
    }

    func testFlagsStaplesAndTheDefaultList() throws {
        let s = try session()
        let olie = try XCTUnwrap(HomeActions.addStaple("olijfolie", home: "G", in: s))
        _ = try HomeActions.addStaple("Olijfolie", home: "G", in: s)
        var r = try rows(s, "G")
        XCTAssertEqual(r.map(\.name), ["olijfolie"], "the same name is one staple")
        XCTAssertEqual(r[0].state, .unknown)
        XCTAssertTrue(r[0].isStaple)
        try HomeActions.setFlag(.out, home: "G", item: olie, in: s)
        r = try rows(s, "G")
        XCTAssertEqual(r[0].state, .out)
        let entries = try s.store.read(s.scope!) { db, sc in try Queries.entries(db, sc, listID: "L1") }
        XCTAssertEqual(entries.map(\.itemID), [olie], "out puts the item on the default list")
        XCTAssertEqual(entries[0].forHomeID, "G")
        let cards = try s.store.read(s.scope!) { db, sc in try Queries.homeCards(db, sc, staleness: Staleness(days: nil)) }
        XCTAssertEqual(cards.map(\.missing), [1])
        XCTAssertEqual(cards.map(\.staples), [1])
        try HomeActions.setFlag(.have, home: "G", item: olie, in: s)
        XCTAssertEqual(try rows(s, "G")[0].state, .have)
        // a flag older than the staleness is unknown, and its age shows past half of it
        let later = Date().addingTimeInterval(20 * 86_400)
        let old = try rows(s, "G", days: 14, now: later)
        XCTAssertEqual(old[0].state, .unknown)
        XCTAssertTrue(old[0].ageShown)
        XCTAssertFalse(try rows(s, "G", days: 60, now: later)[0].ageShown)
        XCTAssertTrue(try rows(s, "G", days: 30, now: later)[0].ageShown)
        // a flagged item that is not a staple is listed after the staples
        guard case .added(let melk) = try ListActions.add("melk", to: "L1", in: s) else { return XCTFail("not added") }
        try HomeActions.setFlag(.low, home: "G", item: melk, in: s)
        r = try rows(s, "G")
        XCTAssertEqual(r.map(\.name), ["olijfolie", "melk"])
        XCTAssertFalse(r[1].isStaple)
        try HomeActions.removeStaple(itemID: olie, home: "G", in: s)
        r = try rows(s, "G")
        XCTAssertEqual(r.map(\.isStaple), [false, false], "the flag stays when the staple goes")
    }

    func testHomesAndSpots() throws {
        let s = try session()
        let hut = try XCTUnwrap(HomeActions.createHome(named: " Hut ", in: s))
        XCTAssertNil(try HomeActions.createHome(named: "  ", in: s))
        var homes = try s.store.read(s.scope!) { db, sc in try Queries.homes(db, sc) }
        XCTAssertEqual(homes.map(\.name), ["Gouda", "Hut"])
        try HomeActions.renameHome(hut, to: "De Hut", in: s)
        let pantry = try XCTUnwrap(HomeActions.createSpot(named: "Pantry", home: hut, in: s))
        let fridge = try XCTUnwrap(HomeActions.createSpot(named: "Fridge", home: hut, in: s))
        var spots = try s.store.read(s.scope!) { db, sc in try Queries.spots(db, sc, homeID: hut) }
        XCTAssertEqual(spots.map(\.name), ["Fridge", "Pantry"])
        XCTAssertNil(spots[0].photoID)
        try HomeActions.renameSpot(pantry, to: "Larder", in: s)
        spots = try s.store.read(s.scope!) { db, sc in try Queries.spots(db, sc, homeID: hut) }
        var table = try s.store.tables(s.scope!).spots
        XCTAssertEqual(spots.map(\.name), ["Fridge", "Larder"], "renamed in place: \(table)")
        try HomeActions.archiveSpot(fridge, in: s)
        spots = try s.store.read(s.scope!) { db, sc in try Queries.spots(db, sc, homeID: hut) }
        table = try s.store.tables(s.scope!).spots
        XCTAssertEqual(spots.map(\.name), ["Larder"], "\(table)")
        // homes by name, as the screens list them
        let cards = try s.store.read(s.scope!) { db, sc in try Queries.homeCards(db, sc, staleness: Staleness(days: nil)) }
        XCTAssertEqual(cards.map(\.name), ["De Hut", "Gouda"])
        XCTAssertEqual(cards[0].spots.map(\.name), ["Larder"])
        try HomeActions.archiveHome(hut, in: s)
        homes = try s.store.read(s.scope!) { db, sc in try Queries.homes(db, sc) }
        XCTAssertEqual(homes.map(\.name), ["Gouda"])
    }

    func testAPictureWaitsOnDiskUntilItGoesUp() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("doma-photos-" + ULID.make(), isDirectory: true)
        PhotoFiles.overrideRoot = dir
        defer {
            PhotoFiles.overrideRoot = nil
            try? FileManager.default.removeItem(at: dir)
        }
        let s = try session()
        let spot = try XCTUnwrap(HomeActions.createSpot(named: "Pantry", home: "G", in: s))
        let raw = try XCTUnwrap(Shutter.standIn(label: "Pantry"))
        let id = try XCTUnwrap(HomeActions.addPhoto(raw, spot: spot, in: s))
        // the event is in the outbox with the picture's size, the row is in the table
        let photos = try s.store.read(s.scope!) { db, sc in try Queries.photos(db, sc, spotID: spot) }
        XCTAssertEqual(photos.map(\.id), [id])
        let tables = try s.store.tables(s.scope!)
        XCTAssertEqual(tables.photos.first?.width, 1200)
        XCTAssertEqual(tables.photos.first?.height, 900)
        XCTAssertGreaterThan(tables.photos.first?.bytes ?? 0, 0)
        let spots = try s.store.read(s.scope!) { db, sc in try Queries.spots(db, sc, homeID: "G") }
        XCTAssertEqual(spots.first?.photoID, id, "the newest picture is the spot's")
        // the file waits in pending, and is the picture at hand meanwhile
        let pending = PhotoFiles.pending(server: "S1")
        XCTAssertEqual(pending.map(\.photoID), [id])
        XCTAssertEqual(pending.first?.household, "H1")
        XCTAssertNotNil(PhotoFiles.local(server: "S1", household: "H1", photoID: id, thumb: true))
        // a picture larger than the long edge is scaled, a smaller one kept
        let big = try XCTUnwrap(Pictures.jpeg(from: raw, longEdge: 600))
        XCTAssertEqual(big.width, 600)
        XCTAssertEqual(big.height, 450)
        // once up, the file is the cache
        PhotoFiles.landed(pending[0], server: "S1")
        XCTAssertTrue(PhotoFiles.pending(server: "S1").isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: PhotoFiles.cacheURL(server: "S1", photoID: id, thumb: false).path))
        XCTAssertNotNil(PhotoFiles.local(server: "S1", household: "H1", photoID: id, thumb: false))
        PhotoFiles.wipe(server: "S1")
        XCTAssertNil(PhotoFiles.local(server: "S1", household: "H1", photoID: id, thumb: false))
    }

    func testTripIsDerivedFromTheFlagsAndArrivedMovesThem() throws {
        let s = try session()
        let hut = try XCTUnwrap(HomeActions.createHome(named: "Hut", in: s))
        let melk = try XCTUnwrap(HomeActions.addStaple("melk", home: hut, in: s))
        let brood = try XCTUnwrap(HomeActions.addStaple("brood", home: hut, in: s))
        let kaas = try XCTUnwrap(HomeActions.addStaple("kaas", home: hut, in: s))
        let zout = try XCTUnwrap(HomeActions.addStaple("zout", home: hut, in: s))
        try HomeActions.setFlag(.out, home: hut, item: melk, in: s)
        try HomeActions.setFlag(.low, home: hut, item: brood, in: s)
        try HomeActions.setFlag(.have, home: hut, item: zout, in: s)
        try HomeActions.setFlag(.have, home: "G", item: melk, in: s)
        // melk's out put it on the default list for the hut; eieren is wanted there by hand
        guard case .added(let eieren) = try ListActions.add("eieren", to: "L1", in: s) else { return XCTFail("not added") }
        let eggs = try XCTUnwrap(s.store.read(s.scope!) { db, sc in try Queries.entries(db, sc, listID: "L1") }.first { $0.itemID == eieren })
        try ListActions.setHome(eggs, hut, on: "L1", in: s)

        // the plan is shared: planned twice to the hut, the nearer one carries its needs
        let staleness = Staleness(days: nil)
        let day = 86_400_000.0
        let soon = Date(timeIntervalSince1970: 1_800_000_000 + 3 * day / 1000)
        let later = Date(timeIntervalSince1970: 1_800_000_000 + 10 * day / 1000)
        XCTAssertNil(try TripActions.plan(from: "G", to: "G", date: soon, list: "L1", in: s), "a trip needs two homes")
        let laterID = try XCTUnwrap(TripActions.plan(from: "G", to: hut, date: later, list: nil, in: s))
        let soonID = try XCTUnwrap(TripActions.plan(from: "G", to: hut, date: soon, list: "L1", in: s))
        func trips(_ home: String? = nil) throws -> [TripRow] { try s.store.read(s.scope!) { db, sc in try Queries.trips(db, sc, homeID: home) } }
        var all = try trips()
        XCTAssertEqual(all.map(\.id), [soonID, laterID], "upcoming by date, nearest first")
        XCTAssertEqual(all[0].listName, "Shopping")
        XCTAssertNil(all[1].listID)
        XCTAssertTrue(all.allSatisfy(\.isOpen))
        let soonTrip = all[0], laterTrip = all[1]
        XCTAssertTrue(TripPlan.carries(soonTrip, among: all))
        XCTAssertFalse(TripPlan.carries(laterTrip, among: all), "the hut's needs are on the nearer trip")
        var plan = try TripActions.plan(for: soonTrip, among: all, in: s, staleness: staleness)
        XCTAssertEqual(plan.bring.map(\.name), ["melk"], "out at the hut and have in Gouda")
        XCTAssertEqual(plan.buy.map(\.name), ["brood", "eieren"], "low at the hut and not have in Gouda; and the open entry for the hut")
        XCTAssertEqual(plan.buy.map(\.onList), [false, true])
        XCTAssertEqual(plan.buy.map(\.listName), [nil, "Shopping"], "the row names the list it is on")
        XCTAssertEqual(plan.check.map(\.itemID), [kaas], "an unknown staple of the hut")
        XCTAssertTrue(try TripActions.plan(for: laterTrip, among: all, in: s, staleness: staleness).isEmpty)

        // the plan changes under the same id; a cancel drops it to the history
        try TripActions.plan(id: laterID, from: hut, to: "G", date: later, list: "L1", in: s)
        all = try trips()
        XCTAssertEqual(all.first { $0.id == laterID }?.fromName, "Hut")
        try TripActions.cancel(laterID, in: s)
        all = try trips()
        XCTAssertEqual(all.map(\.isOpen), [true, false])
        XCTAssertNotNil(all[1].cancelledAt)

        try TripActions.addToList(brood, forHome: hut, list: soonTrip.listID, in: s)
        try TripActions.addToList(brood, forHome: hut, list: nil, in: s)
        plan = try TripActions.plan(for: soonTrip, among: all, in: s, staleness: staleness)
        XCTAssertEqual(plan.buy.map(\.onList), [true, true])
        XCTAssertEqual(try s.store.read(s.scope!) { db, sc in try Queries.entries(db, sc, listID: "L1") }.filter { $0.itemID == brood }.count, 1, "once on the list is enough")

        XCTAssertNil(try TripActions.arrive(soonTrip, packed: [], in: s), "nothing packed, no arrival")
        let trip = try XCTUnwrap(TripActions.arrive(soonTrip, packed: [melk], in: s))
        XCTAssertEqual(trip, soonID)
        XCTAssertEqual(try rows(s, hut).first { $0.itemID == melk }?.state, .have)
        XCTAssertEqual(try rows(s, "G").first { $0.itemID == melk }?.state, .out)
        let hutTrips = try trips(hut)
        XCTAssertEqual(hutTrips.map(\.id), [soonID, laterID], "arrived first, newest over")
        XCTAssertEqual(hutTrips.first?.fromName, "Gouda")
        XCTAssertEqual(hutTrips.first?.toName, "Hut")
        XCTAssertEqual(hutTrips.first?.moved, ["melk"])
        XCTAssertNotNil(hutTrips.first?.arrivedAt)
        XCTAssertEqual(hutTrips.first?.date, millis(Calendar.current.startOfDay(for: soon)), "the plan's date stays")
        XCTAssertEqual(try trips("nowhere").count, 0)
        let again = try XCTUnwrap(TripActions.plan(from: "G", to: hut, date: later, list: nil, in: s))
        all = try trips()
        plan = try TripActions.plan(for: try XCTUnwrap(all.first { $0.id == again }), among: all, in: s, staleness: staleness)
        XCTAssertTrue(plan.bring.isEmpty, "melk is at the hut now")
        // the out flag in Gouda would put melk on the default list, but the entry the hut's out
        // made is still open, so there is one entry, not two
        let open = try s.store.read(s.scope!) { db, sc in try Queries.entries(db, sc, listID: "L1") }.filter { $0.itemID == melk && !$0.isChecked }
        XCTAssertEqual(open.map(\.forHomeID), [hut])
    }
}
