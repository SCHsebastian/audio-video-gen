import XCTest
@testable import Domain

final class GenomeTests: XCTestCase {
    func test_expected_length_is_44() {
        // 6×4 W1 + 6 b1 + 2×6 W2 + 2 b2 = 44
        XCTAssertEqual(Genome.expectedLength, 44)
    }

    func test_random_genome_has_expected_length() {
        let r = TestRandomSource(Array(repeating: 0.5, count: 8))
        let g = Genome.random(using: r)
        XCTAssertEqual(g.weights.count, Genome.expectedLength)
    }

    func test_random_genome_values_are_in_minus_one_to_one() {
        let r = TestRandomSource(Array(repeating: 0.0, count: 4)) // → -1
        let g = Genome.random(using: r)
        XCTAssertTrue(g.weights.allSatisfy { $0 >= -1 && $0 < 1 })
    }
}
