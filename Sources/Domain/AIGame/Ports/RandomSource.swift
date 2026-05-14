// Sources/Domain/AIGame/Ports/RandomSource.swift
import Foundation

/// Pluggable PRNG so tests can inject a deterministic stream and
/// `Population` / `World` stay pure-Swift testable.
public protocol RandomSource: AnyObject {
    /// Uniform Float in [0, 1).
    func nextUnit() -> Float
    /// Uniform Float in [-1, 1).
    func nextSigned() -> Float
    /// Standard-normal Float (Box–Muller).
    func nextGaussian() -> Float
}

/// Production default. Backed by `SystemRandomNumberGenerator`.
public final class SystemRandomSource: RandomSource {
    private var rng = SystemRandomNumberGenerator()
    public init() {}
    public func nextUnit() -> Float { Float.random(in: 0..<1, using: &rng) }
    public func nextSigned() -> Float { Float.random(in: -1..<1, using: &rng) }
    public func nextGaussian() -> Float {
        let u1 = max(Float.leastNonzeroMagnitude, nextUnit())
        let u2 = nextUnit()
        return sqrtf(-2 * logf(u1)) * cosf(2 * .pi * u2)
    }
}
