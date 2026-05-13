import Metal
import Domain

struct SceneUniforms {
    var time: Float
    var aspect: Float
    var rms: Float
    var beatStrength: Float
}

protocol VisualizerScene: AnyObject {
    func build(device: MTLDevice, library: MTLLibrary, paletteTexture: MTLTexture) throws
    func update(spectrum: SpectrumFrame, waveform: WaveformBuffer, beat: BeatEvent?, dt: Float)
    func encode(into encoder: MTLRenderCommandEncoder, uniforms: inout SceneUniforms)
}
