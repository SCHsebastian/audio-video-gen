import XCTest
@testable import Domain

final class RenderOptionsTests: XCTestCase {
    func test_holds_width_height_fps_bitrate() {
        let o = RenderOptions(width: 1920, height: 1080, fps: 60, bitrate: 12_000_000)
        XCTAssertEqual(o.width, 1920)
        XCTAssertEqual(o.height, 1080)
        XCTAssertEqual(o.fps, 60)
        XCTAssertEqual(o.bitrate, 12_000_000)
    }

    func test_resolution_dimensions_match_design() {
        XCTAssertEqual(RenderOptions.Resolution.hd720.width, 1280)
        XCTAssertEqual(RenderOptions.Resolution.hd720.height, 720)
        XCTAssertEqual(RenderOptions.Resolution.hd1080.width, 1920)
        XCTAssertEqual(RenderOptions.Resolution.hd1080.height, 1080)
        XCTAssertEqual(RenderOptions.Resolution.uhd4k.width, 3840)
        XCTAssertEqual(RenderOptions.Resolution.uhd4k.height, 2160)
    }

    func test_make_returns_design_bitrate_table() {
        XCTAssertEqual(RenderOptions.make(.hd720,  .fps30).bitrate,  5_000_000)
        XCTAssertEqual(RenderOptions.make(.hd720,  .fps60).bitrate,  7_500_000)
        XCTAssertEqual(RenderOptions.make(.hd1080, .fps30).bitrate,  8_000_000)
        XCTAssertEqual(RenderOptions.make(.hd1080, .fps60).bitrate, 12_000_000)
        XCTAssertEqual(RenderOptions.make(.uhd4k,  .fps30).bitrate, 30_000_000)
        XCTAssertEqual(RenderOptions.make(.uhd4k,  .fps60).bitrate, 45_000_000)
    }

    func test_make_propagates_resolution_and_fps() {
        let o = RenderOptions.make(.hd1080, .fps60)
        XCTAssertEqual(o.width, 1920)
        XCTAssertEqual(o.height, 1080)
        XCTAssertEqual(o.fps, 60)
    }

    func test_equatable_distinguishes_resolutions() {
        XCTAssertNotEqual(RenderOptions.make(.hd720, .fps30), RenderOptions.make(.hd1080, .fps30))
        XCTAssertEqual(RenderOptions.make(.hd1080, .fps60), RenderOptions.make(.hd1080, .fps60))
    }
}
