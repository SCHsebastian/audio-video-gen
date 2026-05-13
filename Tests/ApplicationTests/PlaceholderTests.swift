import XCTest
@testable import Application

final class PlaceholderTests: XCTestCase {
    func test_marker() { XCTAssertEqual(ApplicationPlaceholder.marker, "application") }
}
