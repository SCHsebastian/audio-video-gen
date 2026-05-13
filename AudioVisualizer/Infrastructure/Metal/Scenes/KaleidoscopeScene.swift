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

    func update(spectrum: SpectrumFrame, waveform: [Float], beat: BeatEvent?, dt: Float) {
        time += dt
        rms = spectrum.rms

        let bands = spectrum.bands
        let n = max(1, bands.count)
        let bassEnd = min(6, n)
        let midStart = min(6, n - 1)
        let midEnd   = min(24, n)
        let trebStart = min(24, n - 1)
        let trebEnd  = min(56, n)

        let bassTgt = bands.prefix(bassEnd).reduce(0, +) / Float(bassEnd)
        let midTgt  = (midStart..<midEnd).reduce(Float(0)) { $0 + bands[$1] }
                    / Float(max(1, midEnd - midStart))
        let trebTgt = (trebStart..<trebEnd).reduce(Float(0)) { $0 + bands[$1] }
                    / Float(max(1, trebEnd - trebStart))

        bass   += (bassTgt - bass)   * (1.0 - expf(-dt / 0.120))
        mid    += (midTgt  - mid)    * (1.0 - expf(-dt / 0.200))
        treble += (trebTgt - treble) * (1.0 - expf(-dt / 0.060))

        if let b = beat { beatEnv = max(beatEnv, b.strength) }
        beatEnv *= expf(-dt / 0.080)

        // Continuous rotation. Mid widens the rate. Wrap to avoid float blowup.
        rotate += dt * (0.10 + mid * 1.2)
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
