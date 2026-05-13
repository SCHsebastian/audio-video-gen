import Metal
import Domain

/// GPU compute-shader particle scene driven by a curl-noise flow field.
/// Bass loosens the cloud (drag), mid changes the curl frequency, treble
/// shortens lifetimes (sparkle feel), beats deliver a one-shot radial
/// impulse. Velocity is capped so dense beat sequences can't fling particles
/// off-screen; drag is in per-second form so 60/120 Hz refresh rates match.
final class AlchemyScene: VisualizerScene {
    private let particleCount = 120_000
    private var particles: MTLBuffer!
    private var computePipeline: MTLComputePipelineState!
    private var renderPipeline: MTLRenderPipelineState!
    private var paletteTexture: MTLTexture!
    private var bass: Float = 0
    private var mid: Float = 0
    private var treble: Float = 0
    private var beatEnv: Float = 0
    private var beatTriggered: Bool = false
    private var simTime: Float = 0

    private var attractorSpeedX: Float = 0.55
    private var attractorSpeedY: Float = 0.71
    private var attractorAmpX: Float = 0.60
    private var attractorAmpY: Float = 0.50
    private var curlScale: Float = 1.6
    private var swirlBias: Float = 1.2
    private var hueShift: Float = 0

    func build(device: MTLDevice, library: MTLLibrary, paletteTexture: MTLTexture) throws {
        self.paletteTexture = paletteTexture
        guard let fn = library.makeFunction(name: "alchemy_update") else {
            throw RenderError.shaderCompilationFailed(name: "alchemy_update")
        }
        computePipeline = try device.makeComputePipelineState(function: fn)

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "alchemy_vertex")
        desc.fragmentFunction = library.makeFunction(name: "alchemy_fragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .one
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .one
        do { renderPipeline = try device.makeRenderPipelineState(descriptor: desc) }
        catch { throw RenderError.pipelineCreationFailed(name: "Alchemy") }

        struct Particle { var pos: SIMD2<Float>; var vel: SIMD2<Float>; var life: Float; var seed: Float }
        var initial = [Particle](repeating: .init(pos: .zero, vel: .zero, life: 0, seed: 0), count: particleCount)
        for i in 0..<particleCount {
            let seed = Float.random(in: 0..<1)
            let a = seed * 2 * .pi
            let r = Float.random(in: 0.2..<0.9)
            initial[i].seed = seed
            initial[i].life = Float.random(in: 0..<1)
            initial[i].pos = SIMD2(cos(a), sin(a)) * r
            initial[i].vel = SIMD2(-sin(a), cos(a)) * Float.random(in: 0.1..<0.4)
        }
        particles = device.makeBuffer(bytes: initial,
                                      length: particleCount * MemoryLayout<Particle>.stride,
                                      options: .storageModeShared)
    }

    func update(spectrum: SpectrumFrame, waveform: [Float], beat: BeatEvent?, dt: Float) {
        let bandCount = spectrum.bands.count
        // Explicit bass/mid/treble ranges — match the spec, not bandCount/4.
        let bassEnd = min(8, bandCount)
        let midStart = min(8, bandCount - 1)
        let midEnd   = min(32, bandCount)
        let hiStart  = min(32, bandCount - 1)
        let hiEnd    = bandCount
        let bassAvg = bandCount > 0 ? spectrum.bands.prefix(bassEnd).reduce(0, +) / Float(bassEnd) : 0
        let midAvg = (midStart..<midEnd).reduce(Float(0)) { $0 + spectrum.bands[$1] } / Float(max(1, midEnd - midStart))
        let trebAvg = (hiStart..<hiEnd).reduce(Float(0)) { $0 + spectrum.bands[$1] } / Float(max(1, hiEnd - hiStart))
        bass   = max(bassAvg, bass * 0.88)
        mid    = max(midAvg,  mid  * 0.85)
        treble = max(trebAvg, treble * 0.80)

        // Beat: triggered only on the frame the event arrives; envelope decays.
        beatTriggered = false
        if let b = beat {
            beatEnv = max(beatEnv, b.strength)
            beatTriggered = true
        }
        beatEnv *= expf(-dt / 0.150)
        simTime += dt
    }

    func randomize() {
        attractorSpeedX = Float.random(in: 0.4...1.1)
        attractorSpeedY = Float.random(in: 0.4...1.1)
        if abs(attractorSpeedX - attractorSpeedY) < 0.1 { attractorSpeedY += 0.25 }
        attractorAmpX = Float.random(in: 0.40...0.70)
        attractorAmpY = Float.random(in: 0.35...0.60)
        curlScale = Float.random(in: 1.0...3.0)
        swirlBias = Float.random(in: 0.7...1.6)
        hueShift = Float.random(in: 0..<1)
    }

    func encode(into enc: MTLRenderCommandEncoder, uniforms: inout SceneUniforms) {
        enc.setRenderPipelineState(renderPipeline)
        enc.setVertexBuffer(particles, offset: 0, index: 0)
        var au = uniformBuffer(dt: 0, aspect: uniforms.aspect)
        enc.setVertexBytes(&au, length: MemoryLayout.size(ofValue: au), index: 1)
        enc.setFragmentTexture(paletteTexture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: particleCount)
    }

    func dispatchCompute(into cmd: MTLCommandBuffer, dt: Float, aspect: Float) {
        guard let enc = cmd.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(computePipeline)
        enc.setBuffer(particles, offset: 0, index: 0)
        var au = uniformBuffer(dt: dt, aspect: aspect)
        enc.setBytes(&au, length: MemoryLayout.size(ofValue: au), index: 1)
        let tg = MTLSize(width: computePipeline.threadExecutionWidth, height: 1, depth: 1)
        let grid = MTLSize(width: particleCount, height: 1, depth: 1)
        enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
        enc.endEncoding()
    }

    private struct AUniforms {
        var bass: Float
        var mid: Float
        var treble: Float
        var beat: Float
        var dt: Float
        var aspect: Float
        var time: Float
        var attractorSpeedX: Float
        var attractorSpeedY: Float
        var attractorAmpX: Float
        var attractorAmpY: Float
        var curlScale: Float
        var swirlBias: Float
        var hueShift: Float
        var beatTriggered: Float = 0
        var _pad1: Float = 0
    }

    private func uniformBuffer(dt: Float, aspect: Float) -> AUniforms {
        AUniforms(bass: bass, mid: mid, treble: treble, beat: beatEnv,
                  dt: dt, aspect: aspect, time: simTime,
                  attractorSpeedX: attractorSpeedX, attractorSpeedY: attractorSpeedY,
                  attractorAmpX: attractorAmpX, attractorAmpY: attractorAmpY,
                  curlScale: curlScale, swirlBias: swirlBias, hueShift: hueShift,
                  beatTriggered: beatTriggered ? 1.0 : 0.0)
    }
}
