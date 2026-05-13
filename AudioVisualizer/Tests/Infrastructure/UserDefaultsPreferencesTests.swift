import XCTest
import Domain
@testable import AudioVisualizer

final class UserDefaultsPreferencesTests: XCTestCase {
    func test_round_trip() {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let sut = UserDefaultsPreferences(defaults: defaults)
        var p = sut.load()
        p.lastScene = .alchemy
        p.lastSource = .process(pid: 123, bundleID: "com.example")
        p.lastPaletteName = "Aurora"
        sut.save(p)
        let r = sut.load()
        XCTAssertEqual(r.lastScene, .alchemy)
        XCTAssertEqual(r.lastSource, .process(pid: 123, bundleID: "com.example"))
        XCTAssertEqual(r.lastPaletteName, "Aurora")
    }

    func test_load_when_empty_returns_default() {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let sut = UserDefaultsPreferences(defaults: defaults)
        XCTAssertEqual(sut.load(), .default)
    }

    func test_round_trip_includes_language() {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let sut = UserDefaultsPreferences(defaults: defaults)
        var p = sut.load()
        p.lastLanguage = .es
        sut.save(p)
        XCTAssertEqual(sut.load().lastLanguage, .es)
    }
}
