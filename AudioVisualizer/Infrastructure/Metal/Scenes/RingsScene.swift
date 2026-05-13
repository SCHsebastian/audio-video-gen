import Metal
import Domain

/// Sonar-ping rings. Each beat spawns a fresh ring at birth-time; radius is
/// computed as `(time - birth) * speed` (no CPU integration drift). Intensity
/// fades exponentially in time AND with `1/r` so young rings read as hotter.
/// Idle continuous spawn at 0.5 Hz keeps the screen alive in silence.
final class RingsScene: VisualizerScene {
    private struct Ring {
        var birthTime: Float
        var speed: Float
        var intensity: Float    // initial intensity, scaled by beat strength
        var paletteU: Float     // 0..1, golden-ratio shuffled
        var lifetime: Float
    }

    private static let maxRings = 16
    private var slots: [Ring?] = Array(repeating: nil, count: 16)
    private var spawnCounter: Int = 0
    private var lastBeatTime: Float = -10
    private var idleAccum: Float = 0
    private var time: Float = 0
    private var rms: Float = 0
    private var bass: Float = 0
    private var treble: Float = 0

    private var pipeline: MTLRenderPipelineState!
    private var paletteTexture: MTLTexture!
    private var ringBuffer: MTLBuffer!

    // Look knobs — `randomize()` rolls these.
    private var speedBase: Float = 0.55
    private var tau: Float = 1.2
    private var bassWarpAmp: Float = 0.020

    func build(device: MTLDevice, library: MTLLibrary, paletteTexture: MTLTexture) throws {
        self.paletteTexture = paletteTexture
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "rings_vertex")
        desc.fragmentFunction = library.makeFunction(name: "rings_fragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        do { pipeline = try device.makeRenderPipelineState(descriptor: desc) }
        catch { throw RenderError.pipelineCreationFailed(name: "Rings") }
        ringBuffer = device.makeBuffer(length: Self.maxRings * 4 * MemoryLayout<Float>.size,
                                       options: .storageModeShared)
    }

    func randomize() {
        speedBase    = Float.random(in: 0.35...0.80)
        tau          = Float.random(in: 0.9...1.8)
        bassWarpAmp  = Float.random(in: 0.012...0.030)
    }

    func update(spectrum: SpectrumFrame, waveform: [Float], beat: BeatEvent?, dt: Float) {
        time += dt
        rms = spectrum.rms

        let bands = spectrum.bands
        let n = max(1, bands.count)
        let bassEnd = min(5, n)
        let trebStart = min(48, n - 1)
        let trebEnd  = n
        let bassTgt = bands.prefix(bassEnd).reduce(0, +) / Float(bassEnd)
        let trebTgt = (trebStart..<trebEnd).reduce(Float(0)) { $0 + bands[$1] }
                    / Float(max(1, trebEnd - trebStart))
        bass   += (bassTgt - bass)   * (1.0 - expf(-dt / 0.10))
        treble += (trebTgt - treble) * (1.0 - expf(-dt / 0.04))

        // Beat-driven spawn.
        if let b = beat {
            spawn(strength: 0.35 + 0.65 * b.strength)
            lastBeatTime = time
            idleAccum = 0
        }

        // Idle continuous spawn — only after a quiet stretch with no beats.
        let idleGap: Float = 1.5
        let idleHz: Float = 0.5
        if time - lastBeatTime > idleGap && rms < 0.02 {
            idleAccum += dt
            if idleAccum >= 1.0 / idleHz {
                idleAccum = 0
                spawn(strength: 0.20)
            }
        } else {
            idleAccum = 0
        }

        // Repack slots into the GPU buffer.
        let ptr = ringBuffer.contents().bindMemory(to: Float.self, capacity: Self.maxRings * 4)
        for j in 0..<Self.maxRings {
            if let r = slots[j] {
                let age = time - r.birthTime
                if age > r.lifetime {
                    slots[j] = nil
                    ptr[j * 4 + 0] = -1
                    ptr[j * 4 + 1] = 0
                    ptr[j * 4 + 2] = 0
                    ptr[j * 4 + 3] = 0
                    continue
                }
                let radius = age * r.speed
                // Two-component fade: exp(-age/tau) * R0/(r+R0) (1/r shockwave).
                let ringR0: Float = 0.05
                let intensity = r.intensity
                    * expf(-age / tau)
                    * (ringR0 / (radius + ringR0))
                // Width grows over age — wave packet shimmer.
                let width: Float = 0.004 + age * 0.010
                let phase = r.paletteU * 2.0 * .pi
                ptr[j * 4 + 0] = radius
                ptr[j * 4 + 1] = intensity
                ptr[j * 4 + 2] = width
                ptr[j * 4 + 3] = phase
            } else {
                ptr[j * 4 + 0] = -1
                ptr[j * 4 + 1] = 0
                ptr[j * 4 + 2] = 0
                ptr[j * 4 + 3] = 0
            }
        }
    }

    private func spawn(strength: Float) {
        // Pick the empty slot, or recycle the oldest live ring.
        var pickIdx = -1
        var oldestBirth: Float = .infinity
        for j in 0..<Self.maxRings {
            if slots[j] == nil { pickIdx = j; break }
            if let r = slots[j], r.birthTime < oldestBirth {
                oldestBirth = r.birthTime
                pickIdx = j
            }
        }
        if pickIdx < 0 { return }

        // Golden-ratio palette shuffle so consecutive rings get visibly
        // distinct hues without random clumping.
        spawnCounter &+= 1
        let palU = (Float(spawnCounter) * 0.6180339).truncatingRemainder(dividingBy: 1)
        let speed = speedBase * Float.random(in: 0.85...1.15)
        slots[pickIdx] = Ring(birthTime: time,
                              speed: max(0.10, speed),
                              intensity: max(0.10, min(1.0, strength)),
                              paletteU: palU,
                              lifetime: 3.0)
    }

    func encode(into enc: MTLRenderCommandEncoder, uniforms: inout SceneUniforms) {
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBuffer(ringBuffer, offset: 0, index: 0)
        var u = RU(aspect: uniforms.aspect, time: time, ringCount: Int32(Self.maxRings),
                   rms: rms, bass: bass, treble: treble, _pad0: 0, _pad1: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout.size(ofValue: u), index: 1)
        enc.setFragmentTexture(paletteTexture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private struct RU {
        var aspect: Float
        var time: Float
        var ringCount: Int32
        var rms: Float
        var bass: Float
        var treble: Float
        var _pad0: Float
        var _pad1: Float
    }
}
