public protocol AudioSpectrumAnalyzing: Sendable {
    var bandCount: Int { get }
    func analyze(_ frame: AudioFrame) -> SpectrumFrame
}
