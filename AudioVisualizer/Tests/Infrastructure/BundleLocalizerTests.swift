import XCTest
import Domain
@testable import AudioVisualizer

final class BundleLocalizerTests: XCTestCase {
    func test_english_returns_english_strings() {
        let sut = BundleLocalizer(initialLanguage: .en)
        XCTAssertEqual(sut.string(.sceneBars), "Bars")
        XCTAssertEqual(sut.string(.sourceLabel), "Source")
        XCTAssertEqual(sut.current, .en)
    }
    func test_spanish_returns_spanish_strings() {
        let sut = BundleLocalizer(initialLanguage: .es)
        XCTAssertEqual(sut.string(.sceneBars), "Barras")
        XCTAssertEqual(sut.string(.waitingForAudio), "Esperando audio…")
        XCTAssertEqual(sut.current, .es)
    }
    func test_setLanguage_changes_resolved_strings() {
        let sut = BundleLocalizer(initialLanguage: .en)
        XCTAssertEqual(sut.string(.sceneBars), "Bars")
        sut.setLanguage(.es)
        XCTAssertEqual(sut.string(.sceneBars), "Barras")
        XCTAssertEqual(sut.current, .es)
    }
    func test_resolved_locale_reflects_current() {
        let sut = BundleLocalizer(initialLanguage: .en)
        XCTAssertEqual(sut.resolvedLocale, "en")
        sut.setLanguage(.es)
        XCTAssertEqual(sut.resolvedLocale, "es")
    }
}
