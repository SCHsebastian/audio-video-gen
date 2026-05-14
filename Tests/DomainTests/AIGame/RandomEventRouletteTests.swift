import XCTest
@testable import Domain

final class RandomEventRouletteTests: XCTestCase {
    func test_pick_returns_first_event_when_unit_is_zero() {
        let r = TestRandomSource([0.0])
        XCTAssertEqual(RandomEventRoulette.pick(using: r), AIGameEvent.allCases[0])
    }

    func test_pick_covers_all_events_for_uniform_input() {
        var seen = Set<AIGameEvent>()
        let count = AIGameEvent.allCases.count
        for k in 0..<count {
            // Map midpoint of each bucket to its event.
            let u = (Float(k) + 0.5) / Float(count)
            let r = TestRandomSource([u])
            seen.insert(RandomEventRoulette.pick(using: r))
        }
        XCTAssertEqual(seen, Set(AIGameEvent.allCases))
    }
}
