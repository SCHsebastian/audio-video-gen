import XCTest
@testable import Domain

final class SpectrumFrameTests: XCTestCase {
    func test_holds_bands_rms_and_timestamp() {
        let f = SpectrumFrame(bands: [0, 0.5, 1.0], rms: 0.25, timestamp: HostTime(machAbsolute: 99))
        XCTAssertEqual(f.bands, [0, 0.5, 1.0])
        XCTAssertEqual(f.rms, 0.25)
        XCTAssertEqual(f.timestamp.machAbsolute, 99)
    }
}
