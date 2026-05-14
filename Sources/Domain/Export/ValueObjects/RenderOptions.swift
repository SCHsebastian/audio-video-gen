import Foundation

/// Resolution / fps / bit-rate triple selected in the export sheet. The
/// constructors expose only the combinations the UI offers (720p / 1080p / 4K
/// × 30 / 60 fps) so the rest of the pipeline can't be passed an arbitrary
/// bit rate.
public struct RenderOptions: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let fps: Int
    public let bitrate: Int    // bits per second

    public init(width: Int, height: Int, fps: Int, bitrate: Int) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
    }

    public enum Resolution: String, CaseIterable, Sendable {
        case hd720    // 1280 x 720
        case hd1080   // 1920 x 1080
        case uhd4k    // 3840 x 2160

        public var width: Int  { switch self { case .hd720: 1280; case .hd1080: 1920; case .uhd4k: 3840 } }
        public var height: Int { switch self { case .hd720:  720; case .hd1080: 1080; case .uhd4k: 2160 } }
    }

    public enum FrameRate: Int, CaseIterable, Sendable {
        case fps30 = 30
        case fps60 = 60
    }

    /// Bit-rate table from the design spec: enough headroom for the H.264
    /// hardware encoder to look clean on motion-heavy scenes (Tunnel scroll,
    /// Synthwave grid) without blowing up file sizes.
    public static func make(_ resolution: Resolution, _ frameRate: FrameRate) -> RenderOptions {
        let bps: Int
        switch (resolution, frameRate) {
        case (.hd720,  .fps30): bps =  5_000_000
        case (.hd720,  .fps60): bps =  7_500_000
        case (.hd1080, .fps30): bps =  8_000_000
        case (.hd1080, .fps60): bps = 12_000_000
        case (.uhd4k,  .fps30): bps = 30_000_000
        case (.uhd4k,  .fps60): bps = 45_000_000
        }
        return RenderOptions(width: resolution.width, height: resolution.height,
                             fps: frameRate.rawValue, bitrate: bps)
    }
}
