import Metal
import Domain

/// Demoscene 2D-trick tunnel — projects each fragment onto a cylinder via
/// `(u, v) = (angle/π, 1/r + scroll)` and shades a checkerboard pattern with
/// derivative-based AA. Bass drives spiral twist, RMS gooses forward speed,
/// beats fire a radial shockwave, treble adds high-frequency surface ripple.
final class TunnelScene: VisualizerScene {
    private var pipeline: MTLRenderPipelineState!
    private var paletteTexture: MTLTexture!

    // Smoothed audio scalars + beat state.
    private var rms: Float = 0
    private var bass: Float = 0
    private var treble: Float = 0
    private var trebleL: Float = 0
    private var trebleR: Float = 0
    // Bass left/right balance, smoothed to [-1, 1]. -1 = bass on the left only,
    // +1 = bass on the right only, 0 = centered or mono.
    private var stereoBias: Float = 0
    private var beatEnv: Float = 0
    private var beatAge: Float = 1
    private var time: Float = 0

    // Look knobs — `randomize()` jitters these.
    private var nAng: Float = 8
    private var nDep: Float = 4
    private var depthScale: Float = 0.6
    private var twist: Float = 6.0
    private var direction: Float = 1.0

    func build(device: MTLDevice, library: MTLLibrary, paletteTexture: MTLTexture) throws {
        self.paletteTexture = paletteTexture
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "tunnel_vertex")
        desc.fragmentFunction = library.makeFunction(name: "tunnel_fragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        desc.colorAttachments[0].isBlendingEnabled = false
        do { pipeline = try device.makeRenderPipelineState(descriptor: desc) }
        catch { throw RenderError.pipelineCreationFailed(name: "Tunnel") }
    }

    func update(spectrum: SpectrumFrame, waveform: WaveformBuffer, beat: BeatEvent?, dt: Float) {
        rms = spectrum.rms
        time += dt

        // τ-stable one-pole smoothing of the analyzer's centralised sub-bands.
        bass   += (spectrum.bass   - bass)   * (1.0 - expf(-dt / 0.10))
        treble += (spectrum.treble - treble) * (1.0 - expf(-dt / 0.04))

        // Per-side band reductions match the analyzer's 1/8, 1/2 split so trebleL/R
        // and the bass-balance scalar read on the same scale as `bass` / `treble`.
        let (lBass, lTreb) = Self.bassTreble(spectrum.leftBands)
        let (rBass, rTreb) = Self.bassTreble(spectrum.rightBands)
        let aTreb = 1.0 - expf(-dt / 0.04)
        trebleL += (lTreb - trebleL) * aTreb
        trebleR += (rTreb - trebleR) * aTreb

        // Normalised L/R bass balance. Falls back to 0 when bands are absent (mono
        // source) so the shader's stereoBias term contributes nothing.
        let balanceTarget: Float
        let denom = lBass + rBass
        if denom > 1e-4 {
            balanceTarget = max(-1, min(1, (rBass - lBass) / denom))
        } else {
            balanceTarget = 0
        }
        stereoBias += (balanceTarget - stereoBias) * (1.0 - expf(-dt / 0.20))

        if let b = beat {
            beatEnv = max(beatEnv, b.strength)
            beatAge = 0
        } else {
            beatAge = min(1, beatAge + dt / 0.35)
        }
        beatEnv *= expf(-dt / 0.220)
    }

    /// Sub-band averages matching `VDSPSpectrumAnalyzer.subBandAverages` — bass is
    /// the first 1/8 of bands, treble is the last 1/2. Empty input returns zero
    /// pair, so a mono frame (no left/right bands) collapses to no stereo effect.
    private static func bassTreble(_ bands: [Float]) -> (Float, Float) {
        let n = bands.count
        guard n > 0 else { return (0, 0) }
        let bassEnd = max(1, n / 8)
        let trebStart = max(bassEnd + 1, n / 2)
        var bass: Float = 0, treb: Float = 0
        for i in 0..<bassEnd     { bass += bands[i] }
        for i in trebStart..<n   { treb += bands[i] }
        bass /= Float(bassEnd)
        treb /= Float(max(1, n - trebStart))
        return (bass, treb)
    }

    func encode(into enc: MTLRenderCommandEncoder, uniforms: inout SceneUniforms) {
        enc.setRenderPipelineState(pipeline)
        var tu = TU(time: time,
                    aspect: uniforms.aspect,
                    rms: rms,
                    beat: beatEnv,
                    beatAge: beatAge,
                    bass: bass,
                    treble: treble,
                    twist: twist,
                    depth: depthScale,
                    nAng: nAng,
                    nDep: nDep,
                    direction: direction,
                    trebleL: trebleL,
                    trebleR: trebleR,
                    stereoBias: stereoBias,
                    _pad0: 0)
        enc.setFragmentBytes(&tu, length: MemoryLayout.size(ofValue: tu), index: 0)
        enc.setFragmentTexture(paletteTexture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    func randomize() {
        nAng = [6, 8, 12].randomElement().map(Float.init) ?? 8
        nDep = [3, 4, 6].randomElement().map(Float.init) ?? 4
        depthScale = Float.random(in: 0.45...0.85)
        twist = Float.random(in: 3.0...10.0)
        direction = Bool.random() ? 1.0 : -1.0
    }

    private struct TU {
        var time: Float
        var aspect: Float
        var rms: Float
        var beat: Float
        var beatAge: Float
        var bass: Float
        var treble: Float
        var twist: Float
        var depth: Float
        var nAng: Float
        var nDep: Float
        var direction: Float
        // Stereo extension — mono source leaves these all at zero, which is the
        // mathematical identity for the shader's stereo terms.
        var trebleL: Float
        var trebleR: Float
        var stereoBias: Float
        var _pad0: Float
    }
}
