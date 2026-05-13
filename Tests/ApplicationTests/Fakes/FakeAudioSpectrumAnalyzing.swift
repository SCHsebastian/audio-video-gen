import Domain

final class FakeAudioSpectrumAnalyzing: AudioSpectrumAnalyzing, @unchecked Sendable {
    let bandCount = 4
    var analyzeCount = 0
    func analyze(_ frame: AudioFrame) -> SpectrumFrame {
        analyzeCount += 1
        return SpectrumFrame(bands: [0, 0.25, 0.5, 0.75], rms: 0.5, timestamp: frame.timestamp)
    }
}
