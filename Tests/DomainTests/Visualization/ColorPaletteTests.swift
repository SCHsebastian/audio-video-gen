import XCTest
@testable import Domain

final class ColorPaletteTests: XCTestCase {
    func test_init_holds_stops() {
        let p = ColorPalette(name: "Test", stops: [RGB(r: 0, g: 0, b: 0), RGB(r: 1, g: 1, b: 1)])
        XCTAssertEqual(p.name, "Test")
        XCTAssertEqual(p.stops.count, 2)
    }
}
