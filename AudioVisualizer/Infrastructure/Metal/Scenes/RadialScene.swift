import Metal
import Domain

/// Radial spectrum: mirrored half-wheel of log-frequency bars with a beat ring
/// at the inner radius and an angular rainbow palette. Visually a "clock face
/// of frequency": low bands sit at the top, treble curls around the sides.
final class RadialScene: VisualizerScene {
    private let halfBarCount = 64                          // rendered side, mirrored across vertical axis
    private static let fMin: Float = 40
    private static let fMax: Float = 16_000
    private static let sampleRateHz: Float = 48_000
    private static let inputBands = 64                     // analyzer band count

    private var displayed = [Float](repeating: 0, count: 64)
    private var pipeline: MTLRenderPipelineState!
    private var heightsBuffer: MTLBuffer!
    private var paletteTexture: MTLTexture!

    private var time: Float = 0
    private var rms: Float = 0
    private var beatEnv: Float = 0
    private var beatAge: Float = 1

    // Pre-computed log-band table: for each output bar k, the (loBin, hiBin)
    // range in the linear FFT band array. Built once in `build()`.
    private var bandLo: [Int] = []
    private var bandHi: [Int] = []
    private var binMid: [Float] = []   // fractional bin midpoint for narrow slices

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
        heightsBuffer = device.makeBuffer(length: halfBarCount * MemoryLayout<Float>.size,
                                          options: .storageModeShared)
        rebuildBandTable()
    }

    private func rebuildBandTable() {
        bandLo.removeAll(keepingCapacity: true)
        bandHi.removeAll(keepingCapacity: true)
        binMid.removeAll(keepingCapacity: true)
        let hzPerBin = (Self.sampleRateHz * 0.5) / Float(Self.inputBands)
        let ratio = Self.fMax / Self.fMin
        for k in 0..<halfBarCount {
            let tLo = Float(k)     / Float(halfBarCount)
            let tHi = Float(k + 1) / Float(halfBarCount)
            let fLo = Self.fMin * powf(ratio, tLo)
            let fHi = Self.fMin * powf(ratio, tHi)
            let iLo = fLo / hzPerBin
            let iHi = fHi / hzPerBin
            bandLo.append(max(0, min(Self.inputBands - 1, Int(iLo.rounded(.down)))))
            bandHi.append(max(0, min(Self.inputBands - 1, Int((iHi).rounded(.up)) - 1)))
            binMid.append(0.5 * (iLo + iHi))
        }
    }

    func randomize() {
        // Re-seed the smoothing so a click resets the figure crisply, and flip
        // the rotation direction so the user sees something change.
        for i in 0..<displayed.count { displayed[i] = 0 }
        rotateDir = Bool.random() ? 1.0 : -1.0
    }

    private var rotateDir: Float = 1.0

    func update(spectrum: SpectrumFrame, waveform: [Float], beat: BeatEvent?, dt: Float) {
        time += dt
        rms = spectrum.rms
        if let b = beat {
            beatEnv = max(beatEnv, b.strength)
            beatAge = 0
        } else {
            beatAge = min(1, beatAge + dt / 0.50)
        }
        beatEnv *= expf(-dt / 0.150)

        // Rebin 64 linear → halfBarCount log; max within each slice when wider
        // than one bin, interpolate when narrower.
        let bands = spectrum.bands
        let aRise: Float = 0.55
        let aFall = 1.0 - expf(-dt / 0.250)
        for k in 0..<halfBarCount {
            var raw: Float = 0
            let lo = bandLo[k], hi = bandHi[k]
            if hi <= lo {
                let mid = binMid[k]
                let b0 = max(0, min(bands.count - 1, Int(mid.rounded(.down))))
                let b1 = min(bands.count - 1, b0 + 1)
                let frac = mid - Float(b0)
                raw = bands[b0] * (1 - frac) + bands[b1] * frac
            } else {
                for j in lo...hi { if bands[j] > raw { raw = bands[j] } }
            }
            // Log-magnitude compression so quiet bands don't hug the floor.
            let target = log10f(1.0 + 9.0 * raw)
            if target > displayed[k] {
                displayed[k] += (target - displayed[k]) * aRise
            } else {
                displayed[k] += (target - displayed[k]) * aFall
            }
        }
        memcpy(heightsBuffer.contents(), displayed, halfBarCount * MemoryLayout<Float>.size)
    }

    func encode(into enc: MTLRenderCommandEncoder, uniforms: inout SceneUniforms) {
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBuffer(heightsBuffer, offset: 0, index: 0)
        var u = RU(aspect: uniforms.aspect,
                   time: time * rotateDir,
                   barCount: Int32(halfBarCount),
                   rms: rms,
                   beat: beatEnv,
                   beatAge: beatAge,
                   _pad0: 0, _pad1: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout.size(ofValue: u), index: 1)
        enc.setFragmentTexture(paletteTexture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private struct RU {
        var aspect: Float
        var time: Float
        var barCount: Int32
        var rms: Float
        var beat: Float
        var beatAge: Float
        var _pad0: Float
        var _pad1: Float
    }
}
