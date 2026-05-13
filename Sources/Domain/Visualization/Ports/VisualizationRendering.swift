public protocol VisualizationRendering: AnyObject, Sendable {
    func setScene(_ kind: SceneKind)
    func setPalette(_ palette: ColorPalette)
    func consume(spectrum: SpectrumFrame, waveform: WaveformBuffer, beat: BeatEvent?)
}
