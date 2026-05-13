public protocol BeatDetecting: Sendable {
    func feed(_ spectrum: SpectrumFrame) -> BeatEvent?
}
