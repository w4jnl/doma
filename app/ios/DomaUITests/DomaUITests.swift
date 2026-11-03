// The phone driven from outside against a real doma (scripts/ui-test.sh starts one and writes
// tmp/live.json): join from a QR picture, add, strike and clear, add while offline and then
// sync. Each test mints its own invite through the admin pages, so it starts from nothing.
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

    /// A fresh owner invite from the admin pages.
    func mintInvite(_ live: Live) throws -> String {
        let base = URL(string: live.baseURL)!
        let session: URLSession
        if let s = Self.admin {
            session = s
        } else {
            session = URLSession(configuration: .ephemeral)
            var login = URLRequest(url: base.appendingPathComponent("/admin/login"))
            login.httpMethod = "POST"
            login.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            login.httpBody = Data("login=\(live.admin.login)&password=\(live.admin.password.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)".utf8)
            _ = try sync(session, login)
            Self.admin = session
        }
        let admin = try sync(session, URLRequest(url: base.appendingPathComponent("/admin")))
        let page = String(decoding: admin, as: UTF8.self)
        let csrf = try XCTUnwrap(page.range(of: #"name="_csrf" value="([^"]+)""#, options: .regularExpression).map { page[$0] }
            .flatMap { $0.split(separator: "\"").last.map(String.init) }, "no admin session: " + String(page.prefix(200)))
        var invite = URLRequest(url: base.appendingPathComponent("/admin/h/\(live.household)/invite"))
        invite.httpMethod = "POST"
        invite.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        invite.httpBody = Data("_csrf=\(csrf)".utf8)
        let html = String(decoding: try sync(session, invite), as: UTF8.self)
        let token = try XCTUnwrap(html.range(of: #"/i/[A-Za-z0-9_-]+"#, options: .regularExpression).map { String(html[$0].dropFirst(3)) })
        return live.baseURL + "/i/" + token
    }

    private func sync(_ session: URLSession, _ request: URLRequest) throws -> Data {
        let done = expectation(description: "http")
        let box = Box()
        session.dataTask(with: request) { data, _, error in
            box.data = data
            box.error = error
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        if let e = box.error { throw e }
        return box.data ?? Data()
    }

    final class Box: @unchecked Sendable {
        var data: Data?
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
    }

    func testOfflineAddThenSync() throws {
        let live = try live()
        // joined online; then the network is away for a while and comes back by itself
        let app = launch(join: try mintInvite(live), extra: ["DOMA_UITEST_OFFLINE_SECONDS": "45"])
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
        let deadline = Date().addingTimeInterval(70)
        while app.descendants(matching: .any)["waiting"].exists, Date() < deadline {
            sleep(1)
        }
        XCTAssertFalse(app.descendants(matching: .any)["waiting"].exists, "everything went up")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertFalse(app.descendants(matching: .any)["offline"].exists, "the badge is gone")
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
