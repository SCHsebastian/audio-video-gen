import Foundation
import Metal
import Domain
import Application

@main
struct AudioVisRender {
    static func main() async {
        let args = CommandLine.arguments
        if args.count >= 2, args[1] == "-h" || args[1] == "--help" {
            printHelp()
            exit(0)
        }
        guard let parsed = parseArgs(args) else {
            printHelp(toStderr: true)
            exit(2)
        }

        guard let device = MTLCreateSystemDefaultDevice() else {
            fputs("audiovis-render: no Metal device available\n", stderr)
            exit(1)
        }
        guard let queue = device.makeCommandQueue() else {
            fputs("audiovis-render: failed to create Metal command queue\n", stderr)
            exit(1)
        }
        let library: MTLLibrary
        do {
            library = try loadShaderLibrary(device: device)
        } catch {
            fputs("audiovis-render: failed to load default.metallib: \(error)\n", stderr)
            exit(1)
        }

        let decoder = AVAudioFileDecoder()
        let analyzer = VDSPSpectrumAnalyzer(bandCount: 64, sampleRate: SampleRate(hz: 48_000))
        let beats = EnergyBeatDetector()
        let renderer = MetalVisualizationRenderer.makeOfflineRenderer(
            device: device, queue: queue, library: library)
        let useCase = ExportVisualizationUseCase(
            decoder: decoder, analyzer: analyzer, beats: beats, renderer: renderer)

        let palette = PaletteFactory.all.first(where: {
            $0.name.caseInsensitiveCompare(parsed.paletteName) == .orderedSame
        }) ?? PaletteFactory.xpNeon
        let options = RenderOptions.make(parsed.resolution, parsed.fps)

        fputs("audiovis-render: \(parsed.audioURL.lastPathComponent) -> \(parsed.outputURL.lastPathComponent)\n", stdout)
        fputs("  scene=\(parsed.scene) palette=\(palette.name) \(options.width)x\(options.height)@\(options.fps)fps\n", stdout)

        let stream = useCase.execute(
            audio: parsed.audioURL,
            output: parsed.outputURL,
            scene: parsed.scene,
            palette: palette,
            options: options)

        var exitCode: Int32 = 0
        var lastReportedPercent = -1
        for await state in stream {
            switch state {
            case .preparing:
                fputs("preparing...\n", stdout)
            case .rendering(let n, let total):
                if let total, total > 0 {
                    let pct = Int(Double(n) * 100.0 / Double(total))
                    if pct != lastReportedPercent {
                        lastReportedPercent = pct
                        fputs("  \(pct)% (\(n)/\(total))\n", stdout)
                    }
                } else {
                    fputs("  frame \(n)\n", stdout)
                }
            case .finalising:
                fputs("finalising...\n", stdout)
            case .completed(let url):
                fputs("done: \(url.path)\n", stdout)
                exitCode = 0
            case .failed(let e):
                fputs("failed: \(describe(error: e))\n", stderr)
                exitCode = 1
            case .cancelled:
                fputs("cancelled\n", stderr)
                exitCode = 130
            }
        }
        exit(exitCode)
    }

    private static func loadShaderLibrary(device: MTLDevice) throws -> MTLLibrary {
        if let lib = device.makeDefaultLibrary() { return lib }
        // Fallback for CLI tools where Bundle.main doesn't locate the metallib
        // automatically — look for default.metallib next to the executable.
        let exeURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let metallibURL = exeURL.deletingLastPathComponent().appendingPathComponent("default.metallib")
        return try device.makeLibrary(URL: metallibURL)
    }

    private static func describe(error: ExportError) -> String {
        switch error {
        case .fileUnreadable(let url, let d):       return "audio file unreadable (\(url.path)): \(d)"
        case .unsupportedAudioFormat(let d):        return "unsupported audio format: \(d)"
        case .outputUnwritable(let url, let d):     return "output unwritable (\(url.path)): \(d)"
        case .encoderFailed(let d):                 return "encoder failed: \(d)"
        case .metalUnavailable:                     return "Metal unavailable"
        }
    }
}

private struct ParsedArgs {
    var audioURL: URL
    var outputURL: URL
    var scene: SceneKind
    var paletteName: String
    var resolution: RenderOptions.Resolution
    var fps: RenderOptions.FrameRate
}

private func parseArgs(_ args: [String]) -> ParsedArgs? {
    guard args.count >= 3 else { return nil }
    let audioURL  = URL(fileURLWithPath: args[1])
    let outputURL = URL(fileURLWithPath: args[2])

    var scene: SceneKind = .bars
    var palette = "Synthwave"
    var resolution: RenderOptions.Resolution = .hd1080
    var fps: RenderOptions.FrameRate = .fps60

    var i = 3
    while i < args.count {
        let key = args[i]
        guard i + 1 < args.count else {
            fputs("audiovis-render: missing value for \(key)\n", stderr)
            return nil
        }
        let value = args[i + 1]
        switch key {
        case "--scene":
            guard let s = parseScene(value) else {
                fputs("audiovis-render: unknown scene '\(value)'\n", stderr); return nil
            }
            scene = s
        case "--palette":
            palette = value
        case "--resolution":
            guard let r = parseResolution(value) else {
                fputs("audiovis-render: unknown resolution '\(value)' (use 720p|1080p|4k)\n", stderr); return nil
            }
            resolution = r
        case "--fps":
            guard let f = parseFps(value) else {
                fputs("audiovis-render: unknown fps '\(value)' (use 30|60)\n", stderr); return nil
            }
            fps = f
        default:
            fputs("audiovis-render: unknown option '\(key)'\n", stderr); return nil
        }
        i += 2
    }

    return ParsedArgs(audioURL: audioURL, outputURL: outputURL,
                      scene: scene, paletteName: palette,
                      resolution: resolution, fps: fps)
}

private func parseScene(_ s: String) -> SceneKind? {
    switch s.lowercased() {
    case "bars":         return .bars
    case "scope":        return .scope
    case "alchemy":      return .alchemy
    case "tunnel":       return .tunnel
    case "lissajous":    return .lissajous
    case "radial":       return .radial
    case "rings":        return .rings
    case "synthwave":    return .synthwave
    case "spectrogram":  return .spectrogram
    case "milkdrop":     return .milkdrop
    case "kaleidoscope": return .kaleidoscope
    default:             return nil
    }
}

private func parseResolution(_ s: String) -> RenderOptions.Resolution? {
    switch s.lowercased() {
    case "720p", "hd720":             return .hd720
    case "1080p", "hd1080", "fhd":    return .hd1080
    case "4k", "uhd4k", "2160p":      return .uhd4k
    default:                          return nil
    }
}

private func parseFps(_ s: String) -> RenderOptions.FrameRate? {
    switch s {
    case "30": return .fps30
    case "60": return .fps60
    default:   return nil
    }
}

private func printHelp(toStderr: Bool = false) {
    let help = """
    audiovis-render — offline render of the AudioVisualizer scenes to a silent .mp4

    USAGE:
        audiovis-render <audio> <output> [options]

    OPTIONS:
        --scene NAME        bars | scope | alchemy | tunnel | lissajous | radial |
                            rings | synthwave | spectrogram | milkdrop | kaleidoscope
                            (default: bars)
        --palette NAME      palette name as shown in the app's palette picker
                            (default: Synthwave)
        --resolution RES    720p | 1080p | 4k  (default: 1080p)
        --fps N             30 | 60            (default: 60)
        -h, --help          show this help

    EXAMPLES:
        audiovis-render song.mp3 out.mp4
        audiovis-render song.wav out.mp4 --scene synthwave --resolution 4k --fps 30
        audiovis-render song.flac out.mp4 --scene tunnel --palette "Aurora" --fps 60

    """
    if toStderr { fputs(help, stderr) } else { fputs(help, stdout) }
}
