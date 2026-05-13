import Foundation
import Metal
import Domain

/// Canonical spectrogram waterfall. Time runs horizontally (newest at the
/// right edge), frequency vertically on a log axis (bass at the bottom).
/// The CPU bakes a *column* per frame — log-Hz remap of the 64 linear FFT
/// bands, then 20·log10 + 80 dB normalization — and writes one column into
/// a ring-buffer texture. The shader rotates the texture so the write head
/// always lives at the right edge.
final class SpectrogramScene: VisualizerScene {
    private static let W = 1024              // history columns (~17 s @ 60 fps)
    private static let H = 256               // log-frequency rows
    private static let fMin: Float = 20
    private static let fMax: Float = 24_000  // Nyquist for 48 kHz capture
    private static let dbFloor: Float = -80
    private static let dbCeil:  Float = 0

    private static let inputBands: Int = 64
    private static let hzPerInputBin: Float = (48_000 * 0.5) / Float(inputBands)

    private var writeCol: Int = 0
    private var pipeline: MTLRenderPipelineState!
    private var paletteTexture: MTLTexture!
    private var historyTexture: MTLTexture!

    // Per-row "max-with-decay" memory so sustained tones look stable.
    private var previousColumn = [Float](repeating: 0, count: H)
    // Separate persistence buffers for the stereo split (each half is H/2 rows).
    private var previousColumnL = [Float](repeating: 0, count: H / 2)
    private var previousColumnR = [Float](repeating: 0, count: H / 2)
    // Precomputed log-Hz → linear-bin lookup table (one entry per H row).
    private var binTable: [Float] = []   // length H — fractional bin index per row

    func build(device: MTLDevice, library: MTLLibrary, paletteTexture: MTLTexture) throws {
        self.paletteTexture = paletteTexture
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "spec_vertex")
        desc.fragmentFunction = library.makeFunction(name: "spec_fragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        desc.colorAttachments[0].isBlendingEnabled = false
        do { pipeline = try device.makeRenderPipelineState(descriptor: desc) }
        catch { throw RenderError.pipelineCreationFailed(name: "Spectrogram") }

        let tdesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float,
            width: Self.W, height: Self.H, mipmapped: false)
        tdesc.usage = [.shaderRead]
        tdesc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: tdesc) else {
            throw RenderError.pipelineCreationFailed(name: "Spectrogram.history")
        }
        // Zero-fill so empty regions render as the dark end of the palette.
        let zeros = [Float](repeating: 0, count: Self.W * Self.H)
        zeros.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, Self.W, Self.H),
                        mipmapLevel: 0,
                        withBytes: raw.baseAddress!,
                        bytesPerRow: Self.W * MemoryLayout<Float>.size)
        }
        self.historyTexture = tex
        self.writeCol = 0

        // Build the log-Hz → linear-bin table for row k ∈ [0, H).
        let ratio = log2f(Self.fMax / Self.fMin)
        binTable.reserveCapacity(Self.H)
        for k in 0..<Self.H {
            let t = Float(k) / Float(Self.H - 1)
            let f = Self.fMin * exp2f(ratio * t)
            binTable.append(f / Self.hzPerInputBin)
        }
    }

    func update(spectrum: SpectrumFrame, waveform: WaveformBuffer, beat: BeatEvent?, dt: Float) {
        // Build one log-Hz, dB-scaled, normalized column [0..1] over H rows.
        // Stereo path: bottom half = R, top half = L — both span the full
        // log-Hz range. Mono path: one column over the full H rows.
        let stereo = !spectrum.leftBands.isEmpty && !spectrum.rightBands.isEmpty
        var column = [Float](repeating: 0, count: Self.H)
        if stereo {
            let half = Self.H / 2
            // Build R into rows [0, half), L into rows [half, H).
            buildHalfColumn(into: &column, offset: 0,         rows: half,
                            bands: spectrum.rightBands,
                            previous: &previousColumnR)
            buildHalfColumn(into: &column, offset: half,      rows: half,
                            bands: spectrum.leftBands,
                            previous: &previousColumnL)
            // 1-pixel dim divider between the two halves so the eye separates them.
            column[half] = 0
        } else {
            buildHalfColumn(into: &column, offset: 0, rows: Self.H,
                            bands: spectrum.bands,
                            previous: &previousColumn)
        }

        // Bottom of the screen should be bass — but ndc.y maps top→1, so when
        // the shader does `v_tex = uv.y` row 0 ends up at the bottom of the
        // screen. We want row 0 = bass = bottom, so this matches naturally —
        // ndc.y=-1 (bottom) → uv.y=0 → row 0. Good. In the stereo case row 0
        // is R-bass at the bottom and row H/2 is L-bass just above the divider.

        column.withUnsafeBytes { raw in
            historyTexture.replace(region: MTLRegionMake2D(writeCol, 0, 1, Self.H),
                                   mipmapLevel: 0,
                                   withBytes: raw.baseAddress!,
                                   bytesPerRow: MemoryLayout<Float>.size)
        }
        writeCol = (writeCol + 1) % Self.W
    }

    /// Build a log-Hz, dB-normalised, peak-held column slice into `column`
    /// starting at `offset` and spanning `rows` rows. `previous` is updated in
    /// place so the per-row exponential peak hold survives across frames.
    private func buildHalfColumn(into column: inout [Float],
                                 offset: Int,
                                 rows: Int,
                                 bands: [Float],
                                 previous: inout [Float]) {
        let n = bands.count
        guard n > 0, rows > 0 else { return }
        let lastBin = n - 1
        let dbRange = Self.dbCeil - Self.dbFloor
        // Stretch the precomputed binTable (which spans the full H rows) over
        // this half so both halves still cover the full log-Hz range.
        let scale = Float(Self.H - 1) / Float(max(1, rows - 1))
        for k in 0..<rows {
            let srcK = min(Self.H - 1, Int((Float(k) * scale).rounded()))
            let frac = binTable[srcK]
            let b0 = max(0, min(lastBin, Int(frac.rounded(.down))))
            let b1 = min(lastBin, b0 + 1)
            let t = frac - Float(b0)
            let mag = bands[b0] * (1 - t) + bands[b1] * t
            let db = 20.0 * log10f(max(mag, 1e-6))
            var v = (db - Self.dbFloor) / dbRange
            if v < 0 { v = 0 }
            if v > 1 { v = 1 }
            let prev = previous[k] * 0.85
            let held = max(v, prev)
            column[offset + k] = held
            previous[k] = held
        }
    }

    func encode(into enc: MTLRenderCommandEncoder, uniforms: inout SceneUniforms) {
        enc.setRenderPipelineState(pipeline)
        // writeColNorm sits at the *next* slot — that's where the newest
        // column is about to land. Shader uses `fract(uv.x + writeColNorm)`
        // to put the newest column at the right edge.
        let writeColNorm = Float(writeCol) / Float(Self.W)
        var u = SU(aspect: uniforms.aspect,
                   W: Int32(Self.W), H: Int32(Self.H),
                   writeColNorm: 1.0 - writeColNorm,
                   showPitchGrid: 0,
                   _pad0: 0, _pad1: 0, _pad2: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout.size(ofValue: u), index: 1)
        enc.setFragmentTexture(paletteTexture, index: 0)
        enc.setFragmentTexture(historyTexture, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private struct SU {
        var aspect: Float
        var W: Int32
        var H: Int32
        var writeColNorm: Float
        var showPitchGrid: Int32
        var _pad0: Float
        var _pad1: Float
        var _pad2: Float
    }
}
