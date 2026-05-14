import AVFoundation
import Foundation
import Domain

final class AVAudioFileDecoder: AudioFileDecoding, @unchecked Sendable {
    init() {}

    func decode(url: URL) throws -> AsyncThrowingStream<AudioFrame, Error> {
        let asset = AVURLAsset(url: url)

        return AsyncThrowingStream<AudioFrame, Error> { continuation in
            let task = Task {
                do {
                    // Async load avoids blocking and uses the modern API; AVAssetReader
                    // can still operate on the same AVURLAsset once tracks are available.
                    let tracks = try await asset.loadTracks(withMediaType: .audio)
                    guard let track = tracks.first else {
                        throw ExportError.unsupportedAudioFormat(description: "no audio track")
                    }

                    let outputSettings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVLinearPCMBitDepthKey: 32,
                        AVLinearPCMIsFloatKey: true,
                        AVLinearPCMIsBigEndianKey: false,
                        AVLinearPCMIsNonInterleaved: false,
                        AVSampleRateKey: 48_000,
                        AVNumberOfChannelsKey: 2
                    ]

                    let reader: AVAssetReader
                    do {
                        reader = try AVAssetReader(asset: asset)
                    } catch {
                        throw ExportError.fileUnreadable(url, description: error.localizedDescription)
                    }
                    let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
                    output.alwaysCopiesSampleData = false
                    guard reader.canAdd(output) else {
                        throw ExportError.fileUnreadable(url, description: "reader cannot add output")
                    }
                    reader.add(output)

                    guard reader.startReading() else {
                        let desc = reader.error?.localizedDescription ?? "startReading returned false"
                        throw ExportError.fileUnreadable(url, description: desc)
                    }

                    let chunkFrames = 1024
                    var mono  = [Float](); mono.reserveCapacity(chunkFrames)
                    var left  = [Float](); left.reserveCapacity(chunkFrames)
                    var right = [Float](); right.reserveCapacity(chunkFrames)

                    while !Task.isCancelled, let sample = output.copyNextSampleBuffer() {
                        var blockBufferOut: CMBlockBuffer?
                        var abl = AudioBufferList(
                            mNumberBuffers: 1,
                            mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: 0, mData: nil)
                        )
                        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                            sample,
                            bufferListSizeNeededOut: nil,
                            bufferListOut: &abl,
                            bufferListSize: MemoryLayout<AudioBufferList>.size,
                            blockBufferAllocator: nil,
                            blockBufferMemoryAllocator: nil,
                            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                            blockBufferOut: &blockBufferOut
                        )
                        guard status == noErr, let data = abl.mBuffers.mData else {
                            continue
                        }
                        let totalFloats = Int(abl.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
                        let channels = max(Int(abl.mBuffers.mNumberChannels), 1)
                        let frames = totalFloats / channels
                        let p = data.assumingMemoryBound(to: Float.self)

                        for i in 0..<frames {
                            let l = p[i * channels + 0]
                            let r = channels >= 2 ? p[i * channels + 1] : l
                            left.append(l)
                            right.append(r)
                            mono.append((l + r) * 0.5)
                            if mono.count == chunkFrames {
                                let frame = AudioFrame(
                                    samples: mono,
                                    sampleRate: SampleRate(hz: 48_000),
                                    timestamp: HostTime(machAbsolute: mach_absolute_time()),
                                    left: left,
                                    right: right
                                )
                                continuation.yield(frame)
                                mono.removeAll(keepingCapacity: true)
                                left.removeAll(keepingCapacity: true)
                                right.removeAll(keepingCapacity: true)
                            }
                        }
                    }

                    if reader.status == .failed {
                        let desc = reader.error?.localizedDescription ?? "reader failed"
                        throw ExportError.fileUnreadable(url, description: desc)
                    }

                    // Zero-pad the final partial chunk so downstream code always sees a
                    // 1024-frame AudioFrame — matches the live capture's drainer contract.
                    if !mono.isEmpty {
                        let padCount = chunkFrames - mono.count
                        if padCount > 0 {
                            mono.append(contentsOf: repeatElement(0, count: padCount))
                            left.append(contentsOf: repeatElement(0, count: padCount))
                            right.append(contentsOf: repeatElement(0, count: padCount))
                        }
                        let frame = AudioFrame(
                            samples: mono,
                            sampleRate: SampleRate(hz: 48_000),
                            timestamp: HostTime(machAbsolute: mach_absolute_time()),
                            left: left,
                            right: right
                        )
                        continuation.yield(frame)
                    }

                    continuation.finish()
                } catch let err as ExportError {
                    continuation.finish(throwing: err)
                } catch {
                    continuation.finish(throwing: ExportError.fileUnreadable(url, description: error.localizedDescription))
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func estimatedFrameCount(url: URL) async throws -> Int? {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            guard seconds.isFinite, seconds > 0 else { return nil }
            return Int(seconds * 48_000)
        } catch {
            return nil
        }
    }
}
