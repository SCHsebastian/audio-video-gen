import Metal
import Domain

final class ScopeScene: VisualizerScene {
    private var samplesBuffer: MTLBuffer!
    private var sampleCount: UInt32 = 1024
    private var pipeline: MTLRenderPipelineState!
    private var paletteTexture: MTLTexture!

    func build(device: MTLDevice, library: MTLLibrary, paletteTexture: MTLTexture) throws {
        self.paletteTexture = paletteTexture
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "scope_vertex")
        desc.fragmentFunction = library.makeFunction(name: "scope_fragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .one        // additive
        do { pipeline = try device.makeRenderPipelineState(descriptor: desc) }
        catch { throw RenderError.pipelineCreationFailed(name: "Scope") }
        samplesBuffer = device.makeBuffer(length: Int(sampleCount) * MemoryLayout<Float>.size, options: .storageModeShared)
    }

    func update(spectrum: SpectrumFrame, waveform: [Float], beat: BeatEvent?, dt: Float) {
        let count = Int(sampleCount)
        var tail = Array(waveform.suffix(count))
        if tail.count < count { tail = Array(repeating: 0, count: count - tail.count) + tail }
        memcpy(samplesBuffer.contents(), tail, count * MemoryLayout<Float>.size)
    }

    func encode(into enc: MTLRenderCommandEncoder, uniforms: inout SceneUniforms) {
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(samplesBuffer, offset: 0, index: 0)
        var count = sampleCount
        enc.setVertexBytes(&count, length: 4, index: 1)
        // Pad struct to 16 bytes to match Metal alignment requirements (matches ScopeUniforms in shader).
        var su = (thickness: Float(0.01 + uniforms.rms * 0.03), aspect: uniforms.aspect, time: uniforms.time, _pad: Float(0))
        enc.setVertexBytes(&su, length: MemoryLayout.size(ofValue: su), index: 2)
        var alpha: Float = 0.9
        enc.setFragmentBytes(&alpha, length: 4, index: 0)
        enc.setFragmentTexture(paletteTexture, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: Int(sampleCount) * 2)
        // Glow pass: thicker, low alpha.
        var alpha2: Float = 0.25
        su.thickness *= 3
        enc.setVertexBytes(&su, length: MemoryLayout.size(ofValue: su), index: 2)
        enc.setFragmentBytes(&alpha2, length: 4, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: Int(sampleCount) * 2)
    }
}
