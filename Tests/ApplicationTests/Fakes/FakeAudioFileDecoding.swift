import Domain
import Foundation

final class FakeAudioFileDecoding: AudioFileDecoding, @unchecked Sendable {
    var frames: [AudioFrame] = []
    var estimatedTotal: Int? = nil
    var decodeError: Error?
    private(set) var lastURL: URL?

    func decode(url: URL) throws -> AsyncThrowingStream<AudioFrame, Error> {
        lastURL = url
        if let decodeError { throw decodeError }
        let snapshot = frames
        return AsyncThrowingStream { continuation in
            for f in snapshot { continuation.yield(f) }
            continuation.finish()
        }
    }

    func estimatedFrameCount(url: URL) async throws -> Int? {
        estimatedTotal
    }
}
