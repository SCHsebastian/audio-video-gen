import Metal
import simd
import Domain
import VisualizerKernels

/// Floor-anchored Winamp-style spectrum bars with floating peak caps. Audio
/// goes through the canonical pipeline: log-frequency rebinning → dB scale
/// with +3 dB/oct slope → asymmetric attack/release smoothing → peak cap.
/// All heavy math lives in `vk_bars_process` so this file just owns buffer
/// sizing and per-frame encoding.
final class BarsScene: VisualizerScene {
    // Visual bar count — randomized in {24, 32, 48, 64}. The buffer capacity
    // is the maximum so we can swap counts without reallocating.
    private static let maxBars = 96
    private var barCount = 64

    private var displayed = [Float](repeating: 0, count: maxBars)
    private var peaks     = [Float](repeating: 0, count: maxBars)
    private var state     = [Float](repeating: 0, count: maxBars * 2)  // smooth + holdTimer

    private var pipelineBody: MTLRenderPipelineState!
    private var pipelinePeak: MTLRenderPipelineState!
    private var heightsBuffer: MTLBuffer!
    private var peaksBuffer:   MTLBuffer!
    private var paletteTexture: MTLTexture!

    // Beat flash envelope — decays in scene; lights the bar bodies for ~80 ms.
    private var beatFlash: Float = 0

    // Sample rate the analyzer publishes — matches CompositionRoot's wiring.
    private static let sampleRateHz: Float = 48_000

    func build(device: MTLDevice, library: MTLLibrary, paletteTexture: MTLTexture) throws {
        self.paletteTexture = paletteTexture

        let body = MTLRenderPipelineDescriptor()
        body.vertexFunction = library.makeFunction(name: "bars_vertex")
        body.fragmentFunction = library.makeFunction(name: "bars_fragment")
        body.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        body.colorAttachments[0].isBlendingEnabled = true
        body.colorAttachments[0].rgbBlendOperation = .add
        body.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        body.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        do { pipelineBody = try device.makeRenderPipelineState(descriptor: body) }
        catch { throw RenderError.pipelineCreationFailed(name: "Bars.body") }

        let peak = MTLRenderPipelineDescriptor()
        peak.vertexFunction = library.makeFunction(name: "bars_peak_vertex")
        peak.fragmentFunction = library.makeFunction(name: "bars_fragment")
        peak.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        peak.colorAttachments[0].isBlendingEnabled = true
        peak.colorAttachments[0].rgbBlendOperation = .add
        peak.colorAttachments[0].sourceRGBBlendFactor = .one
        peak.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        do { pipelinePeak = try device.makeRenderPipelineState(descriptor: peak) }
        catch { throw RenderError.pipelineCreationFailed(name: "Bars.peak") }

        let bytes = Self.maxBars * MemoryLayout<Float>.size
        heightsBuffer = device.makeBuffer(length: bytes, options: .storageModeShared)
        peaksBuffer   = device.makeBuffer(length: bytes, options: .storageModeShared)
    }

    func randomize() {
        // Stylistic count switch. Reset the smoothing state so we don't bleed
        // values from the previous mapping (each `k` maps to a different
        // frequency band depending on `outCount`).
        let options = [24, 32, 48, 64]
        let next = options.randomElement() ?? 64
        if next != barCount {
            barCount = next
            for i in 0..<state.count    { state[i]    = 0 }
            for i in 0..<displayed.count{ displayed[i] = 0 }
            for i in 0..<peaks.count    { peaks[i]    = 0 }
        }
    }

    func update(spectrum: SpectrumFrame, waveform: [Float], beat: BeatEvent?, dt: Float) {
        // Beat flash envelope — `1 - exp(-dt/tau)` so refresh-rate independent.
        if let b = beat { beatFlash = max(beatFlash, b.strength) }
        beatFlash *= expf(-dt / 0.080)

        spectrum.bands.withUnsafeBufferPointer { inPtr in
            displayed.withUnsafeMutableBufferPointer { outPtr in
                state.withUnsafeMutableBufferPointer { statePtr in
                    peaks.withUnsafeMutableBufferPointer { peakPtr in
                        vk_bars_process(inPtr.baseAddress,
                                        UInt32(spectrum.bands.count),
                                        outPtr.baseAddress,
                                        UInt32(barCount),
                                        statePtr.baseAddress,
                                        peakPtr.baseAddress,
                                        Self.sampleRateHz,
                                        dt)
                    }
                }
            }
        }
        let n = barCount * MemoryLayout<Float>.size
        memcpy(heightsBuffer.contents(), displayed, n)
        memcpy(peaksBuffer.contents(),   peaks,     n)
    }

    func encode(into enc: MTLRenderCommandEncoder, uniforms: inout SceneUniforms) {
        var bu = (aspect: uniforms.aspect,
                  time:   uniforms.time,
                  barCount: Int32(barCount),
                  beatFlash: beatFlash)

        // Body pass.
        enc.setRenderPipelineState(pipelineBody)
        enc.setVertexBuffer(heightsBuffer, offset: 0, index: 0)
        enc.setVertexBytes(&bu, length: MemoryLayout.size(ofValue: bu), index: 2)
        enc.setFragmentBytes(&bu, length: MemoryLayout.size(ofValue: bu), index: 2)
        enc.setFragmentTexture(paletteTexture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: barCount)

        // Peak cap pass.
        enc.setRenderPipelineState(pipelinePeak)
        enc.setVertexBuffer(peaksBuffer, offset: 0, index: 0)
        enc.setVertexBytes(&bu, length: MemoryLayout.size(ofValue: bu), index: 2)
        enc.setFragmentBytes(&bu, length: MemoryLayout.size(ofValue: bu), index: 2)
        enc.setFragmentTexture(paletteTexture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: barCount)
    }
}
