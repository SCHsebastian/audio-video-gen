import Metal
import Domain
import VisualizerKernels

/// Phosphor-style oscilloscope with Schmitt-trigger sync and SDF anti-aliasing.
/// The kernel locks the displayed window to the first positive-going zero-
/// crossing past the first quarter of the input buffer, so a steady tone holds
/// still on the display instead of jittering frame-to-frame.
final class ScopeScene: VisualizerScene {
    private let inputCount  = 1024
    private let displayCount = 512

    private var samplesBuffer: MTLBuffer!
    // Secondary trace buffer — used as the R channel when the source is stereo.
    private var samplesBufferR: MTLBuffer!
    private var pipeline: MTLRenderPipelineState!
    private var paletteTexture: MTLTexture!

    private var scratchIn  = [Float](repeating: 0, count: 1024)
    private var scratchOut = [Float](repeating: 0, count: 512)
    // Stereo scratch — used only when the WaveformBuffer carries true L/R data.
    private var scratchInL  = [Float](repeating: 0, count: 1024)
    private var scratchInR  = [Float](repeating: 0, count: 1024)
    private var scratchOutL = [Float](repeating: 0, count: 512)
    private var scratchOutR = [Float](repeating: 0, count: 512)
    private var lastStereo: Bool = false

    // Auto-gain envelope follower — fast attack, slow release. Keeps quiet
    // signals readable without amplifying silence-floor self-noise.
    private var peakEnv: Float = 0.05
    private var rms: Float = 0
    private var beatBoost: Float = 0

    func build(device: MTLDevice, library: MTLLibrary, paletteTexture: MTLTexture) throws {
        self.paletteTexture = paletteTexture
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "scope_vertex")
        desc.fragmentFunction = library.makeFunction(name: "scope_fragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        do { pipeline = try device.makeRenderPipelineState(descriptor: desc) }
        catch { throw RenderError.pipelineCreationFailed(name: "Scope") }
        samplesBuffer  = device.makeBuffer(length: displayCount * MemoryLayout<Float>.size,
                                           options: .storageModeShared)
        samplesBufferR = device.makeBuffer(length: displayCount * MemoryLayout<Float>.size,
                                           options: .storageModeShared)
    }

    func update(spectrum: SpectrumFrame, waveform: WaveformBuffer, beat: BeatEvent?, dt: Float) {
        rms = spectrum.rms

        // Beat envelope — `1 - exp(-dt/τ)` decay so 30/60/120 Hz refreshes look the same.
        if let b = beat { beatBoost = max(beatBoost, b.strength) }
        beatBoost *= expf(-dt / 0.250)

        let n = inputCount
        let stereo = waveform.isStereo
        lastStereo = stereo
        if stereo {
            copyTail(of: waveform.left,  into: &scratchInL, length: n)
            copyTail(of: waveform.right, into: &scratchInR, length: n)
            let peakNow = max(peakAbs(of: scratchInL), peakAbs(of: scratchInR))
            let gain = updateGain(peakNow: peakNow, dt: dt)

            scratchInL.withUnsafeBufferPointer { inPtr in
                scratchOutL.withUnsafeMutableBufferPointer { outPtr in
                    vk_scope_prepare(inPtr.baseAddress, UInt32(n),
                                     outPtr.baseAddress, UInt32(displayCount), gain)
                }
            }
            scratchInR.withUnsafeBufferPointer { inPtr in
                scratchOutR.withUnsafeMutableBufferPointer { outPtr in
                    vk_scope_prepare(inPtr.baseAddress, UInt32(n),
                                     outPtr.baseAddress, UInt32(displayCount), gain)
                }
            }
            // Compress each trace into a half-height band and offset vertically.
            // L sits centred at y=+0.4 with ±0.4 amplitude, R at y=-0.4 ± 0.4.
            for i in 0..<displayCount {
                scratchOutL[i] = scratchOutL[i] * 0.4 + 0.4
                scratchOutR[i] = scratchOutR[i] * 0.4 - 0.4
            }
            memcpy(samplesBuffer.contents(),  scratchOutL, displayCount * MemoryLayout<Float>.size)
            memcpy(samplesBufferR.contents(), scratchOutR, displayCount * MemoryLayout<Float>.size)
        } else {
            copyTail(of: waveform.mono, into: &scratchIn, length: n)
            let gain = updateGain(peakNow: peakAbs(of: scratchIn), dt: dt)
            scratchIn.withUnsafeBufferPointer { inPtr in
                scratchOut.withUnsafeMutableBufferPointer { outPtr in
                    vk_scope_prepare(inPtr.baseAddress, UInt32(n),
                                     outPtr.baseAddress, UInt32(displayCount), gain)
                }
            }
            memcpy(samplesBuffer.contents(), scratchOut, displayCount * MemoryLayout<Float>.size)
        }
    }

    /// Copy the most recent `length` samples from `src` into `dst`, zero-padding
    /// the front when the producer hasn't yet fed a full frame.
    private func copyTail(of src: [Float], into dst: inout [Float], length n: Int) {
        let tail = src.suffix(n)
        let pad = n - tail.count
        for i in 0..<pad { dst[i] = 0 }
        var idx = pad
        for v in tail { dst[idx] = v; idx += 1 }
    }

    private func peakAbs(of buffer: [Float]) -> Float {
        var p: Float = 0
        for v in buffer { let a = abs(v); if a > p { p = a } }
        return p
    }

    /// Shared fast-attack / slow-release peak follower → target-peak gain.
    private func updateGain(peakNow: Float, dt: Float) -> Float {
        let attackTau: Float = 0.020
        let releaseTau: Float = 1.200
        if peakNow > peakEnv {
            peakEnv += (peakNow - peakEnv) * (1.0 - expf(-dt / attackTau))
        } else {
            peakEnv += (peakNow - peakEnv) * (1.0 - expf(-dt / releaseTau))
        }
        let targetPeak: Float = 0.70
        return max(1.0, min(8.0, targetPeak / max(peakEnv, 0.05)))
    }

    func encode(into enc: MTLRenderCommandEncoder, uniforms: inout SceneUniforms) {
        enc.setRenderPipelineState(pipeline)
        var count = UInt32(displayCount)
        // Halo widens with RMS so loud passages bloom; core stays constant.
        var su = ScopeU(aspect: uniforms.aspect,
                        time: uniforms.time,
                        coreRadius: 0.004,
                        haloSigma: 0.018 + min(0.040, rms * 0.10),
                        beatBoost: beatBoost)
        enc.setFragmentBytes(&su, length: MemoryLayout.size(ofValue: su), index: 0)
        enc.setFragmentTexture(paletteTexture, index: 0)

        // L trace (or mono trace when the source isn't stereo).
        enc.setVertexBuffer(samplesBuffer, offset: 0, index: 0)
        enc.setVertexBytes(&count, length: 4, index: 1)
        enc.setVertexBytes(&su, length: MemoryLayout.size(ofValue: su), index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                           instanceCount: displayCount - 1)
        // R trace — only drawn when the most recent update saw stereo data.
        if lastStereo {
            enc.setVertexBuffer(samplesBufferR, offset: 0, index: 0)
            enc.setVertexBytes(&count, length: 4, index: 1)
            enc.setVertexBytes(&su, length: MemoryLayout.size(ofValue: su), index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                               instanceCount: displayCount - 1)
        }
    }

    private struct ScopeU {
        var aspect: Float
        var time: Float
        var coreRadius: Float
        var haloSigma: Float
        var beatBoost: Float
    }
}
