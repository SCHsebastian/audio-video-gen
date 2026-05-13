import XCTest
@testable import Application
@testable import Domain

final class ChangeLanguageUseCaseTests: XCTestCase {
    func test_sets_language_on_localizer_and_persists() {
        let loc = FakeLocalizing()
        let prefs = FakePreferencesStoring()
        let sut = ChangeLanguageUseCase(localizer: loc, preferences: prefs)
        sut.execute(.es)
        XCTAssertEqual(loc.setLanguageCalls, [.es])
        XCTAssertEqual(prefs.stored.lastLanguage, .es)
    }
}
