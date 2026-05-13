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
    }

    deinit { vDSP_DFT_DestroySetup(setup) }

    func analyze(_ frame: AudioFrame) -> SpectrumFrame {
        let n = fftSize
        let half = n / 2
        let src = frame.samples

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
        var bands = [Float](repeating: 0, count: bandCount)
        for i in 0..<bandCount {
            let lo = bandEdges[i]
            let hi = max(lo + 1, bandEdges[i + 1])
            var peak: Float = 0
            for j in lo..<hi { peak = max(peak, sqrtMags[j]) }
            bands[i] = min(1, peak * norm)
        }

        // RMS over the (un-windowed) input segment.
        var rms: Float = 0
        let actualCount = min(n, src.count)
        if actualCount > 0 {
            let tail = src.suffix(actualCount)
            let tailArr = Array(tail)
            vDSP_rmsqv(tailArr, 1, &rms, vDSP_Length(tailArr.count))
            rms = min(1, rms)
        }

        return SpectrumFrame(bands: bands, rms: rms, timestamp: frame.timestamp)
    }
}
