import Metal
import Domain

/// Folded-polar kaleidoscope with N-fold mirror symmetry. `randomize()` picks
/// a fresh sector count (6/8/10/12) and rotation phase.
final class KaleidoscopeScene: VisualizerScene {
    private var pipeline: MTLRenderPipelineState!
    private var paletteTexture: MTLTexture!
    private var time: Float = 0
    private var rms: Float = 0
    private var bass: Float = 0
    private var sectors: Int32 = 8
    private var spin: Float = 0

    func build(device: MTLDevice, library: MTLLibrary, paletteTexture: MTLTexture) throws {
        self.paletteTexture = paletteTexture
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "kal_vertex")
        desc.fragmentFunction = library.makeFunction(name: "kal_fragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        desc.colorAttachments[0].isBlendingEnabled = false
        do { pipeline = try device.makeRenderPipelineState(descriptor: desc) }
        catch { throw RenderError.pipelineCreationFailed(name: "Kaleidoscope") }
    }

    func randomize() {
        sectors = Int32([6, 8, 10, 12].randomElement() ?? 8)
        spin = Float.random(in: 0..<(.pi * 2))
    }

    func update(spectrum: SpectrumFrame, waveform: [Float], beat: BeatEvent?, dt: Float) {
        time += dt
        rms = spectrum.rms
        let target = spectrum.bands.prefix(6).reduce(0, +) / 6
        bass += (target - bass) * 0.12
    }

    func encode(into enc: MTLRenderCommandEncoder, uniforms: inout SceneUniforms) {
        enc.setRenderPipelineState(pipeline)
        var u = (aspect: uniforms.aspect, time: time, rms: rms, bass: bass, sectors: sectors, spin: spin)
        enc.setFragmentBytes(&u, length: MemoryLayout.size(ofValue: u), index: 1)
        enc.setFragmentTexture(paletteTexture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
}
