import Metal
import simd
import Domain
import VisualizerKernels

/// Phosphor-persistence Lissajous / parametric trace. The CPU generates a
/// dense parametric curve, runs Catmull-Rom subdivision for a continuous
/// "phosphor beam" feel, then a 3-pass GPU pipeline accumulates the trace
/// into a ping-pong texture with exponential decay (~80 ms half-life)
/// before compositing to the drawable.
///
/// NOTE: A true mastering-grade goniometer needs the original stereo PCM
/// (L/R interleaved) — see `docs/superpowers/specs/.../lissajous.md`.
/// Until the capture pipeline exposes a stereo buffer the trace is the
/// parametric figure (which is still musically interesting and visually
/// rich), updated to RMS/bass.
final class LissajousScene: VisualizerScene {
    private static let controlCount = 256          // parametric "control" points
    private static let subdivs: UInt32 = 8         // Catmull-Rom subdivisions per span
    // After Catmull-Rom: (controlCount - 3) * subdivs + 1 trace points.
    private static let tracePoints: Int = (controlCount - 3) * Int(subdivs) + 1

    private var pipelineDecay: MTLRenderPipelineState!
    private var pipelineTrace: MTLRenderPipelineState!
    private var pipelineComposite: MTLRenderPipelineState!

    private var device: MTLDevice!
    private var paletteTexture: MTLTexture!
    private var pingPong: [MTLTexture] = []        // 2 entries; accumulator (rgba16Float)
    private var currIndex: Int = 0
    private var lastSize: (w: Int, h: Int) = (0, 0)

    // Geometry buffers — control points (CPU built), then smoothed trace.
    private var controlScratch = [Float](repeating: 0, count: 256 * 2)
    private var traceBuffer: MTLBuffer!

    // Audio state.
    private var time: Float = 0
    private var rms: Float = 0
    private var bass: Float = 0
    private var beatEnv: Float = 0

    // Look knobs — `randomize()` rolls these.
    private var aBase: Float = 3
    private var bBase: Float = 2
    private var aJitter: Float = 1.0
    private var bJitter: Float = 1.0
    private var phaseOffset: Float = 0
    private var petalsBase: Int32 = 5
    private var rotation: Float = 0
    private var modeIsRose: Bool = false
    private var tauSec: Float = 0.080              // phosphor decay τ

    func build(device: MTLDevice, library: MTLLibrary, paletteTexture: MTLTexture) throws {
        self.device = device
        self.paletteTexture = paletteTexture

        let decay = MTLRenderPipelineDescriptor()
        decay.vertexFunction = library.makeFunction(name: "li_full_vertex")
        decay.fragmentFunction = library.makeFunction(name: "li_decay_fragment")
        decay.colorAttachments[0].pixelFormat = .rgba16Float
        decay.colorAttachments[0].isBlendingEnabled = false
        do { pipelineDecay = try device.makeRenderPipelineState(descriptor: decay) }
        catch { throw RenderError.pipelineCreationFailed(name: "Lissajous.decay") }

        let trace = MTLRenderPipelineDescriptor()
        trace.vertexFunction = library.makeFunction(name: "li_trace_vertex")
        trace.fragmentFunction = library.makeFunction(name: "li_trace_fragment")
        trace.colorAttachments[0].pixelFormat = .rgba16Float
        trace.colorAttachments[0].isBlendingEnabled = true
        trace.colorAttachments[0].rgbBlendOperation = .add
        trace.colorAttachments[0].sourceRGBBlendFactor = .one
        trace.colorAttachments[0].destinationRGBBlendFactor = .one   // additive
        do { pipelineTrace = try device.makeRenderPipelineState(descriptor: trace) }
        catch { throw RenderError.pipelineCreationFailed(name: "Lissajous.trace") }

        let comp = MTLRenderPipelineDescriptor()
        comp.vertexFunction = library.makeFunction(name: "li_full_vertex")
        comp.fragmentFunction = library.makeFunction(name: "li_composite_fragment")
        comp.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        comp.colorAttachments[0].isBlendingEnabled = false
        do { pipelineComposite = try device.makeRenderPipelineState(descriptor: comp) }
        catch { throw RenderError.pipelineCreationFailed(name: "Lissajous.composite") }

        traceBuffer = device.makeBuffer(length: Self.tracePoints * MemoryLayout<SIMD2<Float>>.size,
                                        options: .storageModeShared)
        pingPong = []
        lastSize = (0, 0)
    }

    func randomize() {
        modeIsRose = Bool.random()
        aBase = Float(Int.random(in: 2...7))
        bBase = Float(Int.random(in: 2...7))
        aJitter = Float.random(in: 0.5...1.8)
        bJitter = Float.random(in: 0.5...1.8)
        phaseOffset = Float.random(in: 0..<(.pi * 2))
        petalsBase = Int32.random(in: 3...9)
        rotation = Float.random(in: 0..<(.pi * 2))
        tauSec = Float.random(in: 0.060...0.140)
    }

    func update(spectrum: SpectrumFrame, waveform: [Float], beat: BeatEvent?, dt: Float) {
        time += dt
        rms = spectrum.rms
        let bassTgt = spectrum.bands.prefix(8).reduce(0, +) / 8
        bass += (bassTgt - bass) * (1.0 - expf(-dt / 0.10))
        if let b = beat { beatEnv = max(beatEnv, b.strength) }
        beatEnv *= expf(-dt / 0.200)

        // Build control points via the existing parametric kernels.
        let ctrlPtr = controlScratch.withUnsafeMutableBufferPointer { $0.baseAddress! }
        if modeIsRose {
            let petals = petalsBase + Int32(min(3.0, bass * 30))
            vk_rose(ctrlPtr, UInt32(Self.controlCount), time + rotation, petals, rms)
        } else {
            let a = aBase + bass * aJitter * 4
            let b = bBase + rms  * bJitter * 4
            let delta = sin(time * 0.4) * .pi + phaseOffset
            vk_lissajous(ctrlPtr, UInt32(Self.controlCount), time + rotation, a, b, delta, rms)
        }

        // Catmull-Rom subdivision into the GPU buffer.
        let outPtr = traceBuffer.contents().bindMemory(to: Float.self, capacity: Self.tracePoints * 2)
        vk_catmull_rom(ctrlPtr, UInt32(Self.controlCount), outPtr, Self.subdivs)
    }

    /// Pre-pass: decay the accumulator, then additively draw the trace into it.
    func prepass(into cmd: MTLCommandBuffer, drawableSize size: CGSize, aspect: Float, dt: Float) {
        ensureTextures(width: max(2, Int(size.width)), height: max(2, Int(size.height)))
        let prev = pingPong[currIndex]
        let curr = pingPong[1 - currIndex]

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = curr
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }

        // Decay pass — multiplicative; not additive.
        var decay = expf(-dt / max(0.001, tauSec))
        enc.setRenderPipelineState(pipelineDecay)
        enc.setFragmentBytes(&decay, length: MemoryLayout<Float>.size, index: 0)
        enc.setFragmentTexture(prev, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

        // Trace pass — additive.
        var tu = TraceU(aspect: aspect,
                        coreRadius: 0.0025,
                        haloSigma: 0.012 + min(0.020, rms * 0.05),
                        intensity: 0.70 + 0.30 * rms + 0.40 * beatEnv)
        enc.setRenderPipelineState(pipelineTrace)
        enc.setVertexBuffer(traceBuffer, offset: 0, index: 0)
        var pc = UInt32(Self.tracePoints)
        enc.setVertexBytes(&pc, length: 4, index: 1)
        enc.setVertexBytes(&tu, length: MemoryLayout.size(ofValue: tu), index: 2)
        enc.setFragmentBytes(&tu, length: MemoryLayout.size(ofValue: tu), index: 0)
        enc.setFragmentTexture(paletteTexture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                           instanceCount: Self.tracePoints - 1)

        enc.endEncoding()
        currIndex = 1 - currIndex
    }

    func encode(into enc: MTLRenderCommandEncoder, uniforms: inout SceneUniforms) {
        guard !pingPong.isEmpty else { return }
        enc.setRenderPipelineState(pipelineComposite)
        var cu = CompU(aspect: uniforms.aspect, gamma: 0.85, gain: 1.3, beat: beatEnv)
        enc.setFragmentBytes(&cu, length: MemoryLayout.size(ofValue: cu), index: 0)
        enc.setFragmentTexture(pingPong[currIndex], index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private func ensureTextures(width: Int, height: Int) {
        if pingPong.count == 2 && lastSize.w == width && lastSize.h == height { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        var arr: [MTLTexture] = []
        for _ in 0..<2 {
            guard let t = device.makeTexture(descriptor: d) else { return }
            arr.append(t)
        }
        pingPong = arr
        lastSize = (width, height)
        currIndex = 0
    }

    private struct TraceU {
        var aspect: Float; var coreRadius: Float; var haloSigma: Float; var intensity: Float
    }
    private struct CompU {
        var aspect: Float; var gamma: Float; var gain: Float; var beat: Float
    }
}
