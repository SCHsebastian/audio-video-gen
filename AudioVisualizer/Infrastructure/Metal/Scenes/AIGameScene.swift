import Metal
import simd
import Foundation
import Domain
import Application

/// Side-scrolling runner with 6 ≤10-neuron agents evolving in real time inside
/// a music-shaped procedural world. Holds a `Domain.Population` (pure Swift)
/// and renders its public snapshot via three instanced/strip draw calls.
final class AIGameScene: VisualizerScene {
    private static let populationSize = 6
    private static let agentRadius: Float = 0.06

    private var paletteTexture: MTLTexture!
    private var device: MTLDevice!

    private var terrainPipeline: MTLRenderPipelineState!
    private var obstaclePipeline: MTLRenderPipelineState!
    private var agentPipeline: MTLRenderPipelineState!

    private var terrainBuffer: MTLBuffer!
    private var obstacleBuffer: MTLBuffer!
    private var agentBuffer: MTLBuffer!

    private(set) var population: Population!
    /// Injected by the renderer so generation milestones can persist a rolling
    /// snapshot to the fixed auto-save slot. Optional so unit tests can build
    /// the scene without the use case.
    var autoSaveUC: SaveAIGameProgressUseCase?
    /// Stable sentinel UUID for the silent auto-save slot. Hex-only so the
    /// `UUID(uuidString:)` parser accepts it; each auto-save overwrites the
    /// previous one in this single rolling slot.
    private let autoSaveSlotID = UUID(uuidString: "00000000-0000-0000-0000-A1170547EA1D")!
    private var simTime: Float = 0
    private var beatEnv: Float = 0
    private var bass: Float = 0
    private var mid: Float = 0
    private var treble: Float = 0
    private var lastSnapshot: PopulationSnapshot!
    private var pendingSeedProgress: AIGameProgress?

    #if DEBUG
    private(set) var lastSeedProgressForTesting: AIGameProgress?
    #endif

    /// Seed the live population from a previously-saved `AIGameProgress`.
    /// Honored on the very next `build`/`update`. If `population` already
    /// exists at call time, replaces it immediately.
    func setSeedProgress(_ progress: AIGameProgress) {
        pendingSeedProgress = progress
        if population != nil {
            applyPendingSeedIfAny()
        }
    }

    private func applyPendingSeedIfAny() {
        guard let snap = pendingSeedProgress else { return }
        guard snap.genomeLength == Genome.expectedLength else {
            // Schema drift — ignore the snapshot; live population stays.
            pendingSeedProgress = nil
            return
        }
        population = Population(restoring: snap, source: SystemRandomSource())
        lastSnapshot = population.snapshot()
        installAutoSaveHook()
        #if DEBUG
        lastSeedProgressForTesting = snap
        #endif
        pendingSeedProgress = nil
    }

    /// Re-attach the every-5-generation auto-save callback to whatever the
    /// current `population` instance is. Called after both fresh build and
    /// snapshot-restoring replacements so loading a saved slot mid-session
    /// keeps auto-save active.
    private func installAutoSaveHook() {
        population.onGenerationDidIncrement = { [weak self] gen in
            guard let self else { return }
            guard gen % 5 == 0 else { return }
            self.performAutoSave(generation: gen)
        }
    }

    private func performAutoSave(generation: Int) {
        guard let uc = autoSaveUC else { return }
        // Reuse Population's snapshotProgress for genomes/worldSeed/genomeLength,
        // then re-stamp with the fixed sentinel ID + "auto" label so each save
        // overwrites the prior one in the rolling slot.
        let live = population.snapshotProgress(label: "auto")
        let snap = AIGameProgress(
            id: autoSaveSlotID,
            label: "auto",
            createdAt: Date(),
            generation: generation,
            bestFitness: population.snapshot().bestFitness,
            genomes: live.genomes,
            worldSeed: live.worldSeed,
            genomeLength: Genome.expectedLength
        )
        DispatchQueue.global(qos: .utility).async {
            _ = try? uc.execute(progress: snap)
        }
    }

    func build(device: MTLDevice, library: MTLLibrary, paletteTexture: MTLTexture) throws {
        self.device = device
        self.paletteTexture = paletteTexture

        terrainPipeline  = try Self.makePipeline(device: device, library: library,
                                                 vertex: "aigame_terrain_vertex",
                                                 fragment: "aigame_terrain_fragment",
                                                 name: "AIGame.terrain")
        obstaclePipeline = try Self.makePipeline(device: device, library: library,
                                                 vertex: "aigame_obstacle_vertex",
                                                 fragment: "aigame_obstacle_fragment",
                                                 name: "AIGame.obstacle")
        agentPipeline    = try Self.makePipeline(device: device, library: library,
                                                 vertex: "aigame_agent_vertex",
                                                 fragment: "aigame_agent_fragment",
                                                 name: "AIGame.agent")

        // Allocate scratch GPU buffers sized for the worst case.
        let terrainStride = MemoryLayout<SIMD2<Float>>.stride
        terrainBuffer = device.makeBuffer(length: World.terrainSampleCount * 2 * terrainStride,
                                          options: .storageModeShared)
        obstacleBuffer = device.makeBuffer(length: 32 * MemoryLayout<ObstacleInstanceUniform>.stride,
                                           options: .storageModeShared)
        agentBuffer = device.makeBuffer(length: Self.populationSize * MemoryLayout<AgentInstanceUniform>.stride,
                                        options: .storageModeShared)

        let seed = UInt64.random(in: 1...UInt64.max)
        population = Population(size: Self.populationSize, seed: seed,
                                source: SystemRandomSource())
        lastSnapshot = population.snapshot()
        installAutoSaveHook()
        applyPendingSeedIfAny()
    }

    func update(spectrum: SpectrumFrame, waveform: WaveformBuffer, beat: BeatEvent?, dt: Float) {
        applyPendingSeedIfAny()
        bass   = max(spectrum.bass,   bass   * 0.88)
        mid    = max(spectrum.mid,    mid    * 0.85)
        treble = max(spectrum.treble, treble * 0.80)
        let triggered = (beat != nil)
        if let b = beat { beatEnv = max(beatEnv, b.strength) }
        beatEnv *= expf(-dt / 0.150)
        simTime += dt

        let drive = AudioDrive(
            bass: bass, mid: mid, treble: treble, flux: spectrum.flux,
            beatPulse: beatEnv, beatTriggered: triggered,
            bpm: beat?.bpm ?? 0
        )
        lastSnapshot = population.step(dt: dt, audio: drive)
    }

    func randomize() {
        // Click / shortcut path: trigger a random event instead of resetting.
        _ = triggerRandomEvent()
    }

    /// Pick a random event, apply it to the live population, and return a
    /// **L10nKey rawValue** the caller can localize for the existing toast.
    @discardableResult
    func triggerRandomEvent() -> String {
        let r = SystemRandomSource()
        let event = RandomEventRoulette.pick(using: r)
        population.applyEvent(event, source: r)
        return Self.l10nKey(for: event)
    }

    private static func l10nKey(for e: AIGameEvent) -> String {
        switch e {
        case .catastrophicMutation: return "aigame.event.catastrophicMutation"
        case .cull:                  return "aigame.event.cull"
        case .jumpBoost:             return "aigame.event.jumpBoost"
        case .earthquake:            return "aigame.event.earthquake"
        case .bonusObstacleWave:     return "aigame.event.bonusObstacleWave"
        case .lineageSwap:           return "aigame.event.lineageSwap"
        }
    }

    func encode(into enc: MTLRenderCommandEncoder, uniforms: inout SceneUniforms) {
        var u = AIGameSceneUniforms(
            aspect: uniforms.aspect, time: simTime,
            cameraX: lastSnapshot.cameraX,
            cameraOffsetX: sinf(simTime * 60) * 0.012 * beatEnv,
            cameraOffsetY: cosf(simTime * 73) * 0.012 * beatEnv,
            rms: uniforms.rms, beat: beatEnv
        )

        // 1) Terrain strip — pairs (x, y_top), (x, -1.0).
        let samples = lastSnapshot.terrainSamples
        let bottom: Float = -1.0
        var terrain: [SIMD2<Float>] = []
        terrain.reserveCapacity(samples.count * 2)
        for s in samples {
            terrain.append(SIMD2(s.x, s.y))
            terrain.append(SIMD2(s.x, bottom))
        }
        // Cut the strip across pit obstacles so the ground actually disappears.
        // (Cheap version: write y_top = bottom for samples whose x lies inside any pit.)
        let pits = lastSnapshot.obstacles.filter { $0.kind == .pit }
        if !pits.isEmpty {
            for i in stride(from: 0, to: terrain.count, by: 2) {
                let x = terrain[i].x
                if pits.contains(where: { $0.xStart <= x && x <= $0.xEnd }) {
                    terrain[i].y = bottom
                }
            }
        }
        let terrainBytes = terrain.count * MemoryLayout<SIMD2<Float>>.stride
        memcpy(terrainBuffer.contents(), terrain, terrainBytes)
        enc.setRenderPipelineState(terrainPipeline)
        enc.setVertexBuffer(terrainBuffer, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<AIGameSceneUniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<AIGameSceneUniforms>.stride, index: 1)
        enc.setFragmentTexture(paletteTexture, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: terrain.count)

        // 2) Obstacles.
        var obstacles: [ObstacleInstanceUniform] = lastSnapshot.obstacles.map { o in
            let groundY = lookupGroundY(at: o.xStart, in: samples)
            let bottomY: Float = (o.kind == .ceiling) ? (1.0 - o.height) : groundY
            let flag: Float = (o.kind == .spike) ? 0 : (o.kind == .ceiling) ? 1 : 2
            return ObstacleInstanceUniform(worldPos: SIMD2(o.xStart, bottomY),
                                           size: SIMD2(o.width, o.height),
                                           flags: flag)
        }
        if !obstacles.isEmpty {
            let bytes = obstacles.count * MemoryLayout<ObstacleInstanceUniform>.stride
            memcpy(obstacleBuffer.contents(), &obstacles, bytes)
            enc.setRenderPipelineState(obstaclePipeline)
            enc.setVertexBuffer(obstacleBuffer, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<AIGameSceneUniforms>.stride, index: 1)
            enc.setFragmentTexture(paletteTexture, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0,
                               vertexCount: 6, instanceCount: obstacles.count)
        }

        // 3) Agents.
        var agents: [AgentInstanceUniform] = lastSnapshot.agents.map { a in
            AgentInstanceUniform(worldPos: SIMD2(a.posX, a.posY),
                                 size: Self.agentRadius,
                                 colorSeed: a.colorSeed,
                                 alive: a.alive ? 1 : 0)
        }
        let agentBytes = agents.count * MemoryLayout<AgentInstanceUniform>.stride
        memcpy(agentBuffer.contents(), &agents, agentBytes)
        enc.setRenderPipelineState(agentPipeline)
        enc.setVertexBuffer(agentBuffer, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<AIGameSceneUniforms>.stride, index: 1)
        enc.setFragmentTexture(paletteTexture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0,
                           vertexCount: 6, instanceCount: agents.count)
    }

    // MARK: helpers
    private func lookupGroundY(at x: Float, in samples: [TerrainSample]) -> Float {
        // Linear search — at most 256 samples, called ≤ 8× per frame.
        for i in 0..<(samples.count - 1) {
            if samples[i].x <= x && x <= samples[i + 1].x {
                let t = (x - samples[i].x) / (samples[i + 1].x - samples[i].x)
                return samples[i].y + (samples[i + 1].y - samples[i].y) * t
            }
        }
        return samples.first?.y ?? -0.55
    }

    private static func makePipeline(device: MTLDevice, library: MTLLibrary,
                                     vertex: String, fragment: String,
                                     name: String) throws -> MTLRenderPipelineState {
        guard let v = library.makeFunction(name: vertex),
              let f = library.makeFunction(name: fragment) else {
            throw RenderError.shaderCompilationFailed(name: vertex)
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.label = name
        desc.vertexFunction = v
        desc.fragmentFunction = f
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do { return try device.makeRenderPipelineState(descriptor: desc) }
        catch { throw RenderError.pipelineCreationFailed(name: name) }
    }
}

private struct AIGameSceneUniforms {
    var aspect: Float
    var time: Float
    var cameraX: Float
    var cameraOffsetX: Float
    var cameraOffsetY: Float
    var rms: Float
    var beat: Float
}

private struct ObstacleInstanceUniform {
    var worldPos: SIMD2<Float>
    var size: SIMD2<Float>
    var flags: Float
}

private struct AgentInstanceUniform {
    var worldPos: SIMD2<Float>
    var size: Float
    var colorSeed: Float
    var alive: Float
}
