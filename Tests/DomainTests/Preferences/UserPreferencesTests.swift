import XCTest
@testable import Domain

final class UserPreferencesTests: XCTestCase {
    func test_defaults() {
        let p = UserPreferences.default
        XCTAssertEqual(p.lastScene, .bars)
        XCTAssertEqual(p.lastSource, .systemWide)
        XCTAssertEqual(p.lastPaletteName, "XP Neon")
    }
}
