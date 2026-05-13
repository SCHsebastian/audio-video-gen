import Metal
import MetalKit
import Domain
import os.lock
import os.log

final class MetalVisualizationRenderer: NSObject, VisualizationRendering, MTKViewDelegate, @unchecked Sendable {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let library: MTLLibrary

    private var scenes: [SceneKind: VisualizerScene] = [:]
    private var currentKind: SceneKind = .bars
    private var paletteTexture: MTLTexture
    private(set) var currentPaletteName: String = PaletteFactory.xpNeon.name
    private var lastTimestamp: CFTimeInterval = 0
    private var speed: Float = 1.0

    private let stateLock = OSAllocatedUnfairLock(initialState: State())
    private struct State {
        var spectrum: SpectrumFrame = SpectrumFrame(bands: Array(repeating: 0, count: 64), rms: 0, timestamp: .zero)
        var waveform: [Float] = Array(repeating: 0, count: 1024)
        var beat: BeatEvent?
        var beatConsumed = true
    }

    // Periodic consume() stats — reset every second.
    private struct ConsumeStats {
        var count: Int = 0
        var peakRMS: Float = 0
        var lastLogTime: CFTimeInterval = 0
    }
    private var consumeStats = ConsumeStats()

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
        let tun = TunnelScene(); try tun.build(device: d, library: lib, paletteTexture: pal); renderer.scenes[.tunnel] = tun
        let liss = LissajousScene(); try liss.build(device: d, library: lib, paletteTexture: pal); renderer.scenes[.lissajous] = liss
        return renderer
    }

    func setScene(_ kind: SceneKind) {
        Log.render.info("setScene: \(String(describing: kind), privacy: .public)")
        currentKind = kind
    }

    func setPalette(_ palette: ColorPalette) {
        Log.render.info("setPalette: \(palette.name, privacy: .public)")
        guard let pal = PaletteFactory.texture(from: palette, device: device) else { return }
        self.paletteTexture = pal
        self.currentPaletteName = palette.name
        // Re-build scenes with new palette (cheap — pipelines are unchanged).
        if let bars = scenes[.bars] as? BarsScene { try? bars.build(device: device, library: library, paletteTexture: pal) }
        if let scope = scenes[.scope] as? ScopeScene { try? scope.build(device: device, library: library, paletteTexture: pal) }
        if let alch = scenes[.alchemy] as? AlchemyScene { try? alch.build(device: device, library: library, paletteTexture: pal) }
        if let tun = scenes[.tunnel] as? TunnelScene { try? tun.build(device: device, library: library, paletteTexture: pal) }
        if let liss = scenes[.lissajous] as? LissajousScene { try? liss.build(device: device, library: library, paletteTexture: pal) }
    }

    func setSpeed(_ s: Float) {
        speed = max(0.1, min(3.0, s))
        Log.render.info("setSpeed: \(self.speed, privacy: .public)")
    }

    func randomizeLissajous() {
        (scenes[.lissajous] as? LissajousScene)?.randomize()
        Log.render.info("randomizeLissajous")
    }

    func randomizeAlchemy() {
        (scenes[.alchemy] as? AlchemyScene)?.randomize()
        Log.render.info("randomizeAlchemy")
    }

    /// Randomize the current scene if it supports it. Used by the canvas tap
    /// gesture so we don't have to teach the view layer about specific scenes.
    /// Returns a short label naming what was randomized (or nil if no-op).
    @discardableResult
    func randomizeCurrent() -> String? {
        switch currentKind {
        case .lissajous: randomizeLissajous(); return "Lissajous"
        case .alchemy:   randomizeAlchemy();   return "Alchemy"
        case .tunnel:    (scenes[.tunnel] as? TunnelScene)?.randomize(); return "Tunnel"
        case .bars:      (scenes[.bars]   as? BarsScene)?.randomize();   return "Bars"
        case .scope:     return nil
        }
    }

    func peekRMS() -> Float {
        stateLock.withLock { $0.spectrum.rms }
    }

    /// Smoothed beat strength in [0, 1] for use by ambient UI effects (e.g. vignette).
    private var smoothedBeat: Float = 0
    func peekBeat() -> Float {
        let target = stateLock.withLock { s -> Float in s.beat?.strength ?? 0 }
        let coef: Float = target > smoothedBeat ? 0.45 : 0.06   // attack fast, release slow
        smoothedBeat += (target - smoothedBeat) * coef
        return smoothedBeat
    }

    func consume(spectrum: SpectrumFrame, waveform: [Float], beat: BeatEvent?) {
        stateLock.withLock { s in
            s.spectrum = spectrum
            s.waveform = waveform
            if let beat { s.beat = beat; s.beatConsumed = false }
        }
        consumeStats.count += 1
        consumeStats.peakRMS = max(consumeStats.peakRMS, spectrum.rms)
        let now = CACurrentMediaTime()
        if now - consumeStats.lastLogTime >= 1.0 {
            Log.render.info("consume: \(self.consumeStats.count, privacy: .public) frames/s peakRMS=\(self.consumeStats.peakRMS, privacy: .public)")
            consumeStats = ConsumeStats(count: 0, peakRMS: 0, lastLogTime: now)
        }
    }

    // MARK: MTKViewDelegate
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let raw = lastTimestamp == 0 ? Float(1.0/60.0) : Float(min(0.1, now - lastTimestamp))
        lastTimestamp = now
        let dt = raw * speed

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
