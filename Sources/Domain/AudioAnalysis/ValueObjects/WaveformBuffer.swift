/// PCM tail handed to visualizations every frame. Always carries a mono
/// mixdown; `left` and `right` mirror the original stereo channels when the
/// capture source provides them, and fall back to `mono` when the source is
/// mono so consumers don't need a separate "is stereo?" branch.
public struct WaveformBuffer: Equatable, Sendable {
    public let mono: [Float]
    public let left: [Float]
    public let right: [Float]

    public init(mono: [Float], left: [Float]? = nil, right: [Float]? = nil) {
        self.mono = mono
        self.left  = left  ?? mono
        self.right = right ?? mono
    }

    /// True iff `left` and `right` carry distinct stereo data — i.e. they are
    /// not pointing at the same array as `mono`. Scenes that draw a stereo
    /// goniometer should fall back to a parametric trace when this is false.
    public var isStereo: Bool {
        // A mono fallback init copies the mono array into left/right; once
        // captured separately the two channels will diverge at *some* sample.
        // Cheap sanity check: distinct counts or distinct first sample beyond
        // exact silence.
        guard !mono.isEmpty else { return false }
        if left.count != mono.count || right.count != mono.count { return false }
        // Compare the first non-silent sample; if any L/R pair differs by more
        // than a tiny amount the source is stereo.
        for i in 0..<mono.count {
            if abs(left[i] - right[i]) > 1e-4 { return true }
        }
        return false
    }
}
