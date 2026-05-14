import Foundation

public struct Genome: Equatable, Sendable {
    public static let inputCount  = 4
    public static let hiddenCount = 6
    public static let outputCount = 2
    public static let neuronBudget = 10
    public static let expectedLength =
        hiddenCount * inputCount      // W1
      + hiddenCount                   // b1
      + outputCount * hiddenCount     // W2
      + outputCount                   // b2

    public let weights: [Float]

    public init(weights: [Float]) { self.weights = weights }

    public static func random(using r: RandomSource) -> Genome {
        var w = [Float](); w.reserveCapacity(expectedLength)
        for _ in 0..<expectedLength { w.append(r.nextSigned()) }
        return Genome(weights: w)
    }
}
