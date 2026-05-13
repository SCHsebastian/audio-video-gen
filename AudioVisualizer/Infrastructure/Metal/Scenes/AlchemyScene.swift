import Metal
import Domain

final class AlchemyScene: VisualizerScene {
    private let particleCount = 80_000
    private var particles: MTLBuffer!
    private var computePipeline: MTLComputePipelineState!
    private var renderPipeline: MTLRenderPipelineState!
    private var paletteTexture: MTLTexture!
    private var lastBass: Float = 0
    private var beatBoost: Float = 0
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
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .one
        do { renderPipeline = try device.makeRenderPipelineState(descriptor: desc) }
        catch { throw RenderError.pipelineCreationFailed(name: "Alchemy") }

        struct Particle { var pos: SIMD2<Float>; var vel: SIMD2<Float>; var life: Float; var seed: Float }
        var initial = [Particle](repeating: .init(pos: .zero, vel: .zero, life: 0, seed: 0), count: particleCount)
        for i in 0..<particleCount {
            initial[i].seed = Float.random(in: 0..<1)
            initial[i].life = Float.random(in: 0..<1)
            let a = initial[i].seed * 2 * .pi
            initial[i].vel = SIMD2(cos(a), sin(a)) * 0.2
        }
        particles = device.makeBuffer(bytes: initial,
                                      length: particleCount * MemoryLayout<Particle>.stride,
                                      options: .storageModeShared)
    }

    func update(spectrum: SpectrumFrame, waveform: [Float], beat: BeatEvent?, dt: Float) {
        let bass = spectrum.bands.prefix(8).reduce(0, +) / 8
        lastBass = bass + beatBoost
        if let b = beat { beatBoost = max(beatBoost, b.strength * 0.5) }
        beatBoost *= 0.85
        simTime += dt
    }

    func encode(into enc: MTLRenderCommandEncoder, uniforms: inout SceneUniforms) {
        enc.setRenderPipelineState(renderPipeline)
        enc.setVertexBuffer(particles, offset: 0, index: 0)
        var au = (bass: lastBass, dt: Float(0), aspect: uniforms.aspect, time: simTime)
        enc.setVertexBytes(&au, length: MemoryLayout.size(ofValue: au), index: 1)
        enc.setFragmentTexture(paletteTexture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: particleCount)
    }

    // Public for the driver to dispatch compute before encoding render.
    func dispatchCompute(into cmd: MTLCommandBuffer, dt: Float, aspect: Float) {
        guard let enc = cmd.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(computePipeline)
        enc.setBuffer(particles, offset: 0, index: 0)
        var au = (bass: lastBass, dt: dt, aspect: aspect, time: simTime)
        enc.setBytes(&au, length: MemoryLayout.size(ofValue: au), index: 1)
        let tg = MTLSize(width: computePipeline.threadExecutionWidth, height: 1, depth: 1)
        let grid = MTLSize(width: particleCount, height: 1, depth: 1)
        enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
        enc.endEncoding()
    }
}
