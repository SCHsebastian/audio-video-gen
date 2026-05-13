import Metal
import MetalKit
import Domain
import os.lock

final class MetalVisualizationRenderer: NSObject, VisualizationRendering, MTKViewDelegate, @unchecked Sendable {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let library: MTLLibrary

    private var scenes: [SceneKind: VisualizerScene] = [:]
    private var currentKind: SceneKind = .bars
    private var paletteTexture: MTLTexture
    private var lastTimestamp: CFTimeInterval = 0

    private let stateLock = OSAllocatedUnfairLock(initialState: State())
    private struct State {
        var spectrum: SpectrumFrame = SpectrumFrame(bands: Array(repeating: 0, count: 64), rms: 0, timestamp: .zero)
        var waveform: [Float] = Array(repeating: 0, count: 1024)
        var beat: BeatEvent?
        var beatConsumed = true
    }

    override init() {
        fatalError("Use MetalVisualizationRenderer.make() instead")
    }

    private init(device: MTLDevice, queue: MTLCommandQueue, library: MTLLibrary, paletteTexture: MTLTexture) {
        self.device = device
        self.queue = queue
        self.library = library
        self.paletteTexture = paletteTexture
        super.init()
    }

    static func make() throws -> MetalVisualizationRenderer {
        guard let d = MTLCreateSystemDefaultDevice() else { throw RenderError.metalDeviceUnavailable }
        guard let q = d.makeCommandQueue() else { throw RenderError.metalDeviceUnavailable }
        guard let lib = d.makeDefaultLibrary() else { throw RenderError.shaderCompilationFailed(name: "default") }
        guard let pal = PaletteFactory.texture(from: PaletteFactory.xpNeon, device: d) else {
            throw RenderError.pipelineCreationFailed(name: "palette")
        }
        let renderer = MetalVisualizationRenderer(device: d, queue: q, library: lib, paletteTexture: pal)
        let bars = BarsScene(); try bars.build(device: d, library: lib, paletteTexture: pal); renderer.scenes[.bars] = bars
        let scope = ScopeScene(); try scope.build(device: d, library: lib, paletteTexture: pal); renderer.scenes[.scope] = scope
        let alch = AlchemyScene(); try alch.build(device: d, library: lib, paletteTexture: pal); renderer.scenes[.alchemy] = alch
        return renderer
    }

    func setScene(_ kind: SceneKind) { currentKind = kind }

    func setPalette(_ palette: ColorPalette) {
        guard let pal = PaletteFactory.texture(from: palette, device: device) else { return }
        self.paletteTexture = pal
        // Re-build scenes with new palette (cheap — pipelines are unchanged).
        if let bars = scenes[.bars] as? BarsScene { try? bars.build(device: device, library: library, paletteTexture: pal) }
        if let scope = scenes[.scope] as? ScopeScene { try? scope.build(device: device, library: library, paletteTexture: pal) }
        if let alch = scenes[.alchemy] as? AlchemyScene { try? alch.build(device: device, library: library, paletteTexture: pal) }
    }

    func peekRMS() -> Float {
        stateLock.withLock { $0.spectrum.rms }
    }

    func consume(spectrum: SpectrumFrame, waveform: [Float], beat: BeatEvent?) {
        stateLock.withLock { s in
            s.spectrum = spectrum
            s.waveform = waveform
            if let beat { s.beat = beat; s.beatConsumed = false }
        }
    }

    // MARK: MTKViewDelegate
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = lastTimestamp == 0 ? Float(1.0/60.0) : Float(min(0.1, now - lastTimestamp))
        lastTimestamp = now

        let snap = stateLock.withLock { s -> (SpectrumFrame, [Float], BeatEvent?) in
            let b = s.beatConsumed ? nil : s.beat
            s.beatConsumed = true
            return (s.spectrum, s.waveform, b)
        }
        let (spectrum, waveform, beat) = snap
        guard let scene = scenes[currentKind] else { return }
        scene.update(spectrum: spectrum, waveform: waveform, beat: beat, dt: dt)

        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer() else { return }

        // Compute pass for Alchemy.
        if let alch = scene as? AlchemyScene {
            alch.dispatchCompute(into: cmd, dt: dt, aspect: Float(view.drawableSize.width / max(1, view.drawableSize.height)))
        }

        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.04, alpha: 1)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        var uniforms = SceneUniforms(
            time: Float(now),
            aspect: Float(view.drawableSize.width / max(1, view.drawableSize.height)),
            rms: spectrum.rms,
            beatStrength: beat?.strength ?? 0)
        scene.encode(into: enc, uniforms: &uniforms)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}
