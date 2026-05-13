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
        var waveform: WaveformBuffer = WaveformBuffer(mono: Array(repeating: 0, count: 1024))
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

    var deviceForSecondary: MTLDevice  { device }
    var queueForSecondary:  MTLCommandQueue { queue }
    var libraryForSecondary: MTLLibrary { library }

    /// Build a secondary renderer that shares the primary's device/queue/library
    /// but owns its own scene cache and palette texture. Used by split view.
    static func makeSecondary(device d: MTLDevice, queue q: MTLCommandQueue, library lib: MTLLibrary,
                              palette: ColorPalette) -> MetalVisualizationRenderer {
        let pal = PaletteFactory.texture(from: palette, device: d)
                  ?? PaletteFactory.texture(from: PaletteFactory.xpNeon, device: d)!
        let r = MetalVisualizationRenderer(device: d, queue: q, library: lib, paletteTexture: pal)
        r.currentPaletteName = palette.name
        // Register the same lazy builders the primary uses.
        r.sceneBuilders[.bars]      = { [weak r] in try Self.build(BarsScene(),      with: r, d: d, lib: lib) }
        r.sceneBuilders[.scope]     = { [weak r] in try Self.build(ScopeScene(),     with: r, d: d, lib: lib) }
        r.sceneBuilders[.alchemy]   = { [weak r] in try Self.build(AlchemyScene(),   with: r, d: d, lib: lib) }
        r.sceneBuilders[.tunnel]    = { [weak r] in try Self.build(TunnelScene(),    with: r, d: d, lib: lib) }
        r.sceneBuilders[.lissajous] = { [weak r] in try Self.build(LissajousScene(), with: r, d: d, lib: lib) }
        r.sceneBuilders[.radial]       = { [weak r] in try Self.build(RadialScene(),       with: r, d: d, lib: lib) }
        r.sceneBuilders[.rings]        = { [weak r] in try Self.build(RingsScene(),        with: r, d: d, lib: lib) }
        r.sceneBuilders[.synthwave]    = { [weak r] in try Self.build(SynthwaveScene(),    with: r, d: d, lib: lib) }
        r.sceneBuilders[.spectrogram]  = { [weak r] in try Self.build(SpectrogramScene(),  with: r, d: d, lib: lib) }
        r.sceneBuilders[.milkdrop]     = { [weak r] in try Self.build(MilkdropScene(),     with: r, d: d, lib: lib) }
        r.sceneBuilders[.kaleidoscope] = { [weak r] in try Self.build(KaleidoscopeScene(), with: r, d: d, lib: lib) }
        return r
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
        renderer.sceneBuilders[.radial]       = { [weak renderer] in try Self.build(RadialScene(),       with: renderer, d: d, lib: lib) }
        renderer.sceneBuilders[.rings]        = { [weak renderer] in try Self.build(RingsScene(),        with: renderer, d: d, lib: lib) }
        renderer.sceneBuilders[.synthwave]    = { [weak renderer] in try Self.build(SynthwaveScene(),    with: renderer, d: d, lib: lib) }
        renderer.sceneBuilders[.spectrogram]  = { [weak renderer] in try Self.build(SpectrogramScene(),  with: renderer, d: d, lib: lib) }
        renderer.sceneBuilders[.milkdrop]     = { [weak renderer] in try Self.build(MilkdropScene(),     with: renderer, d: d, lib: lib) }
        renderer.sceneBuilders[.kaleidoscope] = { [weak renderer] in try Self.build(KaleidoscopeScene(), with: renderer, d: d, lib: lib) }
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
        case .radial:    (materialize(.radial) as? RadialScene)?.randomize(); return "Radial"
        case .rings:     (materialize(.rings)  as? RingsScene)?.randomize();  return "Rings"
        case .milkdrop:  (materialize(.milkdrop) as? MilkdropScene)?.randomize(); return "Milkdrop"
        case .kaleidoscope: (materialize(.kaleidoscope) as? KaleidoscopeScene)?.randomize(); return "Kaleidoscope"
        case .scope, .synthwave, .spectrogram: return nil
        }
    }

    func peekRMS() -> Float {
        let raw = stateLock.withLock { $0.spectrum.rms }
        return min(1, raw * audioGain)
    }

    // Time-based beat envelope state. peekBeat() shapes a one-shot pulse on
    // every new beat: ramp from the current value up to the peak over
    // `attackDuration`, then ease back down to zero over `releaseDuration`.
    // Total pulse length ≈ 0.55s — perceptibly rhythmic, never strobe.
    private let beatAttackDuration: CFTimeInterval = 0.10
    private let beatReleaseDuration: CFTimeInterval = 0.45
    private var beatPulseStart: CFTimeInterval = 0
    private var beatPulseFromValue: Float = 0
    private var beatPulsePeak: Float = 0
    private var lastSeenBeatMachTime: UInt64 = 0

    /// Smoothed beat strength in [0, 1] for use by ambient UI effects.
    ///
    /// Replaces the previous per-frame exponential smoothing with a time-based
    /// envelope so the curve is independent of call rate. The shape is:
    ///
    ///   t ∈ [0, attack)            → cubic ease-out from fromValue to peak
    ///   t ∈ [attack, attack+rel)   → cubic ease-in  from peak to 0
    ///   t ≥ attack+release         → 0
    ///
    /// A new beat (detected by a fresh timestamp) takeover-restarts the pulse
    /// from whatever value we're currently at, so back-to-back beats don't
    /// snap downward before ramping up again.
    func peekBeat() -> Float {
        let now = CACurrentMediaTime()

        // Pick up new beat events from the analyzer.
        let observed = stateLock.withLock { s -> (UInt64, Float)? in
            guard let b = s.beat else { return nil }
            return (b.timestamp.machAbsolute, b.strength)
        }
        if let (ts, strength) = observed, ts != lastSeenBeatMachTime {
            lastSeenBeatMachTime = ts
            beatPulseFromValue = currentEnvelopeValue(at: now)
            beatPulsePeak = max(strength, beatPulseFromValue)
            beatPulseStart = now
        }

        return min(1, currentEnvelopeValue(at: now) * beatSensitivity)
    }

    private func currentEnvelopeValue(at now: CFTimeInterval) -> Float {
        guard beatPulseStart > 0 else { return 0 }
        let t = now - beatPulseStart
        if t < 0 { return beatPulseFromValue }
        if t < beatAttackDuration {
            let u = Float(t / beatAttackDuration)
            let eased = 1 - pow(1 - u, 3)                    // ease-out cubic
            return beatPulseFromValue + (beatPulsePeak - beatPulseFromValue) * eased
        }
        let r = t - beatAttackDuration
        if r < beatReleaseDuration {
            let u = Float(r / beatReleaseDuration)
            let eased = u * u * u                              // ease-in cubic
            return beatPulsePeak * (1 - eased)
        }
        return 0
    }

    var currentScene: SceneKind { currentKind }

    func consume(spectrum: SpectrumFrame, waveform: WaveformBuffer, beat: BeatEvent?) {
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

        let snap = stateLock.withLock { s -> (SpectrumFrame, WaveformBuffer, BeatEvent?) in
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

        let aspect = Float(view.drawableSize.width / max(1, view.drawableSize.height))

        // Compute pass for Alchemy.
        if let alch = scene as? AlchemyScene {
            alch.dispatchCompute(into: cmd, dt: dt, aspect: aspect)
        }
        // Milkdrop's ping-pong feedback loop (warp + waveform) renders into
        // its own offscreen target before the drawable's render pass.
        if let md = scene as? MilkdropScene {
            md.prepass(into: cmd, drawableSize: view.drawableSize, aspect: aspect, dt: dt)
        }
        // Lissajous renders its phosphor-persistence trace into an offscreen
        // accumulator before compositing into the drawable.
        if let li = scene as? LissajousScene {
            li.prepass(into: cmd, drawableSize: view.drawableSize, aspect: aspect, dt: dt)
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
