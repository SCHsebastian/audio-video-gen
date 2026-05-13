import XCTest
@testable import Application
@testable import Domain

final class SelectAudioSourceUseCaseTests: XCTestCase {
    func test_persists_chosen_source() {
        let prefs = FakePreferencesStoring()
        let sut = SelectAudioSourceUseCase(preferences: prefs)
        sut.execute(.process(pid: 42, bundleID: "com.apple.Music"))
        XCTAssertEqual(prefs.stored.lastSource, .process(pid: 42, bundleID: "com.apple.Music"))
    }
}
