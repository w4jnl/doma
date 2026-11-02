// The iPhone app's own tests; DomaKit's are in ../shared/Tests and run on both platforms.
import XCTest
@testable import Doma

final class AppTests: XCTestCase {
    func testBundle() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "nl.w4j.doma")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "doma")
        let schemes = (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])?.first?["CFBundleURLSchemes"] as? [String]
        XCTAssertEqual(schemes, ["doma"])
    }
}
