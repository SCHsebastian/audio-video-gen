import Metal
import Domain
import VisualizerKernels

final class ScopeScene: VisualizerScene {
    private var samplesBuffer: MTLBuffer!
    private var sampleCount: UInt32 = 1024
    private var pipeline: MTLRenderPipelineState!
    private var paletteTexture: MTLTexture!
    private var rms: Float = 0
    private var scratchIn = [Float](repeating: 0, count: 1024)
    private var scratchOut = [Float](repeating: 0, count: 1024)

    func build(device: MTLDevice, library: MTLLibrary, paletteTexture: MTLTexture) throws {
        self.paletteTexture = paletteTexture
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "scope_vertex")
        desc.fragmentFunction = library.makeFunction(name: "scope_fragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .one        // additive
        do { pipeline = try device.makeRenderPipelineState(descriptor: desc) }
        catch { throw RenderError.pipelineCreationFailed(name: "Scope") }
        samplesBuffer = device.makeBuffer(length: Int(sampleCount) * MemoryLayout<Float>.size, options: .storageModeShared)
    }

    func update(spectrum: SpectrumFrame, waveform: [Float], beat: BeatEvent?, dt: Float) {
        rms = spectrum.rms
        let count = Int(sampleCount)
        // Copy the tail of the waveform into a fixed-size scratch buffer so the
        // C++ envelope kernel always sees `count` samples, zero-padded at the
        // front if the producer fell short.
        let tail = waveform.suffix(count)
        let pad = count - tail.count
        for i in 0..<pad { scratchIn[i] = 0 }
        var idx = pad
        for v in tail { scratchIn[idx] = v; idx += 1 }

        let gain: Float = 1.0 + min(2.0, rms * 4.0)
        scratchIn.withUnsafeBufferPointer { inPtr in
            scratchOut.withUnsafeMutableBufferPointer { outPtr in
                vk_scope_envelope(inPtr.baseAddress, outPtr.baseAddress, UInt32(count), gain)
            }
        }
        memcpy(samplesBuffer.contents(), scratchOut, count * MemoryLayout<Float>.size)
    }

    func encode(into enc: MTLRenderCommandEncoder, uniforms: inout SceneUniforms) {
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(samplesBuffer, offset: 0, index: 0)
        var count = sampleCount
        enc.setVertexBytes(&count, length: 4, index: 1)
        var su = (thickness: Float(0.01 + uniforms.rms * 0.03), aspect: uniforms.aspect, time: uniforms.time, _pad: Float(0))
        enc.setVertexBytes(&su, length: MemoryLayout.size(ofValue: su), index: 2)
        var alpha: Float = 0.9
        enc.setFragmentBytes(&alpha, length: 4, index: 0)
        enc.setFragmentTexture(paletteTexture, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: Int(sampleCount) * 2)
        var alpha2: Float = 0.25
        su.thickness *= 3
        enc.setVertexBytes(&su, length: MemoryLayout.size(ofValue: su), index: 2)
        enc.setFragmentBytes(&alpha2, length: 4, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: Int(sampleCount) * 2)
    }
}
