import XCTest
@testable import Domain

final class AudioFrameTests: XCTestCase {
    func test_holds_samples_and_metadata() {
        let f = AudioFrame(samples: [0, 0.5, -0.5, 0], sampleRate: SampleRate(hz: 48_000), timestamp: HostTime(machAbsolute: 42))
        XCTAssertEqual(f.samples.count, 4)
        XCTAssertEqual(f.sampleRate.hz, 48_000)
        XCTAssertEqual(f.timestamp.machAbsolute, 42)
    }
}
