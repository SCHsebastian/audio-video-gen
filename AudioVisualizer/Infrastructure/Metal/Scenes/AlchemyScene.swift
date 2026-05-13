import Metal
import Domain

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
    private var simTime: Float = 0

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
        desc.colorAttachments[0].destinationRGBBlendFactor = .one    // additive
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
            let r = Float.random(in: 0..<0.6)
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
        // Split the spectrum into low / mid / high thirds for richer modulation.
        let lo = bandCount / 4                    // ~bass
        let hi = bandCount * 3 / 4
        let bassAvg = bandCount > 0 ? spectrum.bands.prefix(lo).reduce(0, +) / Float(max(1, lo)) : 0
        let midAvg = bandCount > 0 ? spectrum.bands[lo..<hi].reduce(0, +) / Float(max(1, hi - lo)) : 0
        let trebleAvg = bandCount > 0 ? spectrum.bands[hi..<bandCount].reduce(0, +) / Float(max(1, bandCount - hi)) : 0
        // Smooth (attack fast, release slower) so particles don't jitter.
        bass = max(bassAvg, bass * 0.88)
        mid = max(midAvg, mid * 0.85)
        treble = max(trebleAvg, treble * 0.80)
        if let b = beat { beatEnv = max(beatEnv, b.strength) }
        beatEnv *= 0.90
        simTime += dt
    }

    func encode(into enc: MTLRenderCommandEncoder, uniforms: inout SceneUniforms) {
        enc.setRenderPipelineState(renderPipeline)
        enc.setVertexBuffer(particles, offset: 0, index: 0)
        var au = AUniforms(bass: bass, mid: mid, treble: treble, beat: beatEnv,
                           dt: 0, aspect: uniforms.aspect, time: simTime, _pad: 0)
        enc.setVertexBytes(&au, length: MemoryLayout.size(ofValue: au), index: 1)
        enc.setFragmentTexture(paletteTexture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: particleCount)
    }

    func dispatchCompute(into cmd: MTLCommandBuffer, dt: Float, aspect: Float) {
        guard let enc = cmd.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(computePipeline)
        enc.setBuffer(particles, offset: 0, index: 0)
        var au = AUniforms(bass: bass, mid: mid, treble: treble, beat: beatEnv,
                           dt: dt, aspect: aspect, time: simTime, _pad: 0)
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
        var _pad: Float
    }
}
