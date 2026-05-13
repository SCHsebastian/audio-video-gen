import Metal
import Domain

/// Scrolling spectrogram waterfall. A ring-buffer texture stores recent
/// spectrum frames (rows = time, columns = bands); each `update()` writes one
/// fresh row at `writeIndex` and advances the index. The fragment shader maps
/// screen Y to a history offset and samples the texture.
final class SpectrogramScene: VisualizerScene {
    private let bandCount: Int = 64
    private let historyRows: Int = 256
    private var writeIndex: Int = 0

    private var pipeline: MTLRenderPipelineState!
    private var paletteTexture: MTLTexture!
    private var historyTexture: MTLTexture!

    func build(device: MTLDevice, library: MTLLibrary, paletteTexture: MTLTexture) throws {
        self.paletteTexture = paletteTexture
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "spec_vertex")
        desc.fragmentFunction = library.makeFunction(name: "spec_fragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        desc.colorAttachments[0].isBlendingEnabled = false
        do { pipeline = try device.makeRenderPipelineState(descriptor: desc) }
        catch { throw RenderError.pipelineCreationFailed(name: "Spectrogram") }

        let tdesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float,
            width: bandCount, height: historyRows, mipmapped: false)
        tdesc.usage = [.shaderRead, .renderTarget]
        tdesc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: tdesc) else {
            throw RenderError.pipelineCreationFailed(name: "Spectrogram.history")
        }
        // Zero-fill so the first frames aren't garbage.
        var zeros = [Float](repeating: 0, count: bandCount * historyRows)
        zeros.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, bandCount, historyRows),
                        mipmapLevel: 0,
                        withBytes: raw.baseAddress!,
                        bytesPerRow: bandCount * MemoryLayout<Float>.size)
        }
        self.historyTexture = tex
        self.writeIndex = 0
    }

    func update(spectrum: SpectrumFrame, waveform: [Float], beat: BeatEvent?, dt: Float) {
        // Write one row at `writeIndex`. The shader knows the ring direction.
        let n = min(bandCount, spectrum.bands.count)
        var row = [Float](repeating: 0, count: bandCount)
        for i in 0..<n { row[i] = spectrum.bands[i] }
        row.withUnsafeBytes { raw in
            historyTexture.replace(region: MTLRegionMake2D(0, writeIndex, bandCount, 1),
                                   mipmapLevel: 0,
                                   withBytes: raw.baseAddress!,
                                   bytesPerRow: bandCount * MemoryLayout<Float>.size)
        }
        writeIndex = (writeIndex + 1) % historyRows
    }

    func encode(into enc: MTLRenderCommandEncoder, uniforms: inout SceneUniforms) {
        enc.setRenderPipelineState(pipeline)
        var u = (aspect: uniforms.aspect,
                 bandCount: Int32(bandCount),
                 historyRows: Int32(historyRows),
                 writeIndex: Int32(writeIndex))
        enc.setFragmentBytes(&u, length: MemoryLayout.size(ofValue: u), index: 1)
        enc.setFragmentTexture(paletteTexture, index: 0)
        enc.setFragmentTexture(historyTexture, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
}
