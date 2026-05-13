import Metal
import Domain

/// Milkdrop / Winamp tribute (procedural). Two layers of fbm domain warp plus
/// a swirling rotation driven by bass — same vibe as classic Milkdrop presets
/// but cheap enough to run on the same single-draw budget as the rest of the
/// scenes. `randomize()` jitters the swirl phase and warp depth.
final class MilkdropScene: VisualizerScene {
    private var pipeline: MTLRenderPipelineState!
    private var paletteTexture: MTLTexture!
    private var time: Float = 0
    private var rms: Float = 0
    private var bass: Float = 0
    private var warp: Float = 0.6
    private var swirl: Float = 0.0

    func build(device: MTLDevice, library: MTLLibrary, paletteTexture: MTLTexture) throws {
        self.paletteTexture = paletteTexture
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "md_vertex")
        desc.fragmentFunction = library.makeFunction(name: "md_fragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        desc.colorAttachments[0].isBlendingEnabled = false
        do { pipeline = try device.makeRenderPipelineState(descriptor: desc) }
        catch { throw RenderError.pipelineCreationFailed(name: "Milkdrop") }
    }

    func randomize() {
        warp  = Float.random(in: 0.3...1.2)
        swirl = Float.random(in: 0..<(.pi * 2))
    }

    func update(spectrum: SpectrumFrame, waveform: [Float], beat: BeatEvent?, dt: Float) {
        time += dt
        rms = spectrum.rms
        let target = spectrum.bands.prefix(6).reduce(0, +) / 6
        bass += (target - bass) * 0.12
    }

    func encode(into enc: MTLRenderCommandEncoder, uniforms: inout SceneUniforms) {
        enc.setRenderPipelineState(pipeline)
        var u = (aspect: uniforms.aspect, time: time, rms: rms, bass: bass, warp: warp, swirl: swirl)
        enc.setFragmentBytes(&u, length: MemoryLayout.size(ofValue: u), index: 1)
        enc.setFragmentTexture(paletteTexture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
}
