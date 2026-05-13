import Metal
import Domain

/// Spectrum bars laid out around a circle. Same height-smoothing curve as
/// BarsScene (we reuse its band envelope) but rendered as a radial figure
/// from a single full-screen draw. Bar count is user-randomizable (24..96).
final class RadialScene: VisualizerScene {
    private var barCount: Int = 64
    private var displayed = [Float](repeating: 0, count: 96)
    private var pipeline: MTLRenderPipelineState!
    private var heightsBuffer: MTLBuffer!
    private var paletteTexture: MTLTexture!
    private var time: Float = 0
    private var rms: Float = 0

    func build(device: MTLDevice, library: MTLLibrary, paletteTexture: MTLTexture) throws {
        self.paletteTexture = paletteTexture
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "radial_vertex")
        desc.fragmentFunction = library.makeFunction(name: "radial_fragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        do { pipeline = try device.makeRenderPipelineState(descriptor: desc) }
        catch { throw RenderError.pipelineCreationFailed(name: "Radial") }
        heightsBuffer = device.makeBuffer(length: 96 * MemoryLayout<Float>.size, options: .storageModeShared)
    }

    func randomize() {
        let options = [24, 32, 48, 64, 80, 96]
        barCount = options.randomElement() ?? 64
        for i in 0..<displayed.count { displayed[i] = 0 }
    }

    func update(spectrum: SpectrumFrame, waveform: [Float], beat: BeatEvent?, dt: Float) {
        time += dt
        rms = spectrum.rms
        let n = min(barCount, spectrum.bands.count)
        // Per-band envelope: fast rise, slow fall. Independent of vk_bars_process
        // so this scene has its own personality.
        let rise: Float = 0.55
        let fall: Float = max(0.02, 1.0 - exp(-dt * 4.0))
        for i in 0..<n {
            let target = spectrum.bands[i]
            if target > displayed[i] {
                displayed[i] += (target - displayed[i]) * rise
            } else {
                displayed[i] += (target - displayed[i]) * fall
            }
        }
        // Repeat bands around the circle if barCount > bandCount.
        if barCount > n {
            for i in n..<barCount { displayed[i] = displayed[i % n] }
        }
        memcpy(heightsBuffer.contents(), displayed, barCount * MemoryLayout<Float>.size)
    }

    func encode(into enc: MTLRenderCommandEncoder, uniforms: inout SceneUniforms) {
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBuffer(heightsBuffer, offset: 0, index: 0)
        var u = (aspect: uniforms.aspect, time: time, barCount: Int32(barCount), rms: rms)
        enc.setFragmentBytes(&u, length: MemoryLayout.size(ofValue: u), index: 1)
        enc.setFragmentTexture(paletteTexture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
}
