import Foundation

/// Decodes any audio file the platform can read (mp3 / wav / m4a / aac / flac …)
/// into the same `AudioFrame` contract the live capture publishes: 1024 sample
/// chunks at 48 kHz, mono mixdown + L + R. The adapter resamples at the reader
/// boundary so downstream analysis is sample-rate-agnostic.
public protocol AudioFileDecoding: Sendable {
    /// Stream of decoded chunks. Terminates when EOF is reached or throws on
    /// codec / I/O failure. Caller is responsible for cancelling the stream's
    /// underlying task to stop decoding early.
    func decode(url: URL) throws -> AsyncThrowingStream<AudioFrame, Error>

    /// Total 48 kHz frame count, used for progress reporting. Returns `nil`
    /// when the duration cannot be determined cheaply (e.g. an mp3 without a
    /// Xing header). Consumers should fall back to an indeterminate progress
    /// indicator in that case.
    func estimatedFrameCount(url: URL) async throws -> Int?
}
