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
    private var pipeline: MTLRenderPipelineState!
    private var paletteTexture: MTLTexture!

    private var scratchIn  = [Float](repeating: 0, count: 1024)
    private var scratchOut = [Float](repeating: 0, count: 512)

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
        samplesBuffer = device.makeBuffer(length: displayCount * MemoryLayout<Float>.size,
                                          options: .storageModeShared)
    }

    func update(spectrum: SpectrumFrame, waveform: [Float], beat: BeatEvent?, dt: Float) {
        rms = spectrum.rms

        // Beat envelope — `1 - exp(-dt/τ)` decay so 30/60/120 Hz refreshes look the same.
        if let b = beat { beatBoost = max(beatBoost, b.strength) }
        beatBoost *= expf(-dt / 0.250)

        // Copy the tail of the live waveform into the fixed-size scratch input,
        // zero-padding the front if the producer hasn't fed us a full frame yet.
        let n = inputCount
        let tail = waveform.suffix(n)
        let pad = n - tail.count
        for i in 0..<pad { scratchIn[i] = 0 }
        var idx = pad
        for v in tail { scratchIn[idx] = v; idx += 1 }

        // Track peak amplitude with a fast-attack / slow-release follower.
        var peakNow: Float = 0
        for v in scratchIn { let a = abs(v); if a > peakNow { peakNow = a } }
        let attackTau: Float = 0.020
        let releaseTau: Float = 1.200
        if peakNow > peakEnv {
            peakEnv += (peakNow - peakEnv) * (1.0 - expf(-dt / attackTau))
        } else {
            peakEnv += (peakNow - peakEnv) * (1.0 - expf(-dt / releaseTau))
        }
        let targetPeak: Float = 0.70
        let gain: Float = max(1.0, min(8.0, targetPeak / max(peakEnv, 0.05)))

        scratchIn.withUnsafeBufferPointer { inPtr in
            scratchOut.withUnsafeMutableBufferPointer { outPtr in
                vk_scope_prepare(inPtr.baseAddress,
                                 UInt32(n),
                                 outPtr.baseAddress,
                                 UInt32(displayCount),
                                 gain)
            }
        }
        memcpy(samplesBuffer.contents(), scratchOut, displayCount * MemoryLayout<Float>.size)
    }

    func encode(into enc: MTLRenderCommandEncoder, uniforms: inout SceneUniforms) {
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(samplesBuffer, offset: 0, index: 0)
        var count = UInt32(displayCount)
        enc.setVertexBytes(&count, length: 4, index: 1)
        // Halo widens with RMS so loud passages bloom; core stays constant.
        var su = ScopeU(aspect: uniforms.aspect,
                        time: uniforms.time,
                        coreRadius: 0.004,
                        haloSigma: 0.018 + min(0.040, rms * 0.10),
                        beatBoost: beatBoost)
        enc.setVertexBytes(&su, length: MemoryLayout.size(ofValue: su), index: 2)
        enc.setFragmentBytes(&su, length: MemoryLayout.size(ofValue: su), index: 0)
        enc.setFragmentTexture(paletteTexture, index: 0)
        // One quad per segment between consecutive samples.
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                           instanceCount: displayCount - 1)
    }

    private struct ScopeU {
        var aspect: Float
        var time: Float
        var coreRadius: Float
        var haloSigma: Float
        var beatBoost: Float
    }
}
