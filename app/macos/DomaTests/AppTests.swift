// The Mac app's own tests; DomaKit's are in ../shared/Tests and run on both platforms.
import XCTest
@testable import Doma

final class AppTests: XCTestCase {
    func testBundle() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "nl.w4j.doma.mac")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "doma")
    }
}
