import Metal
import Domain

final class TunnelScene: VisualizerScene {
    private var pipeline: MTLRenderPipelineState!
    private var paletteTexture: MTLTexture!
    private var rms: Float = 0
    private var beat: Float = 0
    private var time: Float = 0

    func build(device: MTLDevice, library: MTLLibrary, paletteTexture: MTLTexture) throws {
        self.paletteTexture = paletteTexture
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "tunnel_vertex")
        desc.fragmentFunction = library.makeFunction(name: "tunnel_fragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        desc.colorAttachments[0].isBlendingEnabled = false
        do { pipeline = try device.makeRenderPipelineState(descriptor: desc) }
        catch { throw RenderError.pipelineCreationFailed(name: "Tunnel") }
    }

    func update(spectrum: SpectrumFrame, waveform: [Float], beat: BeatEvent?, dt: Float) {
        rms = spectrum.rms
        if let b = beat { self.beat = max(self.beat, b.strength) }
        self.beat *= 0.9
        time += dt
    }

    func encode(into enc: MTLRenderCommandEncoder, uniforms: inout SceneUniforms) {
        enc.setRenderPipelineState(pipeline)
        var tu = (time: time, aspect: uniforms.aspect, rms: rms, beat: beat)
        enc.setFragmentBytes(&tu, length: MemoryLayout.size(ofValue: tu), index: 0)
        enc.setFragmentTexture(paletteTexture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
}
