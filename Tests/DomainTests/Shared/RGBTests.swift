import XCTest
@testable import Domain

final class RGBTests: XCTestCase {
    func test_components() {
        let c = RGB(r: 1, g: 0.5, b: 0)
        XCTAssertEqual(c.r, 1); XCTAssertEqual(c.g, 0.5); XCTAssertEqual(c.b, 0)
    }
}
