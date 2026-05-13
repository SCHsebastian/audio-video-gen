public struct SpectrumFrame: Equatable, Sendable {
    public let bands: [Float]    // normalized 0..1 — mono mixdown
    public let rms: Float        // overall loudness 0..1
    public let timestamp: HostTime

    // Centralised derived signals — produced by the analyzer once per frame so
    // multiple visualizations don't re-derive them. All in [0, 1].
    public let bass: Float       // mean of bands [0, N/8)         ≈ sub..250 Hz
    public let mid: Float        // mean of bands [N/8, N/2)       ≈ 250 Hz..4 kHz
    public let treble: Float     // mean of bands [N/2, N)         ≈ 4..22 kHz
    public let centroid: Float   // spectral centroid, log-Hz mapped 30 Hz..16 kHz → 0..1
    public let flux: Float       // positive spectral flux (onset energy), 0..1

    // Per-channel FFT bands, populated when the capture source supplies a
    // distinct stereo waveform. Empty when the source is mono — consumers
    // should fall back to `bands` for both channels in that case.
    public let leftBands: [Float]
    public let rightBands: [Float]

    public init(bands: [Float], rms: Float, timestamp: HostTime,
                bass: Float = 0, mid: Float = 0, treble: Float = 0,
                centroid: Float = 0, flux: Float = 0,
                leftBands: [Float] = [], rightBands: [Float] = []) {
        self.bands = bands
        self.rms = rms
        self.timestamp = timestamp
        self.bass = bass
        self.mid = mid
        self.treble = treble
        self.centroid = centroid
        self.flux = flux
        self.leftBands = leftBands
        self.rightBands = rightBands
    }
}
