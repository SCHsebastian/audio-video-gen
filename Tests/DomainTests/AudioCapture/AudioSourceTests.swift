import XCTest
@testable import Domain

final class AudioSourceTests: XCTestCase {
    func test_systemWide_equality() {
        XCTAssertEqual(AudioSource.systemWide, AudioSource.systemWide)
    }
    func test_process_equality() {
        XCTAssertEqual(AudioSource.process(pid: 100, bundleID: "com.spotify.client"),
                       AudioSource.process(pid: 100, bundleID: "com.spotify.client"))
        XCTAssertNotEqual(AudioSource.process(pid: 100, bundleID: "com.spotify.client"),
                          AudioSource.process(pid: 101, bundleID: "com.spotify.client"))
    }
}
