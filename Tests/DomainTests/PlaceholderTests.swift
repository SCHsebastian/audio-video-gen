import XCTest
@testable import Domain

final class PlaceholderTests: XCTestCase {
    func test_marker() { XCTAssertEqual(DomainPlaceholder.marker, "domain") }
}
