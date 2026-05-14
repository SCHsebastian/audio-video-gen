import Foundation

public struct AudioDrive: Equatable, Sendable {
    public let bass: Float
    public let mid: Float
    public let treble: Float
    public let flux: Float
    public let beatPulse: Float
    public let beatTriggered: Bool
    public let bpm: Float

    public init(bass: Float, mid: Float, treble: Float, flux: Float,
                beatPulse: Float, beatTriggered: Bool, bpm: Float) {
        self.bass = bass; self.mid = mid; self.treble = treble; self.flux = flux
        self.beatPulse = beatPulse; self.beatTriggered = beatTriggered; self.bpm = bpm
    }

    public static let silence = AudioDrive(
        bass: 0, mid: 0, treble: 0, flux: 0,
        beatPulse: 0, beatTriggered: false, bpm: 0
    )
}
