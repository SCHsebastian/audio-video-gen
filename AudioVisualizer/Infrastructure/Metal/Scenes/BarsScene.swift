import Metal
import simd
import Domain

final class BarsScene: VisualizerScene {
    private let barCount = 64
    private var heights = [Float](repeating: 0, count: 64)
    private var displayed = [Float](repeating: 0, count: 64)
    private var pipeline: MTLRenderPipelineState!
    private var heightsBuffer: MTLBuffer!
    private var paletteTexture: MTLTexture!

    func build(device: MTLDevice, library: MTLLibrary, paletteTexture: MTLTexture) throws {
        self.paletteTexture = paletteTexture
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "bars_vertex")
        desc.fragmentFunction = library.makeFunction(name: "bars_fragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        do { pipeline = try device.makeRenderPipelineState(descriptor: desc) }
        catch { throw RenderError.pipelineCreationFailed(name: "Bars") }
        heightsBuffer = device.makeBuffer(
            length: barCount * MemoryLayout<Float>.size,
            options: .storageModeShared
        )
    }

    func update(spectrum: SpectrumFrame, waveform: [Float], beat: BeatEvent?, dt: Float) {
        let n = min(spectrum.bands.count, barCount)
        for i in 0..<n {
            let v = spectrum.bands[i]
            displayed[i] = max(v, displayed[i] * 0.88)
        }
        heights = displayed
        memcpy(heightsBuffer.contents(), heights, n * MemoryLayout<Float>.size)
    }

    func encode(into enc: MTLRenderCommandEncoder, uniforms: inout SceneUniforms) {
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(heightsBuffer, offset: 0, index: 0)
        var bu = (aspect: uniforms.aspect, time: uniforms.time, barCount: Int32(barCount))
        enc.setVertexBytes(&bu, length: MemoryLayout.size(ofValue: bu), index: 1)
        enc.setFragmentTexture(paletteTexture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: barCount)
    }
}
