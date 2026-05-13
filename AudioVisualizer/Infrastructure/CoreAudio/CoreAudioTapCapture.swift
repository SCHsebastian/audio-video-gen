import CoreAudio
import AVFoundation
import Foundation
import os
import Domain

final class CoreAudioTapCapture: SystemAudioCapturing, @unchecked Sendable {
    private static let log = OSLog(subsystem: "dev.audiovideogen.AudioVisualizer", category: "capture")
    private var tapID: AudioObjectID = 0
    private var aggID: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?
    private let drainQueue = DispatchQueue(label: "tap.drain", qos: .userInteractive)
    private var ring: RingBuffer?
    private var sampleRate: Double = 48_000
    private var channelCount: Int = 2
    private var deviceChangeListener: AudioObjectPropertyListenerBlock?
    private var currentSource: AudioSource?

    private static func sweepStaleAggregates() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        let uuidRegex = try! NSRegularExpression(pattern: "^[0-9A-Fa-f-]{36}$")
        for id in ids {
            if let uid = try? id.readString(kAudioDevicePropertyDeviceUID),
               uuidRegex.firstMatch(in: uid, options: [], range: NSRange(uid.startIndex..., in: uid)) != nil {
                AudioHardwareDestroyAggregateDevice(id)
            }
        }
    }

    func start(source: AudioSource) async throws -> AsyncStream<AudioFrame> {
        CoreAudioTapCapture.sweepStaleAggregates()
        let desc: CATapDescription
        switch source {
        case .systemWide:
            // Global tap with no exclusions = tap every process on the default output.
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        case .process(_, let bundleID):
            // Lenient matching: find every audio process whose parent bundle ID matches
            // the parent of the requested bundle ID. Chrome can have multiple helpers
            // (Audio, Plugin, GPU) — we want to tap them all, since any of them might
            // be the one currently producing audio. This is also resilient to helper
            // respawns where the specific helper that was visible at picker time has
            // since restarted under a different sub-bundle-ID.
            let matches = Self.findAudioProcessObjects(matchingParentOf: bundleID)
            if matches.isEmpty {
                // Nothing matched — fall back to system-wide capture so the visualizer
                // still shows something. The user's picker selection is preserved; the
                // next start() (after they re-select or refresh) may find it once the
                // helper produces audio again. Logged for diagnostics.
                os_log(.info, log: Self.log, "No audio processes match parent of %{public}@; falling back to system-wide", bundleID)
                desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            } else {
                desc = CATapDescription(stereoMixdownOfProcesses: matches)
            }
        }
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted

        var newTap: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(desc, &newTap)
        guard tapStatus == noErr else { throw CaptureError.tapCreationFailed(tapStatus) }
        self.tapID = newTap

        let outUID: String
        do { outUID = try AudioObjectID.defaultSystemOutputUID() }
        catch { AudioHardwareDestroyProcessTap(tapID); throw error }

        let dict: [String: Any] = [
            kAudioAggregateDeviceUIDKey:           UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey:     true,
            kAudioAggregateDeviceIsStackedKey:     false,
            kAudioAggregateDeviceTapAutoStartKey:  true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]
        var newAgg: AudioObjectID = 0
        let aggStatus = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &newAgg)
        guard aggStatus == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            throw CaptureError.aggregateDeviceCreationFailed(aggStatus)
        }
        self.aggID = newAgg

        // Read tap format.
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: asbd))
        let fmtStatus = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard fmtStatus == noErr else {
            AudioHardwareDestroyAggregateDevice(aggID); AudioHardwareDestroyProcessTap(tapID)
            throw CaptureError.formatUnsupported(description: "tap format read failed")
        }
        self.sampleRate = asbd.mSampleRate
        self.channelCount = Int(asbd.mChannelsPerFrame)
        let nonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        // Issue 3 fix: ring always sized for mono Float32 output (4 bytes/frame), regardless of input format.
        // With mono mixdown in the IOProc, we write exactly 4 bytes per input frame.
        let monoFrameBytes = 4  // always mix down to mono Float32
        let capacityBytes = Int(self.sampleRate) * monoFrameBytes / 2
        let ring = RingBuffer(capacityBytes: capacityBytes)
        self.ring = ring

        let (stream, continuation) = AsyncStream<AudioFrame>.makeStream(bufferingPolicy: .bufferingNewest(8))

        // IOProc — DO NOT capture self strongly, DO NOT allocate, DO NOT touch Swift runtime.
        // Issue 2 fix: downmix to mono Float32 in the IOProc so the ring always holds mono samples,
        // eliminating the garbled-audio bug in the non-interleaved multi-callback drain path.
        let ringRef = Unmanaged.passUnretained(ring).toOpaque()
        let unsafeRing = OpaquePointer(ringRef)
        let ch = channelCount
        let chF = Float(ch)
        var newProc: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&newProc, aggID, drainQueue) { _, inData, _, _, _ in
            let ablPtr = UnsafePointer<AudioBufferList>(OpaquePointer(inData))
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: ablPtr))
            let r = Unmanaged<RingBuffer>.fromOpaque(UnsafeRawPointer(unsafeRing)).takeUnretainedValue()

            let bufferCount = buffers.count
            if !nonInterleaved {
                // Interleaved: single buffer with layout [L, R, L, R, ...]
                let buf = buffers[0]
                guard let data = buf.mData else { return }
                let p = data.assumingMemoryBound(to: Float.self)
                let totalFloats = Int(buf.mDataByteSize) / 4
                let frames = totalFloats / ch
                for i in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<ch { sum += p[i * ch + c] }
                    var mono = sum / chF
                    _ = r.write(&mono, byteCount: 4)
                }
            } else {
                // Non-interleaved: bufferCount == ch, each buffer is one channel of `frames` floats.
                let frames = bufferCount > 0 ? Int(buffers[0].mDataByteSize) / 4 : 0
                for i in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<bufferCount {
                        if let p = buffers[c].mData?.assumingMemoryBound(to: Float.self) {
                            sum += p[i]
                        }
                    }
                    var mono = sum / chF
                    _ = r.write(&mono, byteCount: 4)
                }
            }
        }
        guard ioStatus == noErr, let pid = newProc else {
            AudioHardwareDestroyAggregateDevice(aggID); AudioHardwareDestroyProcessTap(tapID)
            throw CaptureError.ioProcStartFailed(ioStatus)
        }
        self.procID = pid

        let startStatus = AudioDeviceStart(aggID, pid)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggID, pid)
            AudioHardwareDestroyAggregateDevice(aggID); AudioHardwareDestroyProcessTap(tapID)
            throw CaptureError.ioProcStartFailed(startStatus)
        }

        // Drainer: every ~5 ms, pull mono Float32 frames out of the ring and yield 1024-sample chunks.
        // Issue 2 fix: no more interleaved/non-interleaved branching — ring always holds mono Float32.
        let sr = sampleRate
        drainQueue.async { [weak self] in
            guard let self else { return }
            let chunkFrames = 1024
            var accumulator = [Float]()
            accumulator.reserveCapacity(chunkFrames)
            var lastYield = CACurrentMediaTime()
            let silentTimeout = 0.5
            // Issue 1 fix: procID is read only on drainQueue; stop() writes it on drainQueue too
            // (via drainQueue.async in stop()), so this check is properly serialized.
            while self.procID != nil {
                let (ptr, bytes) = ring.peek()
                if let ptr, bytes >= 4 {
                    let frames = bytes / 4
                    let floats = ptr.assumingMemoryBound(to: Float.self)
                    for i in 0..<frames {
                        accumulator.append(floats[i])
                        if accumulator.count == chunkFrames {
                            let frame = AudioFrame(samples: accumulator,
                                                   sampleRate: SampleRate(hz: sr),
                                                   timestamp: HostTime(machAbsolute: mach_absolute_time()))
                            continuation.yield(frame)
                            accumulator.removeAll(keepingCapacity: true)
                            lastYield = CACurrentMediaTime()
                        }
                    }
                    ring.markRead(byteCount: frames * 4)
                } else {
                    // No data; sleep ~5 ms.
                    Thread.sleep(forTimeInterval: 0.005)
                    let now = CACurrentMediaTime()
                    if now - lastYield > silentTimeout {
                        let silent = AudioFrame(samples: Array(repeating: 0, count: 1024),
                                                sampleRate: SampleRate(hz: sr),
                                                timestamp: HostTime(machAbsolute: mach_absolute_time()))
                        continuation.yield(silent)
                        lastYield = now
                    }
                }
            }
            continuation.finish()
        }

        continuation.onTermination = { [weak self] _ in Task { await self?.stop() } }

        // Save source so restart() can document the limitation when device changes.
        currentSource = source

        // Register a listener for default output device changes.
        // When the user switches the system output device the aggregate becomes stale;
        // we stop capture so the next explicit start() builds against the new device.
        // (Documented limitation in v0.1.0 — full reconnect requires the use-case to retry.)
        var deviceAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            Task { await self.restart() }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &deviceAddr, drainQueue, listener)
        deviceChangeListener = listener

        return stream
    }

    /// Called when the default system output device changes.
    /// Stops the current capture; the downstream AsyncStream will finish.
    /// The user must restart visualization explicitly to pick up the new device.
    private func restart() async {
        // Default output device changed. Stop current capture.
        // The downstream AsyncStream will finish; user will need to restart explicitly.
        // (Documented limitation in v0.1.0.)
        await stop()
    }

    func stop() async {
        // Issue 1 fix: serialize all hardware teardown onto drainQueue so it cannot race
        // with the drain loop's `while self.procID != nil` check. Both the read (drainer)
        // and the write (here) now happen on the same serial queue.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            drainQueue.async {
                // Remove the default-output-device change listener before tearing down hardware.
                if let listener = self.deviceChangeListener {
                    var deviceAddr = AudioObjectPropertyAddress(
                        mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain)
                    AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &deviceAddr, self.drainQueue, listener)
                    self.deviceChangeListener = nil
                }
                self.currentSource = nil

                if let pid = self.procID, self.aggID != 0 {
                    AudioDeviceStop(self.aggID, pid)
                    AudioDeviceDestroyIOProcID(self.aggID, pid)
                }
                // Writing procID = nil on drainQueue: this is what the drainer loop checks,
                // so it will see nil on its next iteration and exit cleanly.
                self.procID = nil
                if self.aggID != 0 { AudioHardwareDestroyAggregateDevice(self.aggID); self.aggID = 0 }
                if self.tapID != 0 { AudioHardwareDestroyProcessTap(self.tapID); self.tapID = 0 }
                self.ring = nil
                cont.resume()
            }
        }
    }

    /// Find all audio process objects whose bundle ID shares a parent with `bundleID`.
    /// Uses RunningApplicationsDiscovery.parentBundleID(of:) heuristic for matching.
    private static func findAudioProcessObjects(matchingParentOf bundleID: String) -> [AudioObjectID] {
        let targetParent = RunningApplicationsDiscovery.parentBundleID(of: bundleID)

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else {
            return []
        }

        return ids.compactMap { id -> AudioObjectID? in
            guard let bid = try? id.readString(kAudioProcessPropertyBundleID), !bid.isEmpty else { return nil }
            let candidateParent = RunningApplicationsDiscovery.parentBundleID(of: bid)
            return candidateParent == targetParent ? id : nil
        }
    }
}
