import Metal
import simd
import Domain
import VisualizerKernels

/// Spectrum bars with two design-only enhancements over the classic layout:
///   * Each bar carries a Gaussian halo around its core line so neighbours'
///     halos overlap into a continuous neon ribbon when peaks cluster.
///   * In mono mode a dim mirror reflection paints below the floor line for
///     a glossy-stage feel. Colours stay tied to the user's palette exactly
///     as before (height-driven body gradient, brightest tap for peak caps).
///
/// In stereo mode the same N bars are drawn twice from the canvas centre:
/// L grows upward, R grows downward (foobar2000 mirror VU). No reflection —
/// the L/R split already provides vertical symmetry.
final class BarsScene: VisualizerScene {
    private static let maxBars = 96
    private var barCount = 64

    private var displayed = [Float](repeating: 0, count: maxBars)
    private var peaks     = [Float](repeating: 0, count: maxBars)
    private var state     = [Float](repeating: 0, count: maxBars * 2)
    private var displayedR = [Float](repeating: 0, count: maxBars)
    private var peaksR     = [Float](repeating: 0, count: maxBars)
    private var stateR     = [Float](repeating: 0, count: maxBars * 2)
    private var stateL     = [Float](repeating: 0, count: maxBars * 2)

    private var pipelineBody: MTLRenderPipelineState!
    private var pipelinePeak: MTLRenderPipelineState!
    private var heightsBuffer: MTLBuffer!
    private var peaksBuffer:   MTLBuffer!
    private var heightsBufferR: MTLBuffer!
    private var peaksBufferR:   MTLBuffer!
    private var paletteTexture: MTLTexture!

    private var beatFlash: Float = 0
    private var lastStereo: Bool = false

    private static let sampleRateHz: Float = 48_000

    func build(device: MTLDevice, library: MTLLibrary, paletteTexture: MTLTexture) throws {
        self.paletteTexture = paletteTexture

        // Body — alpha blend so the Gaussian halo's varying alpha composites
        // smoothly over the background and over previously drawn bars.
        let body = MTLRenderPipelineDescriptor()
        body.vertexFunction = library.makeFunction(name: "bars_vertex")
        body.fragmentFunction = library.makeFunction(name: "bars_fragment")
        body.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        body.colorAttachments[0].isBlendingEnabled = true
        body.colorAttachments[0].rgbBlendOperation = .add
        body.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        body.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        body.colorAttachments[0].alphaBlendOperation = .add
        body.colorAttachments[0].sourceAlphaBlendFactor = .one
        body.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do { pipelineBody = try device.makeRenderPipelineState(descriptor: body) }
        catch { throw RenderError.pipelineCreationFailed(name: "Bars.body") }

        // Peak — additive so caps read as bright neon strokes over the body.
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
        heightsBuffer  = device.makeBuffer(length: bytes, options: .storageModeShared)
        peaksBuffer    = device.makeBuffer(length: bytes, options: .storageModeShared)
        heightsBufferR = device.makeBuffer(length: bytes, options: .storageModeShared)
        peaksBufferR   = device.makeBuffer(length: bytes, options: .storageModeShared)
    }

    func randomize() {
        let options = [24, 32, 48, 64]
        let next = options.randomElement() ?? 64
        if next != barCount {
            barCount = next
            for i in 0..<state.count      { state[i]      = 0; stateL[i] = 0; stateR[i] = 0 }
            for i in 0..<displayed.count  { displayed[i]  = 0; displayedR[i] = 0 }
            for i in 0..<peaks.count      { peaks[i]      = 0; peaksR[i]     = 0 }
        }
    }

    func update(spectrum: SpectrumFrame, waveform: WaveformBuffer, beat: BeatEvent?, dt: Float) {
        if let b = beat { beatFlash = max(beatFlash, b.strength) }
        beatFlash *= expf(-dt / 0.080)

        let stereo = !spectrum.leftBands.isEmpty && !spectrum.rightBands.isEmpty
        lastStereo = stereo
        if stereo {
            processChannel(input: spectrum.leftBands,
                           displayed: &displayed, state: &stateL, peaks: &peaks,
                           outCount: barCount, dt: dt)
            processChannel(input: spectrum.rightBands,
                           displayed: &displayedR, state: &stateR, peaks: &peaksR,
                           outCount: barCount, dt: dt)
        } else {
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
        }
        let n = barCount * MemoryLayout<Float>.size
        memcpy(heightsBuffer.contents(), displayed,  n)
        memcpy(peaksBuffer.contents(),   peaks,      n)
        if stereo {
            memcpy(heightsBufferR.contents(), displayedR, n)
            memcpy(peaksBufferR.contents(),   peaksR,     n)
        }
    }

    private func processChannel(input: [Float],
                                displayed: inout [Float],
                                state: inout [Float],
                                peaks: inout [Float],
                                outCount: Int, dt: Float) {
        input.withUnsafeBufferPointer { inPtr in
            displayed.withUnsafeMutableBufferPointer { outPtr in
                state.withUnsafeMutableBufferPointer { statePtr in
                    peaks.withUnsafeMutableBufferPointer { peakPtr in
                        vk_bars_process(inPtr.baseAddress,
                                        UInt32(input.count),
                                        outPtr.baseAddress,
                                        UInt32(outCount),
                                        statePtr.baseAddress,
                                        peakPtr.baseAddress,
                                        Self.sampleRateHz,
                                        dt)
                    }
                }
            }
        }
    }

    func encode(into enc: MTLRenderCommandEncoder, uniforms: inout SceneUniforms) {
        if lastStereo {
            // L grows up, R grows down — symmetric, no reflection needed.
            drawPass(into: enc, uniforms: uniforms,
                     heights: heightsBuffer, peaks: peaksBuffer,
                     yOrigin: 0.0, yDir:  1.0, yScale: 0.95, reflectFactor: 1.0,
                     drawPeaks: true)
            drawPass(into: enc, uniforms: uniforms,
                     heights: heightsBufferR, peaks: peaksBufferR,
                     yOrigin: 0.0, yDir: -1.0, yScale: 0.95, reflectFactor: 1.0,
                     drawPeaks: true)
        } else {
            // Floor sits below centre so the reflection fits underneath. Bars
            // grow upward almost to the top edge; reflection takes the
            // remaining bottom slice at a dim alpha.
            let floor: Float = -0.60
            drawPass(into: enc, uniforms: uniforms,
                     heights: heightsBuffer, peaks: peaksBuffer,
                     yOrigin: floor, yDir: -1.0, yScale: 0.40, reflectFactor: 0.32,
                     drawPeaks: false)
            drawPass(into: enc, uniforms: uniforms,
                     heights: heightsBuffer, peaks: peaksBuffer,
                     yOrigin: floor, yDir:  1.0, yScale: 1.50, reflectFactor: 1.0,
                     drawPeaks: true)
        }
    }

    private func drawPass(into enc: MTLRenderCommandEncoder,
                          uniforms: SceneUniforms,
                          heights: MTLBuffer, peaks: MTLBuffer,
                          yOrigin: Float, yDir: Float, yScale: Float, reflectFactor: Float,
                          drawPeaks: Bool) {
        var bu = BU(aspect: uniforms.aspect,
                    time: uniforms.time,
                    barCount: Int32(barCount),
                    beatFlash: beatFlash,
                    yOrigin: yOrigin, yDir: yDir, yScale: yScale,
                    reflectFactor: reflectFactor)

        enc.setRenderPipelineState(pipelineBody)
        enc.setVertexBuffer(heights, offset: 0, index: 0)
        enc.setVertexBytes(&bu, length: MemoryLayout.size(ofValue: bu), index: 2)
        enc.setFragmentBytes(&bu, length: MemoryLayout.size(ofValue: bu), index: 2)
        enc.setFragmentTexture(paletteTexture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: barCount)

        if drawPeaks {
            enc.setRenderPipelineState(pipelinePeak)
            enc.setVertexBuffer(peaks, offset: 0, index: 0)
            enc.setVertexBytes(&bu, length: MemoryLayout.size(ofValue: bu), index: 2)
            enc.setFragmentBytes(&bu, length: MemoryLayout.size(ofValue: bu), index: 2)
            enc.setFragmentTexture(paletteTexture, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: barCount)
        }
    }

    private struct BU {
        var aspect: Float
        var time: Float
        var barCount: Int32
        var beatFlash: Float
        var yOrigin: Float
        var yDir: Float
        var yScale: Float
        var reflectFactor: Float
    }
}
