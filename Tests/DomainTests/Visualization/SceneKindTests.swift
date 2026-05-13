import XCTest
@testable import Domain

final class SceneKindTests: XCTestCase {
    func test_raw_value_round_trip() {
        for k in SceneKind.allCases {
            XCTAssertEqual(SceneKind(rawValue: k.rawValue), k)
        }
    }
    func test_all_scenes_present() {
        XCTAssertEqual(Set(SceneKind.allCases), [.bars, .scope, .alchemy, .tunnel, .lissajous])
    }
}
