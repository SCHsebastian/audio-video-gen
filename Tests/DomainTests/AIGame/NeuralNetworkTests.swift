import XCTest
@testable import Domain

final class NeuralNetworkTests: XCTestCase {
    func test_neuron_budget_within_10() {
        XCTAssertLessThanOrEqual(Genome.hiddenCount + Genome.outputCount, Genome.neuronBudget)
    }

    func test_throws_on_wrong_genome_length() {
        XCTAssertThrowsError(try NeuralNetwork(genome: Genome(weights: [0, 0, 0]))) { err in
            guard case AIGameError.invalidGenomeLength(let exp, let got) = err else {
                return XCTFail("wrong error type: \(err)")
            }
            XCTAssertEqual(exp, Genome.expectedLength)
            XCTAssertEqual(got, 3)
        }
    }

    func test_forward_outputs_in_unit_range() throws {
        let zeros = Array(repeating: Float.zero, count: Genome.expectedLength)
        let nn = try NeuralNetwork(genome: Genome(weights: zeros))
        let out = nn.forward([1, -1, 0.5, -0.5])
        XCTAssertEqual(out.count, Genome.outputCount)
        for o in out {
            XCTAssertGreaterThanOrEqual(o, 0)
            XCTAssertLessThanOrEqual(o, 1)
        }
    }

    func test_forward_is_deterministic_for_fixed_genome() throws {
        let weights = (0..<Genome.expectedLength).map { Float($0) * 0.01 - 0.2 }
        let nn = try NeuralNetwork(genome: Genome(weights: weights))
        let inputs: [Float] = [0.3, -0.7, 0.1, 0.9]
        XCTAssertEqual(nn.forward(inputs), nn.forward(inputs))
    }

    func test_zero_genome_outputs_half() throws {
        // tanh(0) = 0 in hidden, then sigmoid(0) = 0.5 at output.
        let zeros = Array(repeating: Float.zero, count: Genome.expectedLength)
        let nn = try NeuralNetwork(genome: Genome(weights: zeros))
        let out = nn.forward([0.7, -0.2, 0.4, -0.1])
        for o in out { XCTAssertEqual(o, 0.5, accuracy: 1e-6) }
    }
}
