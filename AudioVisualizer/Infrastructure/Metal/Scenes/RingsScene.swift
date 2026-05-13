import Metal
import Domain

/// Concentric ring-ripples. Each beat spawns a fresh ring at radius 0 that
/// expands outward and fades over `lifetime` seconds. Audio RMS lightly
/// scales the spawn rate so quiet passages get a slow drip and loud ones a
/// continuous shimmer. Rings auto-cap at MAX_RINGS to bound the per-fragment
/// loop in the shader.
final class RingsScene: VisualizerScene {
    private struct Ring {
        var radius: Float
        var alpha: Float
        var width: Float
        var paletteU: Float
        var age: Float
        var lifetime: Float
        var speed: Float
    }

    private static let maxRings = 32
    private var rings: [Ring] = []
    private var ambientTimer: Float = 0
    private var time: Float = 0
    private var rms: Float = 0

    private var pipeline: MTLRenderPipelineState!
    private var paletteTexture: MTLTexture!
    private var ringBuffer: MTLBuffer!         // GPU-side packed Ring{radius, alpha, width, paletteU}
    // Tunable look — `randomize()` rolls these.
    private var minSpeed: Float = 0.35
    private var maxSpeed: Float = 0.85
    private var ringWidth: Float = 0.040
    private var lifetimeBase: Float = 2.2

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
        // 4 floats per ring: { radius, alpha, width, paletteU }
        ringBuffer = device.makeBuffer(length: Self.maxRings * 4 * MemoryLayout<Float>.size,
                                       options: .storageModeShared)
    }

    func randomize() {
        // Roll a fresh feel: drift speed, ring thickness, and how long rings
        // linger before fading out.
        minSpeed = Float.random(in: 0.20...0.45)
        maxSpeed = Float.random(in: 0.60...1.10)
        ringWidth = Float.random(in: 0.022...0.060)
        lifetimeBase = Float.random(in: 1.6...3.2)
    }

    func update(spectrum: SpectrumFrame, waveform: [Float], beat: BeatEvent?, dt: Float) {
        time += dt
        rms = spectrum.rms

        // Spawn on every beat — bass strength chooses palette U so loud hits
        // pop into the warmer end of the palette.
        if let b = beat {
            spawn(strength: b.strength)
        }

        // Ambient drip — one quiet ring per ~700ms when audio is present.
        ambientTimer += dt
        let interval: Float = max(0.25, 0.7 - rms * 0.5)
        if ambientTimer >= interval {
            ambientTimer = 0
            if rms > 0.01 { spawn(strength: 0.20 + rms * 0.3) }
        }

        // Age each ring, drop dead ones.
        var i = 0
        while i < rings.count {
            rings[i].age += dt
            rings[i].radius += rings[i].speed * dt
            let t = rings[i].age / rings[i].lifetime
            rings[i].alpha = max(0, 1 - t * t)                  // ease-in fade
            rings[i].width = ringWidth * (1.0 + t * 1.4)        // thickens as it goes
            if rings[i].age >= rings[i].lifetime || rings[i].radius > 2.0 {
                rings.remove(at: i)
            } else {
                i += 1
            }
        }

        // Pack into GPU buffer (top maxRings only).
        let count = min(rings.count, Self.maxRings)
        let ptr = ringBuffer.contents().bindMemory(to: Float.self, capacity: Self.maxRings * 4)
        for j in 0..<count {
            let r = rings[j]
            ptr[j * 4 + 0] = r.radius
            ptr[j * 4 + 1] = r.alpha
            ptr[j * 4 + 2] = r.width
            ptr[j * 4 + 3] = r.paletteU
        }
        for j in count..<Self.maxRings {
            ptr[j * 4 + 0] = -1
            ptr[j * 4 + 1] = 0
            ptr[j * 4 + 2] = 0
            ptr[j * 4 + 3] = 0
        }
    }

    private func spawn(strength: Float) {
        if rings.count >= Self.maxRings { rings.removeFirst() }
        let speed = minSpeed + (maxSpeed - minSpeed) * Float.random(in: 0.6...1.4) * strength
        let life  = lifetimeBase + Float.random(in: -0.4...0.4)
        let u     = Float.random(in: 0.15...0.95)
        rings.append(Ring(
            radius: 0.04,
            alpha: 0.95,
            width: ringWidth,
            paletteU: u,
            age: 0,
            lifetime: max(0.6, life),
            speed: max(0.15, speed)))
    }

    func encode(into enc: MTLRenderCommandEncoder, uniforms: inout SceneUniforms) {
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBuffer(ringBuffer, offset: 0, index: 0)
        var u = (aspect: uniforms.aspect, time: time, count: Int32(min(rings.count, Self.maxRings)), rms: rms)
        enc.setFragmentBytes(&u, length: MemoryLayout.size(ofValue: u), index: 1)
        enc.setFragmentTexture(paletteTexture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
}
