import Foundation

public enum GeneticEvolver {
    /// Per-gene 50/50 uniform crossover.
    public static func crossover(_ a: Genome, _ b: Genome, using r: RandomSource) -> Genome {
        precondition(a.weights.count == b.weights.count)
        var w = [Float](); w.reserveCapacity(a.weights.count)
        for i in 0..<a.weights.count {
            w.append(r.nextUnit() < 0.5 ? a.weights[i] : b.weights[i])
        }
        return Genome(weights: w)
    }

    /// Per-gene mutation: with probability `rate`, add N(0, sigma); clamp to ±2.
    public static func mutate(_ g: Genome, rate: Float, sigma: Float,
                              using r: RandomSource) -> Genome {
        var w = g.weights
        for i in 0..<w.count {
            if r.nextUnit() < rate {
                let delta = r.nextGaussian() * sigma
                w[i] = max(-2, min(2, w[i] + delta))
            }
        }
        return Genome(weights: w)
    }
}
