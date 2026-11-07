// The phone driven from outside against a real doma (scripts/ui-test.sh starts one and writes
// tmp/live.json): join from a QR picture, add, strike and clear, add while offline and then
// sync, a flag, a picture, a trip. Each test mints its own invite through the admin pages, so
// it starts from nothing.
import CoreImage
import CoreImage.CIFilterBuiltins
import XCTest

final class DomaUITests: XCTestCase {
    struct Live: Decodable {
        struct Admin: Decodable { var login: String; var password: String }
        var baseURL: String
        var invite: String
        var household: String
        var admin: Admin
        enum CodingKeys: String, CodingKey {
            case invite, household, admin
            case baseURL = "base_url"
        }
    }

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func live() throws -> Live {
        let url = Self.root.appendingPathComponent("tmp/live.json")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("no live server: make ui-test") }
        return try JSONDecoder().decode(Live.self, from: data)
    }

    /// The admin's session, one for the whole run: the login is rate limited per address.
    nonisolated(unsafe) static var admin: URLSession?

    /// The admin's session, signed in once, and a CSRF token from its households page.
    func admin(_ live: Live) throws -> (URLSession, String) {
        let base = URL(string: live.baseURL)!
        let session: URLSession
        if let s = Self.admin {
            session = s
        } else {
            session = URLSession(configuration: .ephemeral)
            _ = try post(session, base.appendingPathComponent("/admin/login"), "login=\(live.admin.login)&password=\(live.admin.password.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)")
            Self.admin = session
        }
        let admin = try fetch(session, URLRequest(url: base.appendingPathComponent("/admin"))).data
        let page = String(decoding: admin, as: UTF8.self)
        let csrf = try XCTUnwrap(page.range(of: #"name="_csrf" value="([^"]+)""#, options: .regularExpression).map { page[$0] }
            .flatMap { $0.split(separator: "\"").last.map(String.init) }, "no admin session: " + String(page.prefix(200)))
        return (session, csrf)
    }

    /// A fresh owner invite from the admin pages, for the run's household or another.
    func mintInvite(_ live: Live, household: String? = nil) throws -> String {
        let base = URL(string: live.baseURL)!
        let (session, csrf) = try admin(live)
        let html = String(decoding: try post(session, base.appendingPathComponent("/admin/h/\(household ?? live.household)/invite"), "_csrf=\(csrf)").data, as: UTF8.self)
        let token = try XCTUnwrap(html.range(of: #"/i/[A-Za-z0-9_-]+"#, options: .regularExpression).map { String(html[$0].dropFirst(3)) })
        return live.baseURL + "/i/" + token
    }

    /// Another household from the admin pages; its id, read off the page it lands on.
    func createHousehold(_ live: Live, named name: String, home: String) throws -> String {
        let base = URL(string: live.baseURL)!
        let (session, csrf) = try admin(live)
        let form = "_csrf=\(csrf)&name=\(name.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)&timezone=Europe/Amsterdam&home=\(home.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)"
        let landed = try post(session, base.appendingPathComponent("/admin/households"), form).response?.url
        let id = try XCTUnwrap(landed?.lastPathComponent, "no household page after the form")
        XCTAssertNotEqual(id, "households", "the form did not make a household")
        return id
    }

    private func post(_ session: URLSession, _ url: URL, _ form: String) throws -> (data: Data, response: URLResponse?) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form.utf8)
        return try fetch(session, request)
    }

    private func fetch(_ session: URLSession, _ request: URLRequest) throws -> (data: Data, response: URLResponse?) {
        let done = expectation(description: "http")
        let box = Box()
        session.dataTask(with: request) { data, response, error in
            box.data = data
            box.response = response
            box.error = error
            done.fulfill()
        }.resume()
        // the admin's sign-in hashes the password; the CI Mac takes its time over it
        wait(for: [done], timeout: 60)
        if let e = box.error { throw e }
        return (box.data ?? Data(), box.response)
    }

    final class Box: @unchecked Sendable {
        var data: Data?
        var response: URLResponse?
        var error: Error?
    }

    func launch(join: String? = nil, extra: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DOMA_UITEST"] = "1"
        app.launchEnvironment["DOMA_UITEST_NO_CAMERA"] = "1"
        if let join { app.launchEnvironment["DOMA_UITEST_JOIN"] = join }
        for (k, v) in extra { app.launchEnvironment[k] = v }
        app.launch()
        return app
    }

    func testJoinFromAQRPicture() throws {
        let live = try live()
        let url = try mintInvite(live)
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.utf8)
        let image = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let png = try XCTUnwrap(CIContext().pngRepresentation(of: image, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()))
        let app = launch(extra: ["DOMA_UITEST_QR_PNG": png.base64EncodedString()])
        // the code was read; the first join asks the name
        let name = app.textFields["display-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        let link = app.textFields["invite-link"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        let deadline = Date().addingTimeInterval(10)
        while (link.value as? String ?? "").isEmpty || link.value as? String == "Invite link or code", Date() < deadline {
            sleep(1)
        }
        XCTAssertEqual(link.value as? String, url, "the code was read from the picture")
        name.tap()
        name.typeText("Jaro")
        XCTAssertTrue(app.buttons["join"].isEnabled, "Join is enabled once the name is in")
        app.buttons["join"].tap()
        XCTAssertTrue(app.staticTexts["Shopping"].waitForExistence(timeout: 15), "the default list came down and is the first screen")
    }

    func testAddStrikeAndClear() throws {
        let live = try live()
        let app = launch(join: try mintInvite(live))
        XCTAssertTrue(app.staticTexts["Shopping"].waitForExistence(timeout: 15))
        let field = app.textFields["add-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("melk 2\n")
        let row = app.buttons["entry-melk"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("melk 2x"))
        field.typeText("brood\n")
        XCTAssertTrue(app.buttons["entry-brood"].waitForExistence(timeout: 5))
        // a second melk flashes the row instead of adding one
        field.typeText("Melk\n")
        sleep(1)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier == 'entry-melk'")).count, 1)
        row.tap()
        // the row answers from the store's observation, one hop after the tap; the runner is slow
        let struck = expectation(for: NSPredicate(format: "label BEGINSWITH 'checked'"), evaluatedWith: row)
        wait(for: [struck], timeout: 10)
        // Clear arms, then clears
        app.buttons["clear"].tap()
        XCTAssertTrue(app.buttons["Really clear?"].waitForExistence(timeout: 3))
        app.buttons["Really clear?"].tap()
        XCTAssertFalse(row.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["entry-brood"].exists)
        XCTAssertTrue(app.buttons["Recent"].exists, "the cleared item is in Recent")
        // Lists at the top left opens the overview; picking the list comes back
        app.buttons["all-lists"].tap()
        XCTAssertTrue(app.buttons["New list"].waitForExistence(timeout: 10), "the overview is up")
        let shopping = app.buttons["Shopping"].firstMatch
        XCTAssertTrue(shopping.waitForExistence(timeout: 5), "the list is in the overview")
        shopping.tap()
        XCTAssertTrue(app.textFields["add-field"].waitForExistence(timeout: 10), "back in the list")
        // the Lists tab's second tap steps to the overview and back
        let lists = app.tabBars.buttons["Lists"]
        XCTAssertTrue(lists.waitForExistence(timeout: 5), "the tab bar is back once the keyboard is down")
        lists.tap()
        XCTAssertTrue(app.buttons["New list"].waitForExistence(timeout: 10), "the tab's second tap opens the overview")
        lists.tap()
        XCTAssertTrue(app.textFields["add-field"].waitForExistence(timeout: 10), "and its third tap comes back")
        // History, the overview's last row, opens on the month the melk was bought in
        lists.tap()
        XCTAssertTrue(app.buttons["New list"].waitForExistence(timeout: 10))
        let history = app.descendants(matching: .any)["history"].firstMatch
        for _ in 0..<4 where !history.waitForExistence(timeout: 1) { app.swipeUp() }
        history.tap()
        XCTAssertTrue(app.buttons["history-previous"].waitForExistence(timeout: 10), "the History screen is up")
        XCTAssertTrue(app.descendants(matching: .any)["history-melk"].firstMatch.waitForExistence(timeout: 5),
                      "the cleared melk is in the month")
    }

    func testOfflineAddThenSync() throws {
        let live = try live()
        // joined online; then the network is away for a while and comes back by itself
        let app = launch(join: try mintInvite(live), extra: ["DOMA_UITEST_OFFLINE_SECONDS": "90"])
        XCTAssertTrue(app.staticTexts["Shopping"].waitForExistence(timeout: 15), "joined and synced")
        let field = app.textFields["add-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "the list is open")
        field.tap()
        field.typeText("kaas\n")
        XCTAssertTrue(app.buttons["entry-kaas"].waitForExistence(timeout: 5), "the row appears before any network")
        XCTAssertTrue(app.descendants(matching: .any)["offline"].waitForExistence(timeout: 10), "one small badge, never an alert")
        // the outbox holds the two events until the network is back; the keyboard goes with a
        // swipe on the list, as in the hand, before the tab bar is reachable
        app.swipeDown()
        app.tabBars.buttons["Family"].tap()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "Settings is up")
        // About is at the foot, under the person's devices; scroll it into the list's view
        let waiting = app.descendants(matching: .any)["waiting"]
        for _ in 0..<5 where !waiting.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(waiting.exists, "item.named and entry.added wait")
        // the network comes back: the outbox drains and the row goes
        let deadline = Date().addingTimeInterval(120)
        while app.descendants(matching: .any)["waiting"].exists, Date() < deadline {
            sleep(1)
        }
        XCTAssertFalse(app.descendants(matching: .any)["waiting"].exists, "everything went up")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertFalse(app.descendants(matching: .any)["offline"].exists, "the badge is gone")
    }

    /// A second household on the same doma, joined from Family with the same key and no name
    /// asked again; the title becomes the switcher and goes between the two.
    func testJoinASecondHouseholdAndSwitch() throws {
        let live = try live()
        let app = launch(join: try mintInvite(live))
        XCTAssertTrue(app.staticTexts["Shopping"].waitForExistence(timeout: 15), "the first household is in")
        let second = try createHousehold(live, named: "Buren", home: "Elsewhere")
        let url = try mintInvite(live, household: second)
        app.tabBars.buttons["Family"].tap()
        // the button is at the foot, under every member the run's tests have joined
        let join = app.buttons["Join another household"]
        for _ in 0..<8 where !join.waitForExistence(timeout: 1) { app.swipeUp() }
        XCTAssertTrue(join.exists, "the foot of Family")
        join.tap()
        let link = app.textFields["invite-link"]
        XCTAssertTrue(link.waitForExistence(timeout: 10), "Scan as a sheet, with its field as there is no camera")
        link.tap()
        link.typeText(url)
        XCTAssertFalse(app.textFields["display-name"].exists, "the name is known on this doma")
        app.buttons["join"].tap()
        let switcher = app.buttons["Household"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 15), "two households: the title is the switcher")
        switcher.tap()
        let buren = app.buttons["Buren"]
        XCTAssertTrue(buren.waitForExistence(timeout: 5), "the menu lists both")
        buren.tap()
        XCTAssertTrue(app.staticTexts["Buren"].waitForExistence(timeout: 10), "the second household is in front")
        // the tab bar folded into one pill while Family scrolled, and the second household's
        // short Family cannot scroll it open: a tap on the pill opens it
        let homes = app.tabBars.buttons["Homes"]
        for _ in 0..<4 where !homes.waitForExistence(timeout: 2) {
            app.tabBars.buttons["Family"].tap()
            if !homes.exists { app.swipeDown() }
        }
        XCTAssertTrue(homes.exists, "the tab bar is open")
        homes.tap()
        XCTAssertTrue(app.descendants(matching: .any)["home-Elsewhere"].firstMatch.waitForExistence(timeout: 10), "the second household's home, not the first's")
        XCTAssertFalse(app.descendants(matching: .any)["home-Gouda"].exists)
        app.buttons["Household"].tap()
        let deVries = app.buttons["De Vries"]
        XCTAssertTrue(deVries.waitForExistence(timeout: 5))
        deVries.tap()
        XCTAssertTrue(app.descendants(matching: .any)["home-Gouda"].firstMatch.waitForExistence(timeout: 10), "and back")
    }

    /// Homes: the first home is there from the household; a staple typed under Edit, flagged
    /// out in the row, is on the shopping list.
    func testFlagOutPutsItOnTheList() throws {
        let live = try live()
        let app = launch(join: try mintInvite(live))
        XCTAssertTrue(app.staticTexts["Shopping"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Homes"].tap()
        let gouda = app.descendants(matching: .any)["home-Gouda"].firstMatch
        XCTAssertTrue(gouda.waitForExistence(timeout: 10), "the household's first home is a card")
        gouda.tap()
        let field = app.textFields["new-staple"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the home is open, the add bar at the bottom")
        field.tap()
        field.typeText("olijfolie\n")
        let out = app.buttons["flag-out-olijfolie"]
        XCTAssertTrue(out.waitForExistence(timeout: 5), "an unanswered staple offers the three flags")
        out.tap()
        let flag = app.descendants(matching: .any)["flag-olijfolie"]
        XCTAssertTrue(flag.waitForExistence(timeout: 5))
        XCTAssertTrue(flag.label.contains("out"), "the row shows the flag as a word: \(flag.label)")
        app.tabBars.buttons["Lists"].tap()
        XCTAssertTrue(app.buttons["entry-olijfolie"].waitForExistence(timeout: 10), "out put it on the default list")
    }

    /// A spot made under Edit, a picture taken for it (a stand-in without a camera), shown as
    /// the spot's picture.
    func testAPictureOfASpot() throws {
        let live = try live()
        let app = launch(join: try mintInvite(live))
        XCTAssertTrue(app.staticTexts["Shopping"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Homes"].tap()
        let gouda = app.descendants(matching: .any)["home-Gouda"].firstMatch
        XCTAssertTrue(gouda.waitForExistence(timeout: 10))
        gouda.tap()
        let add = app.descendants(matching: .any)["add-spot"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "the home is open, the + at the end of the strip")
        add.tap()
        let field = app.textFields["new-spot"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("Pantry\n")
        XCTAssertTrue(app.descendants(matching: .any)["spot-Pantry"].waitForExistence(timeout: 5), "the spot is in the strip")
        app.buttons["take-photos"].tap()
        let shutter = app.buttons["shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 10), "the camera screen is up")
        shutter.tap()
        // one spot: the picture leaves the camera screen by itself
        let spot = app.descendants(matching: .any)["spot-Pantry"]
        XCTAssertTrue(spot.waitForExistence(timeout: 10), "back on the home")
        spot.tap()
        XCTAssertTrue(app.descendants(matching: .any)["photo"].waitForExistence(timeout: 10), "the spot's picture is shown")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'taken'")).firstMatch.waitForExistence(timeout: 5), "with when it was taken")
    }

    /// Two homes, melk have here and out there: the trip says bring it; Arrived moves the flag.
    func testTripDerivedAndArrived() throws {
        let live = try live()
        let app = launch(join: try mintInvite(live))
        XCTAssertTrue(app.staticTexts["Shopping"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Homes"].tap()
        app.buttons["new-home"].tap()
        let name = app.textFields["new-home-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Hut\n")
        // melk is a staple of both; have in Gouda, out at the hut
        for (home, flag) in [("home-Gouda", "flag-have-melk"), ("home-Hut", "flag-out-melk")] {
            let card = app.descendants(matching: .any)[home].firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 10), home)
            card.tap()
            let field = app.textFields["new-staple"]
            XCTAssertTrue(field.waitForExistence(timeout: 10), "the home is open")
            field.tap()
            field.typeText("melk\n")
            let button = app.buttons[flag]
            XCTAssertTrue(button.waitForExistence(timeout: 5), flag)
            button.tap()
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        app.tabBars.buttons["Trip"].tap()
        // plan the trip: Gouda to Hut, today, on the shopping list
        let planTrip = app.buttons["plan-trip"]
        XCTAssertTrue(planTrip.waitForExistence(timeout: 10), "a second home makes trips possible")
        planTrip.tap()
        let plan = app.buttons["plan"]
        XCTAssertTrue(plan.waitForExistence(timeout: 5))
        plan.tap()
        let tripRow = app.descendants(matching: .any)["trip-Gouda-Hut"].firstMatch
        XCTAssertTrue(tripRow.waitForExistence(timeout: 10), "the trip is listed")
        XCTAssertTrue(tripRow.label.contains("1 to bring"), "the row counts what to bring: \(tripRow.label)")
        tripRow.tap()
        let bring = app.descendants(matching: .any)["bring-melk"].firstMatch
        XCTAssertTrue(bring.waitForExistence(timeout: 10), "melk is on the bring list")
        let arrived = app.descendants(matching: .any)["arrived"].firstMatch
        XCTAssertFalse(arrived.isEnabled, "nothing packed yet")
        bring.tap()
        XCTAssertTrue(arrived.isEnabled)
        arrived.tap()
        XCTAssertTrue(app.descendants(matching: .any)["plan-trip"].waitForExistence(timeout: 10), "arriving goes back to the trips")
        XCTAssertFalse(tripRow.exists, "the trip is over")
        app.tabBars.buttons["Homes"].tap()
        let hut = app.descendants(matching: .any)["home-Hut"].firstMatch
        XCTAssertTrue(hut.waitForExistence(timeout: 10))
        hut.tap()
        let flag = app.descendants(matching: .any)["flag-melk"]
        XCTAssertTrue(flag.waitForExistence(timeout: 10))
        XCTAssertTrue(flag.label.contains("have"), "the trip moved the flag: \(flag.label)")
    }

    func testInviteShowsAQR() throws {
        let live = try live()
        let app = launch(join: try mintInvite(live))
        XCTAssertTrue(app.staticTexts["Shopping"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Family"].tap()
        XCTAssertTrue(app.staticTexts["Jaro"].waitForExistence(timeout: 10), "the owner is a member")
        app.buttons["Invite"].tap()
        app.buttons["Invite a member"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["qr"].waitForExistence(timeout: 10), "the QR is shown")
        XCTAssertTrue(app.buttons["Share the invite"].exists, "with Share under it")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["member"].waitForExistence(timeout: 5), "the pending invite is listed")
    }
}
