import Metal
import Domain
import VisualizerKernels

final class LissajousScene: VisualizerScene {
    private let pointCount: Int = 2048
    private var pointsBuffer: MTLBuffer!
    private var pipeline: MTLRenderPipelineState!
    private var paletteTexture: MTLTexture!
    private var time: Float = 0
    private var rms: Float = 0
    private var bass: Float = 0
    private var alternate: Bool = false
    private var swapTimer: Float = 0

    func build(device: MTLDevice, library: MTLLibrary, paletteTexture: MTLTexture) throws {
        self.paletteTexture = paletteTexture
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "lissajous_vertex")
        desc.fragmentFunction = library.makeFunction(name: "lissajous_fragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .one
        do { pipeline = try device.makeRenderPipelineState(descriptor: desc) }
        catch { throw RenderError.pipelineCreationFailed(name: "Lissajous") }
        pointsBuffer = device.makeBuffer(length: pointCount * MemoryLayout<SIMD2<Float>>.size,
                                         options: .storageModeShared)
    }

    func update(spectrum: SpectrumFrame, waveform: [Float], beat: BeatEvent?, dt: Float) {
        time += dt
        rms = spectrum.rms
        bass = spectrum.bands.prefix(8).reduce(0, +) / 8
        swapTimer += dt
        if let b = beat, b.strength > 0.6, swapTimer > 0.4 {
            alternate.toggle()
            swapTimer = 0
        }
        let ptr = pointsBuffer.contents().bindMemory(to: Float.self, capacity: pointCount * 2)
        if alternate {
            let petals: Int32 = 5 + Int32(min(3.0, bass * 30))
            vk_rose(ptr, UInt32(pointCount), time, petals, rms)
        } else {
            let a: Float = 3 + bass * 6
            let b: Float = 2 + rms * 5
            let delta = sin(time * 0.4) * .pi
            vk_lissajous(ptr, UInt32(pointCount), time, a, b, delta, rms)
        }
    }

    func encode(into enc: MTLRenderCommandEncoder, uniforms: inout SceneUniforms) {
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(pointsBuffer, offset: 0, index: 0)
        var count = UInt32(pointCount)
        enc.setVertexBytes(&count, length: 4, index: 1)
        // Outer glow pass — thick, dim.
        var glow = (thickness: Float(0.018 + rms * 0.030),
                    aspect: uniforms.aspect,
                    time: time,
                    intensity: Float(0.18 + min(0.30, rms * 1.6)))
        enc.setVertexBytes(&glow, length: MemoryLayout.size(ofValue: glow), index: 2)
        enc.setFragmentBytes(&glow, length: MemoryLayout.size(ofValue: glow), index: 0)
        enc.setFragmentTexture(paletteTexture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: pointCount - 1)
        // Crisp core pass.
        var core = (thickness: Float(0.005 + rms * 0.010),
                    aspect: uniforms.aspect,
                    time: time,
                    intensity: Float(0.85 + min(0.6, rms * 3)))
        enc.setVertexBytes(&core, length: MemoryLayout.size(ofValue: core), index: 2)
        enc.setFragmentBytes(&core, length: MemoryLayout.size(ofValue: core), index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: pointCount - 1)
    }
}
