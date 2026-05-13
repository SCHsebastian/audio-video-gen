import XCTest
@testable import Domain

final class LanguageTests: XCTestCase {
    func test_raw_value_round_trip() {
        for lang in Language.allCases {
            XCTAssertEqual(Language(rawValue: lang.rawValue), lang)
        }
    }
    func test_all_three_cases_present() {
        XCTAssertEqual(Set(Language.allCases), [.system, .en, .es])
    }
    func test_display_names_are_nonempty() {
        for lang in Language.allCases {
            XCTAssertFalse(lang.displayName.isEmpty)
        }
    }
}
