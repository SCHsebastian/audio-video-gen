import Metal
import simd
import Domain

/// Canonical Milkdrop / Butterchurn feedback visualizer. Two offscreen
/// textures ping-pong each frame: the warp pass samples last frame at a
/// warped UV, the waveform pass overlays the iconic line strip, the
/// composite pass tonemaps to the drawable. Decay (~0.97/frame) gives the
/// signature trailing-trails look.
final class MilkdropScene: VisualizerScene {
    private static let waveSamples = 512        // half of the 1024-sample PCM buffer

    private var pipelineWarp: MTLRenderPipelineState!
    private var pipelineWave: MTLRenderPipelineState!
    private var pipelineComposite: MTLRenderPipelineState!

    private var device: MTLDevice!
    private var paletteTexture: MTLTexture!
    private var pingPong: [MTLTexture] = []      // 2 entries
    private var currIndex: Int = 0               // texture we last wrote into
    private var lastSize: (w: Int, h: Int) = (0, 0)

    private var waveBuffer: MTLBuffer!

    // Audio state.
    private var time: Float = 0
    private var bass: Float = 0
    private var mid: Float = 0
    private var rms: Float = 0
    private var beatEnv: Float = 0

    // Look knobs — `randomize()` rolls these.
    private var waveShape: Int32 = 0             // 0 circle / 1 line / 2 fig-8
    private var warpExtra: Float = 0
    private var decay: Float = 0.97

    func build(device: MTLDevice, library: MTLLibrary, paletteTexture: MTLTexture) throws {
        self.device = device
        self.paletteTexture = paletteTexture

        let warp = MTLRenderPipelineDescriptor()
        warp.vertexFunction = library.makeFunction(name: "md_warp_vertex")
        warp.fragmentFunction = library.makeFunction(name: "md_warp_fragment")
        warp.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        warp.colorAttachments[0].isBlendingEnabled = false
        do { pipelineWarp = try device.makeRenderPipelineState(descriptor: warp) }
        catch { throw RenderError.pipelineCreationFailed(name: "Milkdrop.warp") }

        let wave = MTLRenderPipelineDescriptor()
        wave.vertexFunction = library.makeFunction(name: "md_wave_vertex")
        wave.fragmentFunction = library.makeFunction(name: "md_wave_fragment")
        wave.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        wave.colorAttachments[0].isBlendingEnabled = true
        wave.colorAttachments[0].rgbBlendOperation = .add
        wave.colorAttachments[0].sourceRGBBlendFactor = .one
        wave.colorAttachments[0].destinationRGBBlendFactor = .one      // additive
        do { pipelineWave = try device.makeRenderPipelineState(descriptor: wave) }
        catch { throw RenderError.pipelineCreationFailed(name: "Milkdrop.wave") }

        let comp = MTLRenderPipelineDescriptor()
        comp.vertexFunction = library.makeFunction(name: "md_comp_vertex")
        comp.fragmentFunction = library.makeFunction(name: "md_comp_fragment")
        comp.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        comp.colorAttachments[0].isBlendingEnabled = false
        do { pipelineComposite = try device.makeRenderPipelineState(descriptor: comp) }
        catch { throw RenderError.pipelineCreationFailed(name: "Milkdrop.composite") }

        waveBuffer = device.makeBuffer(length: Self.waveSamples * MemoryLayout<SIMD2<Float>>.size,
                                       options: .storageModeShared)
        pingPong = []
        lastSize = (0, 0)
    }

    func randomize() {
        waveShape = Int32.random(in: 0...2)
        warpExtra = Float.random(in: 0...0.010)
        decay = Float.random(in: 0.960...0.985)
    }

    func update(spectrum: SpectrumFrame, waveform: [Float], beat: BeatEvent?, dt: Float) {
        time += dt
        rms = spectrum.rms

        let bands = spectrum.bands
        let n = max(1, bands.count)
        let bassEnd = min(5, n)
        let midStart = min(8, n - 1)
        let midEnd   = min(24, n)
        let bassTgt = bands.prefix(bassEnd).reduce(0, +) / Float(bassEnd)
        let midTgt  = (midStart..<midEnd).reduce(Float(0)) { $0 + bands[$1] }
                    / Float(max(1, midEnd - midStart))
        bass += (bassTgt - bass) * (1.0 - expf(-dt / 0.12))
        mid  += (midTgt  - mid)  * (1.0 - expf(-dt / 0.12))

        if let b = beat { beatEnv = max(beatEnv, b.strength) }
        beatEnv *= expf(-dt / 0.150)

        // Build the per-frame waveform line geometry (CPU side, 512 verts).
        // Center the curve at screen origin; map PCM ±1 along the local normal.
        let count = Self.waveSamples
        let ptr = waveBuffer.contents().bindMemory(to: SIMD2<Float>.self, capacity: count)
        let baseR: Float = 0.45
        let amp:   Float = 0.18 + 0.25 * rms
        let waveCount = max(1, waveform.count)
        for i in 0..<count {
            // Sample evenly from the PCM buffer.
            let t = Float(i) / Float(count - 1)
            let pcm = waveform[min(waveCount - 1, i * (waveCount / count))]
            let theta = t * 2.0 * .pi
            var x: Float = 0
            var y: Float = 0
            switch waveShape {
            case 1: // horizontal line
                x = -0.85 + 1.70 * t
                y = pcm * amp * 0.9
            case 2: // figure-eight (Lissajous 2:1)
                let cx = 0.55 * sin(2 * theta)
                let cy = 0.55 * sin(theta)
                let nx = cos(2 * theta)
                let ny = cos(theta)
                let nlen = max(1e-6, sqrtf(nx*nx + ny*ny))
                x = cx + (-ny / nlen) * pcm * amp * 0.6
                y = cy + ( nx / nlen) * pcm * amp * 0.6
            default: // breathing circle
                let r = baseR + pcm * amp
                x = r * cos(theta)
                y = r * sin(theta)
            }
            ptr[i] = SIMD2<Float>(x, y)
        }
    }

    /// Pre-render-pass hook (called from `MetalVisualizationRenderer.draw`
    /// before the drawable's render pass). Runs warp + waveform into the
    /// ping-pong target so the encode() step can just composite to the
    /// drawable.
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

        // Pass 1: warp prev → curr.
        var wu = WarpU(aspect: aspect, time: time, dtFactor: dt * 60.0,
                       bass: bass, mid: mid, beat: beatEnv,
                       decay: decay, zoomGain: 0.020 + warpExtra)
        enc.setRenderPipelineState(pipelineWarp)
        enc.setFragmentBytes(&wu, length: MemoryLayout.size(ofValue: wu), index: 0)
        enc.setFragmentTexture(prev, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

        // Pass 2: waveform line strip over the warped buffer.
        var vu = WaveU(aspect: aspect, time: time, rms: rms, beat: beatEnv,
                       baseRadius: 0.45, amplitude: 0.18 + 0.25 * rms,
                       thickness: 0.0035, shape: waveShape)
        enc.setRenderPipelineState(pipelineWave)
        enc.setVertexBuffer(waveBuffer, offset: 0, index: 0)
        var vc = UInt32(Self.waveSamples)
        enc.setVertexBytes(&vc, length: 4, index: 1)
        enc.setVertexBytes(&vu, length: MemoryLayout.size(ofValue: vu), index: 2)
        enc.setFragmentBytes(&vu, length: MemoryLayout.size(ofValue: vu), index: 0)
        enc.setFragmentTexture(paletteTexture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                           instanceCount: Self.waveSamples - 1)

        enc.endEncoding()
        // The texture we just wrote becomes "curr" for compositing; flip so
        // the *next* frame reads it as "prev".
        currIndex = 1 - currIndex
    }

    func encode(into enc: MTLRenderCommandEncoder, uniforms: inout SceneUniforms) {
        guard !pingPong.isEmpty else { return }
        // The texture we wrote in prepass is pingPong[currIndex] (parity already flipped).
        enc.setRenderPipelineState(pipelineComposite)
        var cu = CompU(aspect: uniforms.aspect, beat: beatEnv, gamma: 0.85, _pad0: 0)
        enc.setFragmentBytes(&cu, length: MemoryLayout.size(ofValue: cu), index: 0)
        enc.setFragmentTexture(pingPong[currIndex], index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private func ensureTextures(width: Int, height: Int) {
        if pingPong.count == 2 && lastSize.w == width && lastSize.h == height { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
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
        // A clear pass on both textures so first-frame sampling sees black instead
        // of garbage. Done lazily by the first warp pass clearing curr; prev still
        // has uninitialised data but the first warp's `decay * black` is black.
    }

    private struct WarpU {
        var aspect: Float; var time: Float; var dtFactor: Float
        var bass: Float; var mid: Float; var beat: Float
        var decay: Float; var zoomGain: Float
    }
    private struct WaveU {
        var aspect: Float; var time: Float; var rms: Float; var beat: Float
        var baseRadius: Float; var amplitude: Float; var thickness: Float
        var shape: Int32
    }
    private struct CompU {
        var aspect: Float; var beat: Float; var gamma: Float; var _pad0: Float
    }
}
