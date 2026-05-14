import XCTest
@testable import Domain

final class SpectrumFrameTests: XCTestCase {
    func test_holds_bands_rms_and_timestamp() {
        let f = SpectrumFrame(bands: [0, 0.5, 1.0], rms: 0.25, timestamp: HostTime(machAbsolute: 99))
        XCTAssertEqual(f.bands, [0, 0.5, 1.0])
        XCTAssertEqual(f.rms, 0.25)
        XCTAssertEqual(f.timestamp.machAbsolute, 99)
    }

    func test_derived_fields_default_to_zero_for_back_compat() {
        let f = SpectrumFrame(bands: [0.1, 0.2], rms: 0.3, timestamp: .zero)
        XCTAssertEqual(f.bass, 0)
        XCTAssertEqual(f.mid, 0)
        XCTAssertEqual(f.treble, 0)
        XCTAssertEqual(f.centroid, 0)
        XCTAssertEqual(f.flux, 0)
    }

    func test_holds_derived_fields_when_provided() {
        let f = SpectrumFrame(bands: [0.1], rms: 0.2, timestamp: .zero,
                              bass: 0.4, mid: 0.5, treble: 0.6,
                              centroid: 0.7, flux: 0.8)
        XCTAssertEqual(f.bass, 0.4)
        XCTAssertEqual(f.mid, 0.5)
        XCTAssertEqual(f.treble, 0.6)
        XCTAssertEqual(f.centroid, 0.7)
        XCTAssertEqual(f.flux, 0.8)
    }

    func test_stereo_bands_default_to_empty_for_mono() {
        let f = SpectrumFrame(bands: [0.1, 0.2], rms: 0.3, timestamp: .zero)
        XCTAssertTrue(f.leftBands.isEmpty)
        XCTAssertTrue(f.rightBands.isEmpty)
    }

    func test_holds_stereo_bands_when_provided() {
        let l: [Float] = [0.10, 0.20, 0.30, 0.40]
        let r: [Float] = [0.50, 0.60, 0.70, 0.80]
        let f = SpectrumFrame(bands: [0, 0, 0, 0], rms: 0.4, timestamp: .zero,
                              leftBands: l, rightBands: r)
        XCTAssertEqual(f.leftBands, l)
        XCTAssertEqual(f.rightBands, r)
        XCTAssertEqual(f.leftBands.count, f.rightBands.count, "stereo arrays must be the same length")
    }
}
