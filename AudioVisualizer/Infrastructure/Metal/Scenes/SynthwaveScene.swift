import Metal
import Domain

/// Procedural synthwave / Outrun horizon. Ray-plane intersection for the
/// floor + screen-space sun with scanline cutouts + beat flash, all from a
/// single fullscreen quad.
final class SynthwaveScene: VisualizerScene {
    private var pipeline: MTLRenderPipelineState!
    private var paletteTexture: MTLTexture!
    private var time: Float = 0
    private var rms: Float = 0
    private var bass: Float = 0
    private var beatEnv: Float = 0

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

    func update(spectrum: SpectrumFrame, waveform: WaveformBuffer, beat: BeatEvent?, dt: Float) {
        time += dt
        // Smooth rms (and bass) so percussive transients don't strobe the sun.
        let targetBass = spectrum.bands.prefix(6).reduce(0, +) / 6
        let aBass = 1.0 - expf(-dt / 0.10)
        let aRms  = 1.0 - expf(-dt / 0.05)
        bass += (targetBass - bass) * aBass
        rms  += (spectrum.rms - rms) * aRms

        if let b = beat { beatEnv = max(beatEnv, b.strength) }
        beatEnv *= expf(-dt / 0.180)
    }

    func encode(into enc: MTLRenderCommandEncoder, uniforms: inout SceneUniforms) {
        enc.setRenderPipelineState(pipeline)
        var u = (aspect: uniforms.aspect, time: time, rms: rms, bass: bass,
                 beat: beatEnv,
                 _pad0: Float(0), _pad1: Float(0), _pad2: Float(0))
        enc.setFragmentBytes(&u, length: MemoryLayout.size(ofValue: u), index: 1)
        enc.setFragmentTexture(paletteTexture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
}
