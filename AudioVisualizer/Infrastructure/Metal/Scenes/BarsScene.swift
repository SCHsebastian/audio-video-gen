import Metal
import simd
import Domain
import VisualizerKernels

final class BarsScene: VisualizerScene {
    private var barCount = 64
    private var displayed = [Float](repeating: 0, count: 128)
    private var state = [Float](repeating: 0, count: 128)        // C++ smoothing state
    private var pipeline: MTLRenderPipelineState!
    private var heightsBuffer: MTLBuffer!
    private var paletteTexture: MTLTexture!
    private var beat: Float = 0

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
            length: 128 * MemoryLayout<Float>.size,
            options: .storageModeShared
        )
    }

    func randomize() {
        // Limited to the analyzer's band count (64) — higher would leave gaps.
        let options = [24, 32, 48, 64]
        let new = options.randomElement() ?? 64
        if new != barCount {
            barCount = new
            // Reset smoothing/display state so the previous count's tail doesn't bleed in.
            for i in 0..<state.count { state[i] = 0; displayed[i] = 0 }
        }
    }

    func update(spectrum: SpectrumFrame, waveform: [Float], beat: BeatEvent?, dt: Float) {
        let n = min(spectrum.bands.count, barCount)
        if let b = beat { self.beat = max(self.beat, b.strength) }
        self.beat *= 0.85
        let beatStrength = self.beat

        spectrum.bands.withUnsafeBufferPointer { inPtr in
            displayed.withUnsafeMutableBufferPointer { outPtr in
                state.withUnsafeMutableBufferPointer { statePtr in
                    vk_bars_process(inPtr.baseAddress, outPtr.baseAddress,
                                    statePtr.baseAddress, UInt32(n), dt, beatStrength)
                }
            }
        }
        memcpy(heightsBuffer.contents(), displayed, n * MemoryLayout<Float>.size)
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
