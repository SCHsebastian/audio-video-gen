import Foundation

public final class NeuralNetwork: @unchecked Sendable {
    public let w1: [Float]   // hidden × input  (row-major: hidden-major)
    public let b1: [Float]   // hidden
    public let w2: [Float]   // output × hidden
    public let b2: [Float]   // output

    public init(genome: Genome) throws {
        guard genome.weights.count == Genome.expectedLength else {
            throw AIGameError.invalidGenomeLength(
                expected: Genome.expectedLength, got: genome.weights.count
            )
        }
        let H = Genome.hiddenCount, I = Genome.inputCount, O = Genome.outputCount
        let w = genome.weights
        var i = 0
        self.w1 = Array(w[i..<i + H * I]); i += H * I
        self.b1 = Array(w[i..<i + H]);     i += H
        self.w2 = Array(w[i..<i + O * H]); i += O * H
        self.b2 = Array(w[i..<i + O])
    }

    /// Forward pass. `inputs.count` must equal `Genome.inputCount`.
    public func forward(_ inputs: [Float]) -> [Float] {
        precondition(inputs.count == Genome.inputCount)
        let H = Genome.hiddenCount, I = Genome.inputCount, O = Genome.outputCount
        var hidden = [Float](repeating: 0, count: H)
        for j in 0..<H {
            var s: Float = b1[j]
            for k in 0..<I { s += inputs[k] * w1[j * I + k] }
            hidden[j] = tanhf(s)
        }
        var out = [Float](repeating: 0, count: O)
        for j in 0..<O {
            var s: Float = b2[j]
            for k in 0..<H { s += hidden[k] * w2[j * H + k] }
            out[j] = 1.0 / (1.0 + expf(-s))
        }
        return out
    }
}
