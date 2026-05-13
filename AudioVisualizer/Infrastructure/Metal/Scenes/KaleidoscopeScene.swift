import Metal
import Domain

/// N-fold mirror kaleidoscope (mandala). Bass squeezes the noise field, mid
/// drives rotation rate, treble adds grain, beats flash and briefly double N.
final class KaleidoscopeScene: VisualizerScene {
    private var pipeline: MTLRenderPipelineState!
    private var paletteTexture: MTLTexture!
    private var time: Float = 0
    private var rms: Float = 0
    private var bass: Float = 0
    private var mid: Float = 0
    private var treble: Float = 0
    private var centroid: Float = 0
    private var beatEnv: Float = 0
    private var rotate: Float = 0
    private var sectors: Int32 = 8

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
        rotate = Float.random(in: 0..<(.pi * 2))
    }

    func update(spectrum: SpectrumFrame, waveform: WaveformBuffer, beat: BeatEvent?, dt: Float) {
        time += dt
        rms = spectrum.rms

        // τ-stable smoothing of the analyzer's centralised sub-bands and the
        // spectral centroid (used to bias rotation direction by tonal centre).
        bass     += (spectrum.bass     - bass)     * (1.0 - expf(-dt / 0.120))
        mid      += (spectrum.mid      - mid)      * (1.0 - expf(-dt / 0.200))
        treble   += (spectrum.treble   - treble)   * (1.0 - expf(-dt / 0.060))
        centroid += (spectrum.centroid - centroid) * (1.0 - expf(-dt / 0.250))

        if let b = beat { beatEnv = max(beatEnv, b.strength) }
        beatEnv *= expf(-dt / 0.080)

        // Continuous rotation. Mid widens the rate; centroid biases the
        // direction (bright/dark material spins opposite ways) so the mandala
        // feels timbre-aware rather than just amplitude-aware. Wrap to avoid
        // float blowup.
        let dir: Float = centroid > 0.5 ? 1 : -1
        rotate += dt * dir * (0.10 + mid * 1.2)
        if rotate >  6.28318530718 { rotate -= 6.28318530718 }
        if rotate < -6.28318530718 { rotate += 6.28318530718 }
    }

    func encode(into enc: MTLRenderCommandEncoder, uniforms: inout SceneUniforms) {
        enc.setRenderPipelineState(pipeline)
        var u = KU(aspect: uniforms.aspect, time: time, rms: rms,
                   bass: bass, mid: mid, treble: treble,
                   beat: beatEnv, rotate: rotate, sectors: sectors,
                   _pad0: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout.size(ofValue: u), index: 1)
        enc.setFragmentTexture(paletteTexture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private struct KU {
        var aspect: Float
        var time: Float
        var rms: Float
        var bass: Float
        var mid: Float
        var treble: Float
        var beat: Float
        var rotate: Float
        var sectors: Int32
        var _pad0: Float
    }
}
