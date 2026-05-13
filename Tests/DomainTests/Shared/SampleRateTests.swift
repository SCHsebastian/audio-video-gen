import XCTest
@testable import Domain

final class SampleRateTests: XCTestCase {
    func test_equality_and_hashable() {
        XCTAssertEqual(SampleRate(hz: 48_000), SampleRate(hz: 48_000))
        XCTAssertNotEqual(SampleRate(hz: 48_000), SampleRate(hz: 44_100))
        XCTAssertEqual(Set([SampleRate(hz: 48_000), SampleRate(hz: 48_000)]).count, 1)
    }
}
