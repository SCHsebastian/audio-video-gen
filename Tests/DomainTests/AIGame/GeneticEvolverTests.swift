import XCTest
@testable import Domain

final class GeneticEvolverTests: XCTestCase {
    private func g(_ values: [Float]) -> Genome { Genome(weights: values) }

    func test_crossover_produces_correct_length() {
        let a = g(Array(repeating: 0.5, count: Genome.expectedLength))
        let b = g(Array(repeating: -0.5, count: Genome.expectedLength))
        let r = TestRandomSource([0.1, 0.9, 0.1, 0.9])
        let child = GeneticEvolver.crossover(a, b, using: r)
        XCTAssertEqual(child.weights.count, Genome.expectedLength)
    }

    func test_crossover_picks_from_a_when_random_lt_half() {
        let a = g(Array(repeating: 1.0, count: Genome.expectedLength))
        let b = g(Array(repeating: -1.0, count: Genome.expectedLength))
        let r = TestRandomSource([0.0])     // always < 0.5 → always pick a
        let child = GeneticEvolver.crossover(a, b, using: r)
        XCTAssertEqual(child.weights.allSatisfy { $0 == 1.0 }, true)
    }

    func test_mutation_with_zero_rate_is_identity() {
        let original = g(Array(repeating: 0.3, count: Genome.expectedLength))
        let r = TestRandomSource([1.0])     // always >= rate → never mutate
        let mutated = GeneticEvolver.mutate(original, rate: 0.0, sigma: 0.25, using: r)
        XCTAssertEqual(mutated.weights, original.weights)
    }

    func test_mutation_clamps_to_bounds() {
        let original = g(Array(repeating: 1.99, count: Genome.expectedLength))
        // rate roll = 0 (mutate), gaussian = 1, sigma = 0.25 → +0.25 → clamp to 2.0
        let r = TestRandomSource([0.0])
        let mutated = GeneticEvolver.mutate(original, rate: 1.0, sigma: 0.25, using: r)
        XCTAssertTrue(mutated.weights.allSatisfy { $0 <= 2.0 && $0 >= -2.0 })
    }
}
