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
}
