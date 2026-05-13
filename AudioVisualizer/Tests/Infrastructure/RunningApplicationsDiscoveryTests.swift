import XCTest
import Domain
@testable import AudioVisualizer

final class RunningApplicationsDiscoveryTests: XCTestCase {
    func test_returns_list_without_throwing() async throws {
        let sut = RunningApplicationsDiscovery()
        let list = try await sut.listAudioProcesses()
        // We can't assert on the contents, but every entry must have a non-empty bundleID and pid > 0.
        for p in list {
            XCTAssertGreaterThan(p.pid, 0)
            XCTAssertFalse(p.bundleID.isEmpty)
            XCTAssertFalse(p.displayName.isEmpty)
        }
    }

    func test_parentBundleID_strips_helper_suffix() {
        XCTAssertEqual(RunningApplicationsDiscovery.parentBundleID(of: "com.google.Chrome.helper.Audio"), "com.google.Chrome")
        XCTAssertEqual(RunningApplicationsDiscovery.parentBundleID(of: "com.google.Chrome.helper"), "com.google.Chrome")
        XCTAssertEqual(RunningApplicationsDiscovery.parentBundleID(of: "com.apple.WebKit.GPU"), "com.apple.WebKit")
        XCTAssertEqual(RunningApplicationsDiscovery.parentBundleID(of: "com.apple.WebKit.WebContent"), "com.apple.WebKit")
        XCTAssertEqual(RunningApplicationsDiscovery.parentBundleID(of: "com.spotify.client"), "com.spotify.client")
        XCTAssertEqual(RunningApplicationsDiscovery.parentBundleID(of: "com.apple.Music"), "com.apple.Music")
    }

    func test_prettifyBundleID_returns_last_component() {
        XCTAssertEqual(RunningApplicationsDiscovery.prettifyBundleID("com.foo.MyApp"), "MyApp")
        XCTAssertEqual(RunningApplicationsDiscovery.prettifyBundleID("single"), "single")
    }
}
