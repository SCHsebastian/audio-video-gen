import Foundation

public final class World {
    public static let terrainSampleCount = 256
    public static let terrainStrideX: Float = 0.05    // world units per sample

    public let seed: UInt64
    private let source: RandomSource

    public private(set) var cameraX: Float = 0
    public private(set) var obstacles: [Obstacle] = []
    private var samples: [Float] = []                 // y values, length = terrainSampleCount
    private var ringStart: Int = 0                    // index of leftmost sample

    /// Last spawn world-x; used to enforce min spacing in `ObstacleSpawner`.
    public internal(set) var lastSpawnX: Float = -.infinity

    public init(seed: UInt64, source: RandomSource) {
        self.seed = seed; self.source = source
        self.samples = (0..<Self.terrainSampleCount).map { i in
            Self.heightAt(worldX: Float(i) * Self.terrainStrideX, seed: seed, bass: 0)
        }
    }

    public func advance(dt: Float, audio: AudioDrive) {
        let scroll = 4.0 * (1.0 + 0.5 * audio.bass)
        cameraX += scroll * dt

        // Roll the ring forward to keep the window covering [cameraX - 0.4, +∞).
        let leftEdgeWorldX = cameraX - 0.4
        let leftIndexF = leftEdgeWorldX / Self.terrainStrideX
        let desiredLeftIndex = Int(floorf(leftIndexF))
        let currentLeftIndex = baseIndex
        let shift = desiredLeftIndex - currentLeftIndex
        if shift > 0 {
            for k in 0..<shift {
                let newWorldIndex = currentLeftIndex + Self.terrainSampleCount + k
                let x = Float(newWorldIndex) * Self.terrainStrideX
                samples[(ringStart + k) % Self.terrainSampleCount] =
                    Self.heightAt(worldX: x, seed: seed, bass: audio.bass)
            }
            ringStart = (ringStart + shift) % Self.terrainSampleCount
        }

        pruneObstacles()
        spawnIfBeat(audio)
    }

    private var baseIndex: Int { Int(floorf((cameraX - 0.4) / Self.terrainStrideX)) - 0 }
    // baseIndex is computed identically to leftIndex above for clarity in tests.

    public func terrainSamples() -> [TerrainSample] {
        var out = [TerrainSample](); out.reserveCapacity(Self.terrainSampleCount)
        for i in 0..<Self.terrainSampleCount {
            let worldIndex = baseIndex + i
            let x = Float(worldIndex) * Self.terrainStrideX
            let y = samples[(ringStart + i) % Self.terrainSampleCount]
            out.append(TerrainSample(x: x, y: y))
        }
        return out
    }

    public func groundY(atWorldX wx: Float) -> Float {
        let f = wx / Self.terrainStrideX
        let i0 = Int(floorf(f))
        let t = f - Float(i0)
        let y0 = sampleY(worldIndex: i0)
        let y1 = sampleY(worldIndex: i0 + 1)
        return y0 + (y1 - y0) * t
    }

    private func sampleY(worldIndex: Int) -> Float {
        let rel = worldIndex - baseIndex
        if rel < 0 || rel >= Self.terrainSampleCount {
            // Outside ring: synthesize on the fly (silence-bass) — only used
            // by collision queries on the very leading edge.
            return Self.heightAt(worldX: Float(worldIndex) * Self.terrainStrideX,
                                 seed: seed, bass: 0)
        }
        return samples[(ringStart + rel) % Self.terrainSampleCount]
    }

    // MARK: deterministic value-noise

    static func heightAt(worldX: Float, seed: UInt64, bass: Float) -> Float {
        let baseline: Float = -0.55
        let n1 = noise1D(worldX * 0.6, seed: seed &+ 1) * 0.18
        let n2 = noise1D(worldX * 1.7, seed: seed &+ 2) * 0.06
        let bassRoll = bass * sinf(worldX * 0.9) * 0.18
        return baseline + n1 + n2 + bassRoll
    }

    private static func noise1D(_ x: Float, seed: UInt64) -> Float {
        let i = Int(floorf(x))
        let t = x - Float(i)
        let u = t * t * (3 - 2 * t)
        let a = hashUnitSigned(i, seed: seed)
        let b = hashUnitSigned(i + 1, seed: seed)
        return a + (b - a) * u
    }

    private static func hashUnitSigned(_ i: Int, seed: UInt64) -> Float {
        var h: UInt64 = UInt64(bitPattern: Int64(i)) &+ seed
        h ^= (h >> 33); h = h &* 0xff51afd7ed558ccd
        h ^= (h >> 33); h = h &* 0xc4ceb9fe1a85ec53
        h ^= (h >> 33)
        let unit = Float(h % 1_000_000) / 1_000_000.0
        return unit * 2 - 1
    }

    // MARK: obstacles (filled in Task 2.2)

    fileprivate func pruneObstacles() {
        obstacles.removeAll { $0.xEnd < cameraX - 1.6 }
    }

    fileprivate func spawnIfBeat(_ audio: AudioDrive) {
        // Implemented in Task 2.2.
    }
}
