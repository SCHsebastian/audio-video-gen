import XCTest
@testable import Domain

final class UserPreferencesTests: XCTestCase {
    func test_defaults() {
        let p = UserPreferences.default
        XCTAssertEqual(p.lastScene, .bars)
        XCTAssertEqual(p.lastSource, .systemWide)
        XCTAssertEqual(p.lastPaletteName, "XP Neon")
        XCTAssertEqual(p.lastLanguage, .system)
    }
    func test_init_holds_all_fields() {
        let p = UserPreferences(lastSource: .process(pid: 1, bundleID: "x"),
                                lastScene: .alchemy,
                                lastPaletteName: "Aurora",
                                lastLanguage: .es)
        XCTAssertEqual(p.lastLanguage, .es)
        XCTAssertEqual(p.lastScene, .alchemy)
    }
}
