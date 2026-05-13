import XCTest
@testable import Application
@testable import Domain

final class ListAudioSourcesUseCaseTests: XCTestCase {
    func test_returns_systemWide_plus_discovered_processes() async throws {
        let fake = FakeProcessDiscovering()
        fake.stub = [
            AudioProcessInfo(pid: 100, bundleID: "com.spotify.client", displayName: "Spotify", isProducingAudio: true)
        ]
        let sut = ListAudioSourcesUseCase(discovery: fake)
        let result = try await sut.execute()
        XCTAssertEqual(result.first, .systemWide)
        XCTAssertEqual(result.count, 2)
        if case let .process(pid, bid) = result[1] {
            XCTAssertEqual(pid, 100); XCTAssertEqual(bid, "com.spotify.client")
        } else { XCTFail("expected process source") }
    }

    func test_propagates_discovery_error() async {
        let fake = FakeProcessDiscovering()
        fake.error = CaptureError.permissionDenied
        let sut = ListAudioSourcesUseCase(discovery: fake)
        do {
            _ = try await sut.execute()
            XCTFail("expected throw")
        } catch let e as CaptureError {
            XCTAssertEqual(e, .permissionDenied)
        } catch { XCTFail("wrong error type") }
    }
}
