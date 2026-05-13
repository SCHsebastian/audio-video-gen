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

    func update(spectrum: SpectrumFrame, waveform: [Float], beat: BeatEvent?, dt: Float) {
        rms = spectrum.rms
        time += dt

        // Per-band averages with τ-stable one-pole smoothing.
        let bandCount = max(1, spectrum.bands.count)
        let loEnd = min(8, bandCount)
        let bassTgt = spectrum.bands.prefix(loEnd).reduce(0, +) / Float(loEnd)
        let midStart = min(8, bandCount - 1)
        let midEnd   = min(32, bandCount)
        let midSlice = (midStart..<midEnd).reduce(Float(0)) { $0 + spectrum.bands[$1] }
        let _ = midSlice / Float(max(1, midEnd - midStart))  // available if we add a mid coupling later
        let hiStart  = min(40, bandCount - 1)
        let hiEnd    = bandCount
        let hiCount  = max(1, hiEnd - hiStart)
        let trebleTgt = (hiStart..<hiEnd).reduce(Float(0)) { $0 + spectrum.bands[$1] } / Float(hiCount)
        bass   += (bassTgt   - bass)   * (1.0 - expf(-dt / 0.10))
        treble += (trebleTgt - treble) * (1.0 - expf(-dt / 0.04))

        if let b = beat {
            beatEnv = max(beatEnv, b.strength)
            beatAge = 0
        } else {
            beatAge = min(1, beatAge + dt / 0.35)
        }
        beatEnv *= expf(-dt / 0.220)
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
                    _pad0: 0, _pad1: 0)
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
        var _pad0: Float
        var _pad1: Float
    }
}
