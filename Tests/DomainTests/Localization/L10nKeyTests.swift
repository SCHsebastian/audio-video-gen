import XCTest
@testable import Domain

final class L10nKeyTests: XCTestCase {
    func test_raw_values_unique_and_nonempty() {
        let raws = L10nKey.allCases.map(\.rawValue)
        XCTAssertEqual(raws.count, Set(raws).count, "duplicate L10nKey rawValues")
        for r in raws { XCTAssertFalse(r.isEmpty) }
    }
    func test_known_keys_present() {
        XCTAssertEqual(L10nKey.sourceLabel.rawValue, "toolbar.source.label")
        XCTAssertEqual(L10nKey.waitingForAudio.rawValue, "overlay.waitingForAudio")
        XCTAssertEqual(L10nKey.settingsLanguageLabel.rawValue, "settings.language.label")
    }
}
