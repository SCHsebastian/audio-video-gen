import Foundation
import AVFoundation
import Metal
import CoreVideo
import Domain

final class AVOfflineVideoRenderer: OfflineVideoRendering, @unchecked Sendable {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let library: MTLLibrary

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var textureCache: CVMetalTextureCache?
    private var scene: VisualizerScene?
    private var paletteTexture: MTLTexture?
    private var output: URL?

    private var width: Int = 0
    private var height: Int = 0
    private var fps: Int = 0
    private var frameIndex: Int64 = 0
    private var cancelled: Bool = false

    init(device: MTLDevice, queue: MTLCommandQueue, library: MTLLibrary) {
        self.device = device
        self.queue = queue
        self.library = library
    }

    func begin(output: URL, options: RenderOptions, scene: SceneKind,
               palette: ColorPalette,
               aiGameProgress: AIGameProgress?) throws {
        // Threading `aiGameProgress` into AI Game scene seeding lands in
        // Task 8.2 — for now keep the parameter on the signature so the port
        // contract holds, and discard the value.
        _ = aiGameProgress
        guard let pal = PaletteFactory.texture(from: palette, device: device)
              ?? PaletteFactory.texture(from: PaletteFactory.xpNeon, device: device) else {
            throw ExportError.metalUnavailable
        }
        let visualizerScene: VisualizerScene
        do {
            visualizerScene = try MetalVisualizationRenderer.buildScene(
                kind: scene, device: device, library: library, paletteTexture: pal)
        } catch {
            throw ExportError.metalUnavailable
        }

        if FileManager.default.fileExists(atPath: output.path) {
            try? FileManager.default.removeItem(at: output)
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        } catch {
            throw ExportError.outputUnwritable(output, description: error.localizedDescription)
        }

        let colorProperties: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: options.bitrate,
            AVVideoMaxKeyFrameIntervalKey: options.fps * 2,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoAllowFrameReorderingKey: true,
            AVVideoExpectedSourceFrameRateKey: options.fps
        ]
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: options.width,
            AVVideoHeightKey: options.height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: colorProperties
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false

        let sourceAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: options.width,
            kCVPixelBufferHeightKey as String: options.height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: sourceAttrs)

        guard writer.canAdd(input) else {
            throw ExportError.outputUnwritable(output, description: "writer cannot add video input")
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw ExportError.outputUnwritable(
                output, description: writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let textureCache = cache else {
            writer.cancelWriting()
            throw ExportError.metalUnavailable
        }

        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        self.textureCache = textureCache
        self.scene = visualizerScene
        self.paletteTexture = pal
        self.output = output
        self.width = options.width
        self.height = options.height
        self.fps = options.fps
        self.frameIndex = 0
        self.cancelled = false
    }

    func consume(spectrum: SpectrumFrame, waveform: WaveformBuffer, beat: BeatEvent?, dt: Float) async throws {
        guard !cancelled,
              let writer = writer, writer.status == .writing,
              let input = input, let adaptor = adaptor,
              let pool = adaptor.pixelBufferPool,
              let cache = textureCache,
              let scene = scene else {
            throw ExportError.encoderFailed(description: "consume called in invalid state")
        }

        while !input.isReadyForMoreMediaData {
            if cancelled { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        var pixelBuffer: CVPixelBuffer?
        let poolStatus = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard poolStatus == kCVReturnSuccess, let pb = pixelBuffer else {
            throw ExportError.encoderFailed(description: "pool create returned \(poolStatus)")
        }

        var cvTexture: CVMetalTexture?
        let texStatus = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pb, nil, .bgra8Unorm, width, height, 0, &cvTexture)
        guard texStatus == kCVReturnSuccess,
              let cvTex = cvTexture,
              let mtlTexture = CVMetalTextureGetTexture(cvTex) else {
            throw ExportError.encoderFailed(description: "metal texture from pixel buffer failed: \(texStatus)")
        }

        let aspect = Float(width) / Float(max(1, height))

        scene.update(spectrum: spectrum, waveform: waveform, beat: beat, dt: dt)

        guard let cmd = queue.makeCommandBuffer() else {
            throw ExportError.encoderFailed(description: "makeCommandBuffer failed")
        }

        let size = CGSize(width: width, height: height)
        if let alch = scene as? AlchemyScene {
            alch.dispatchCompute(into: cmd, dt: dt, aspect: aspect)
        }
        if let md = scene as? MilkdropScene {
            md.prepass(into: cmd, drawableSize: size, aspect: aspect, dt: dt)
        }
        if let li = scene as? LissajousScene {
            li.prepass(into: cmd, drawableSize: size, aspect: aspect, dt: dt)
        }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = mtlTexture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else {
            throw ExportError.encoderFailed(description: "makeRenderCommandEncoder failed")
        }
        var uniforms = SceneUniforms(
            time: Float(frameIndex) / Float(fps),
            aspect: aspect,
            rms: spectrum.rms,
            beatStrength: beat?.strength ?? 0)
        scene.encode(into: enc, uniforms: &uniforms)
        enc.endEncoding()

        cmd.commit()
        cmd.waitUntilCompleted()

        let pts = CMTime(value: frameIndex, timescale: Int32(fps))
        if !adaptor.append(pb, withPresentationTime: pts) {
            let status = writer.status
            let desc = writer.error?.localizedDescription ?? "append failed (status=\(status.rawValue))"
            throw ExportError.encoderFailed(description: desc)
        }
        frameIndex += 1
    }

    func finish() async throws -> URL {
        guard let writer = writer, let input = input, let output = output else {
            throw ExportError.encoderFailed(description: "finish called without begin")
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            let desc = writer.error?.localizedDescription ?? "writer failed"
            tearDown()
            throw ExportError.encoderFailed(description: desc)
        }
        tearDown()
        return output
    }

    func cancel() async {
        cancelled = true
        if let writer = writer, writer.status == .writing {
            writer.cancelWriting()
        }
        tearDown()
    }

    private func tearDown() {
        writer = nil
        input = nil
        adaptor = nil
        textureCache = nil
        scene = nil
        paletteTexture = nil
    }
}
