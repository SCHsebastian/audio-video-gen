import Metal
import Domain

/// Procedural synthwave / vaporwave horizon. No mesh, no compute — the
/// fragment shader resolves the sun + perspective grid in screen space from a
/// single full-screen quad and a tiny uniform block.
final class SynthwaveScene: VisualizerScene {
    private var pipeline: MTLRenderPipelineState!
    private var paletteTexture: MTLTexture!
    private var time: Float = 0
    private var rms: Float = 0
    private var bass: Float = 0

    func build(device: MTLDevice, library: MTLLibrary, paletteTexture: MTLTexture) throws {
        self.paletteTexture = paletteTexture
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "synth_vertex")
        desc.fragmentFunction = library.makeFunction(name: "synth_fragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        desc.colorAttachments[0].isBlendingEnabled = false
        do { pipeline = try device.makeRenderPipelineState(descriptor: desc) }
        catch { throw RenderError.pipelineCreationFailed(name: "Synthwave") }
    }

    func update(spectrum: SpectrumFrame, waveform: [Float], beat: BeatEvent?, dt: Float) {
        time += dt
        rms = spectrum.rms
        // Smooth bass to avoid epileptic grid speed-up on transients.
        let target = spectrum.bands.prefix(6).reduce(0, +) / 6
        bass += (target - bass) * 0.10
    }

    func encode(into enc: MTLRenderCommandEncoder, uniforms: inout SceneUniforms) {
        enc.setRenderPipelineState(pipeline)
        var u = (aspect: uniforms.aspect, time: time, rms: rms, bass: bass)
        enc.setFragmentBytes(&u, length: MemoryLayout.size(ofValue: u), index: 1)
        enc.setFragmentTexture(paletteTexture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
}
