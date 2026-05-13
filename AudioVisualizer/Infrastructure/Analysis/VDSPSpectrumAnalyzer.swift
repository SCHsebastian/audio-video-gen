import Accelerate
import Domain

final class VDSPSpectrumAnalyzer: AudioSpectrumAnalyzing, @unchecked Sendable {
    let bandCount: Int
    private let sampleRate: SampleRate
    private let fftSize: Int
    private let setup: vDSP_DFT_Setup
    private var window: [Float]
    private var windowed: [Float]
    private var realIn: [Float]
    private var imagIn: [Float]
    private var realOut: [Float]
    private var imagOut: [Float]
    private let bandEdges: [Int]    // FFT bin index per band edge, length == bandCount+1
    private var prevMags: [Float]   // previous-frame mono magnitudes (for spectral flux)

    // Log-Hz centroid mapping. centroid in Hz → [0,1] via log2(c/cLo)/log2(cHi/cLo).
    private let centroidLogLo: Float
    private let centroidLogSpan: Float

    init(bandCount: Int, sampleRate: SampleRate, fftSize: Int = 1024) {
        precondition(fftSize.nonzeroBitCount == 1, "fftSize must be a power of 2")
        self.bandCount = bandCount
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD)!
        var w = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&w, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        self.window = w
        self.windowed = [Float](repeating: 0, count: fftSize)
        let half = fftSize / 2
        self.realIn = [Float](repeating: 0, count: half)
        self.imagIn = [Float](repeating: 0, count: half)
        self.realOut = [Float](repeating: 0, count: half)
        self.imagOut = [Float](repeating: 0, count: half)
        self.prevMags = [Float](repeating: 0, count: half)

        // Log-spaced bands 30 Hz .. 16 kHz mapped onto FFT bins.
        let lo: Double = 30, hi: Double = min(16_000, sampleRate.hz / 2)
        let binHz = sampleRate.hz / Double(fftSize)
        var edges: [Int] = []
        for i in 0...bandCount {
            let f = lo * pow(hi / lo, Double(i) / Double(bandCount))
            let bin = max(1, min(half - 1, Int((f / binHz).rounded())))
            edges.append(bin)
        }
        self.bandEdges = edges

        // Centroid maps the FFT-bin centre frequency to [0,1] on a log axis.
        // Anything below 30 Hz clamps to 0; anything above 16 kHz clamps to 1.
        self.centroidLogLo = log2(Float(lo))
        self.centroidLogSpan = max(.leastNonzeroMagnitude, log2(Float(hi)) - log2(Float(lo)))
    }

    deinit { vDSP_DFT_DestroySetup(setup) }

    func analyze(_ frame: AudioFrame) -> SpectrumFrame {
        let n = fftSize
        let src = frame.samples

        // Run the canonical mono FFT and capture the post-norm magnitudes so we
        // can compute centroid / flux from them without redoing the math.
        var monoMags = [Float](repeating: 0, count: n / 2)
        let bands = fft(samples: src, scaledMagnitudes: &monoMags)

        // RMS over the (un-windowed) input segment.
        var rms: Float = 0
        let actualCount = min(n, src.count)
        if actualCount > 0 {
            let tail = src.suffix(actualCount)
            let tailArr = Array(tail)
            vDSP_rmsqv(tailArr, 1, &rms, vDSP_Length(tailArr.count))
            rms = min(1, rms)
        }

        // ----- Derived signals (mono) -----
        let (bass, mid, treble) = subBandAverages(bands)
        let centroid = spectralCentroid(magnitudes: monoMags,
                                        binHz: Float(sampleRate.hz) / Float(n))
        let flux = spectralFlux(scaled: monoMags)

        // Keep the normalised mono magnitudes for next-frame flux.
        for i in 0..<monoMags.count { prevMags[i] = monoMags[i] }

        // ----- Per-channel bands when the frame carries true stereo -----
        var leftBands: [Float] = []
        var rightBands: [Float] = []
        if !frame.left.isEmpty && !frame.right.isEmpty {
            var scratch = [Float](repeating: 0, count: n / 2)
            leftBands  = fft(samples: frame.left,  scaledMagnitudes: &scratch)
            rightBands = fft(samples: frame.right, scaledMagnitudes: &scratch)
        }

        return SpectrumFrame(bands: bands, rms: rms, timestamp: frame.timestamp,
                             bass: bass, mid: mid, treble: treble,
                             centroid: centroid, flux: flux,
                             leftBands: leftBands, rightBands: rightBands)
    }

    // MARK: - FFT core

    /// Run the windowed real-FFT over `samples` (taking the most recent `fftSize`
    /// samples, zero-padded at the front if shorter), and produce both:
    ///   • the band-aggregated [0,1] vector (length `bandCount`)
    ///   • the normalised per-bin magnitudes written into `scaledMagnitudes`
    private func fft(samples src: [Float], scaledMagnitudes: inout [Float]) -> [Float] {
        let n = fftSize
        let half = n / 2

        // Window. If src is shorter than n, zero-pad; if longer, take the last n samples (most recent).
        let start = max(0, src.count - n)
        for i in 0..<n {
            let sampleIdx = start + i
            let s: Float = sampleIdx < src.count ? src[sampleIdx] : 0
            windowed[i] = s * window[i]
        }

        // Pack real input into split complex using vDSP_ctoz.
        windowed.withUnsafeBufferPointer { wp in
            wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cptr in
                var split = DSPSplitComplex(realp: &realIn, imagp: &imagIn)
                vDSP_ctoz(cptr, 2, &split, 1, vDSP_Length(half))
            }
        }

        // Execute DFT.
        vDSP_DFT_Execute(setup, &realIn, &imagIn, &realOut, &imagOut)

        // Compute magnitudes (squared then sqrt via vvsqrtf).
        var mags = [Float](repeating: 0, count: half)
        realOut.withUnsafeMutableBufferPointer { rp in
            imagOut.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }
        var sqrtMags = [Float](repeating: 0, count: half)
        var halfCount = Int32(half)
        vvsqrtf(&sqrtMags, &mags, &halfCount)

        // Normalize: 2/N keeps amplitude near 1.0 for a full-scale sinusoid.
        let norm = 2.0 / Float(n)
        for i in 0..<half { scaledMagnitudes[i] = min(1, sqrtMags[i] * norm) }

        // Aggregate into bands using peak-within-edge (matches the original behaviour).
        var bands = [Float](repeating: 0, count: bandCount)
        for i in 0..<bandCount {
            let lo = bandEdges[i]
            let hi = max(lo + 1, bandEdges[i + 1])
            var peak: Float = 0
            for j in lo..<hi { peak = max(peak, sqrtMags[j]) }
            bands[i] = min(1, peak * norm)
        }
        return bands
    }

    // MARK: - Derived signals

    /// Cut the band array into three sub-bands using N/8 and N/2 splits so the
    /// boundaries scale with bandCount. With the default 64-band setup this
    /// yields the same [0..8), [8..32), [32..64) ranges every scene used to
    /// re-derive ad-hoc — match the canonical scene specs.
    private func subBandAverages(_ bands: [Float]) -> (Float, Float, Float) {
        let n = bands.count
        guard n > 0 else { return (0, 0, 0) }
        let bassEnd  = max(1, n / 8)
        let midEnd   = max(bassEnd + 1, n / 2)
        let trebEnd  = n
        var bass: Float = 0, mid: Float = 0, treb: Float = 0
        for i in 0..<bassEnd        { bass += bands[i] }
        for i in bassEnd..<midEnd   { mid  += bands[i] }
        for i in midEnd..<trebEnd   { treb += bands[i] }
        bass /= Float(bassEnd)
        mid  /= Float(midEnd - bassEnd)
        treb /= Float(trebEnd - midEnd)
        return (bass, mid, treb)
    }

    /// Magnitude-weighted mean bin frequency, then log-mapped 30 Hz..16 kHz → [0,1].
    /// Silence (sum ≈ 0) returns 0.
    private func spectralCentroid(magnitudes mags: [Float], binHz: Float) -> Float {
        // Skip DC (bin 0). Floor at 1e-6 so silent frames don't divide by zero.
        var num: Float = 0
        var den: Float = 0
        for i in 1..<mags.count {
            let m = mags[i]
            num += Float(i) * binHz * m
            den += m
        }
        guard den > 1e-6 else { return 0 }
        let hz = num / den
        let mapped = (log2(max(1, hz)) - centroidLogLo) / centroidLogSpan
        return min(1, max(0, mapped))
    }

    /// Sum of positive frame-to-frame magnitude deltas, normalised so a sustained
    /// full-scale change yields ≈ 1 and silence yields 0.
    private func spectralFlux(scaled mags: [Float]) -> Float {
        var sum: Float = 0
        for i in 0..<mags.count {
            let d = mags[i] - prevMags[i]
            if d > 0 { sum += d }
        }
        // Empirically, a kick onset contributes ~5 across 512 bins; divide by 8
        // and clamp so flux sits comfortably in [0, 1] for visual mapping.
        return min(1, sum / 8)
    }
}
