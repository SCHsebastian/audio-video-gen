import Metal
import MetalKit
import Domain
import os.lock
import os.log

final class MetalVisualizationRenderer: NSObject, VisualizationRendering, MTKViewDelegate, @unchecked Sendable {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let library: MTLLibrary

    /// Built and cached on first navigation to a given scene. Empty at startup.
    private var scenes: [SceneKind: VisualizerScene] = [:]
    /// Factory closures that lazily build & cache the scene for a given kind.
    /// Populated once in `make()`. Reading from `sceneBuilders` never builds —
    /// pipeline construction happens inside the closure.
    private var sceneBuilders: [SceneKind: () throws -> VisualizerScene] = [:]
    private var currentKind: SceneKind = .bars
    private var paletteTexture: MTLTexture
    private(set) var currentPaletteName: String = PaletteFactory.xpNeon.name
    private var lastTimestamp: CFTimeInterval = 0
    private var speed: Float = 1.0
    private var audioGain: Float = 1.0
    private var beatSensitivity: Float = 1.0

    // FPS sampled over a 0.5s sliding window.
    private var fpsFrameCount: Int = 0
    private var fpsLastSample: CFTimeInterval = 0
    private(set) var measuredFPS: Double = 0

    // Snapshot request: drained on the next draw.
    private var snapshotHandler: ((CGImage?) -> Void)?

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
        // Register lazy builders — scenes are constructed on first navigation
        // so the app starts faster and never compiles pipelines the user
        // doesn't visit. Each closure reads the current palette texture off
        // `renderer` so palette changes take effect on build.
        renderer.sceneBuilders[.bars]      = { [weak renderer] in try Self.build(BarsScene(),      with: renderer, d: d, lib: lib) }
        renderer.sceneBuilders[.scope]     = { [weak renderer] in try Self.build(ScopeScene(),     with: renderer, d: d, lib: lib) }
        renderer.sceneBuilders[.alchemy]   = { [weak renderer] in try Self.build(AlchemyScene(),   with: renderer, d: d, lib: lib) }
        renderer.sceneBuilders[.tunnel]    = { [weak renderer] in try Self.build(TunnelScene(),    with: renderer, d: d, lib: lib) }
        renderer.sceneBuilders[.lissajous] = { [weak renderer] in try Self.build(LissajousScene(), with: renderer, d: d, lib: lib) }
        return renderer
    }

    private static func build<S: VisualizerScene>(_ scene: S, with renderer: MetalVisualizationRenderer?, d: MTLDevice, lib: MTLLibrary) throws -> VisualizerScene {
        let pal = renderer?.paletteTexture ?? PaletteFactory.texture(from: PaletteFactory.xpNeon, device: d)!
        try scene.build(device: d, library: lib, paletteTexture: pal)
        return scene
    }

    /// Build (or fetch from cache) the scene for `kind`. Logs once on first
    /// build so a `log stream` clearly shows which scene a session touches.
    private func materialize(_ kind: SceneKind) -> VisualizerScene? {
        if let s = scenes[kind] { return s }
        guard let builder = sceneBuilders[kind] else { return nil }
        do {
            let s = try builder()
            scenes[kind] = s
            Log.render.info("scene materialized: \(String(describing: kind), privacy: .public)")
            return s
        } catch {
            Log.render.error("scene build failed: \(String(describing: kind), privacy: .public) \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func setScene(_ kind: SceneKind) {
        Log.render.info("setScene: \(String(describing: kind), privacy: .public)")
        let previous = currentKind
        currentKind = kind
        // Free the scene we just left so its pipelines / compute buffers go
        // away. The next visit will pay the build cost again — that's the
        // explicit trade chosen here in favour of lower steady-state memory.
        if previous != kind, scenes[previous] != nil {
            scenes.removeValue(forKey: previous)
            Log.render.info("scene released: \(String(describing: previous), privacy: .public)")
        }
    }

    func setPalette(_ palette: ColorPalette) {
        Log.render.info("setPalette: \(palette.name, privacy: .public)")
        guard let pal = PaletteFactory.texture(from: palette, device: device) else { return }
        self.paletteTexture = pal
        self.currentPaletteName = palette.name
        // Only rebuild scenes that were already materialized. Un-visited
        // scenes will pick up the new texture when they are first built.
        for (_, scene) in scenes {
            try? scene.build(device: device, library: library, paletteTexture: pal)
        }
    }

    func setSpeed(_ s: Float) {
        speed = max(0.1, min(3.0, s))
        Log.render.info("setSpeed: \(self.speed, privacy: .public)")
    }

    func setAudioGain(_ g: Float) {
        audioGain = max(0.25, min(4.0, g))
    }

    func setBeatSensitivity(_ s: Float) {
        beatSensitivity = max(0.25, min(3.0, s))
    }

    /// Pick a palette by display name. Falls back silently when missing.
    func setPalette(named name: String) {
        if let pal = PaletteFactory.all.first(where: { $0.name == name }) {
            setPalette(pal)
        }
    }

    /// Capture the next presented drawable as a CGImage and hand it to `completion`
    /// on the main actor. Completion is `nil` on failure.
    func requestSnapshot(_ completion: @escaping (CGImage?) -> Void) {
        snapshotHandler = completion
    }

    func randomizeLissajous() {
        (materialize(.lissajous) as? LissajousScene)?.randomize()
        Log.render.info("randomizeLissajous")
    }

    func randomizeAlchemy() {
        (materialize(.alchemy) as? AlchemyScene)?.randomize()
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
        case .tunnel:    (materialize(.tunnel) as? TunnelScene)?.randomize(); return "Tunnel"
        case .bars:      (materialize(.bars)   as? BarsScene)?.randomize();   return "Bars"
        case .scope:     return nil
        }
    }

    func peekRMS() -> Float {
        let raw = stateLock.withLock { $0.spectrum.rms }
        return min(1, raw * audioGain)
    }

    /// Smoothed beat strength in [0, 1] for use by ambient UI effects (e.g. vignette).
    /// Attack and release are deliberately gentle: a hard attack reads as a
    /// strobe on bright scenes and is fatiguing to look at. Bars are the only
    /// scene whose own shader brightens with beats — the rest of the scenes
    /// only react through these ambient overlays, so softening here calms
    /// everything except Bars (which is what the user asked for).
    private var smoothedBeat: Float = 0
    func peekBeat() -> Float {
        let target = stateLock.withLock { s -> Float in s.beat?.strength ?? 0 }
        let coef: Float = target > smoothedBeat ? 0.22 : 0.05
        smoothedBeat += (target - smoothedBeat) * coef
        return min(1, smoothedBeat * beatSensitivity)
    }

    var currentScene: SceneKind { currentKind }

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

        // FPS sliding window (~0.5s).
        fpsFrameCount += 1
        if fpsLastSample == 0 { fpsLastSample = now }
        let dtFPS = now - fpsLastSample
        if dtFPS >= 0.5 {
            measuredFPS = Double(fpsFrameCount) / dtFPS
            fpsFrameCount = 0
            fpsLastSample = now
        }

        let snap = stateLock.withLock { s -> (SpectrumFrame, [Float], BeatEvent?) in
            let b = s.beatConsumed ? nil : s.beat
            s.beatConsumed = true
            return (s.spectrum, s.waveform, b)
        }
        let (spectrum, waveform, beat) = snap
        guard let scene = materialize(currentKind) else { return }
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

        // Snapshot the freshly-rendered drawable BEFORE present, so the texture
        // is still valid. Hand the captured CGImage back on the main actor.
        if let handler = snapshotHandler {
            snapshotHandler = nil
            let tex = drawable.texture
            cmd.addCompletedHandler { _ in
                let img = Self.makeCGImage(from: tex)
                DispatchQueue.main.async { handler(img) }
            }
        }

        cmd.present(drawable)
        cmd.commit()
    }

    /// Convert a BGRA8/`bgra8Unorm_srgb` Metal texture to a sRGB CGImage. Returns
    /// nil if the texture cannot be read (e.g. framebufferOnly).
    private static func makeCGImage(from texture: MTLTexture) -> CGImage? {
        let w = texture.width, h = texture.height
        let bytesPerPixel = 4
        let bytesPerRow = w * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        texture.getBytes(&pixels, bytesPerRow: bytesPerRow,
                         from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        // BGRA → RGBA in place.
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let b = pixels[i]; pixels[i] = pixels[i + 2]; pixels[i + 2] = b
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: w, height: h,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow,
                       space: cs,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}
