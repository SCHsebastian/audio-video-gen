import CoreAudio
import AVFoundation
import Foundation
import os.log
import Domain

// Heap-allocated stats counters updated exclusively by the IOProc.
// The drainer reads them once per second for logging (eventual consistency is fine).
private final class IOStats {
    var callbacks: Int64 = 0
    var frames: Int64 = 0
    var peakAmp: Float = 0
}

final class CoreAudioTapCapture: SystemAudioCapturing, @unchecked Sendable {
    private var tapID: AudioObjectID = 0
    private var aggID: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?
    private let drainQueue = DispatchQueue(label: "tap.drain", qos: .userInteractive)
    private var ring: RingBuffer?
    private var sampleRate: Double = 48_000
    private var channelCount: Int = 2
    private var deviceChangeListener: AudioObjectPropertyListenerBlock?
    private var currentSource: AudioSource?
    private var ioStats: IOStats?

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
        Log.capture.info("start: source=\(String(describing: source), privacy: .public)")
        CoreAudioTapCapture.sweepStaleAggregates()
        let desc: CATapDescription
        switch source {
        case .systemWide:
            // Global tap with no exclusions = tap every process on the default output.
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            Log.capture.info("desc: stereoGlobalTapButExcludeProcesses (system-wide)")
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
                Log.capture.notice("no audio processes match \(bundleID, privacy: .public); falling back to system-wide")
                desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            } else {
                Log.capture.info("desc: stereoMixdownOfProcesses with \(matches.count) processes for bundle \(bundleID, privacy: .public)")
                desc = CATapDescription(stereoMixdownOfProcesses: matches)
            }
        }
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted

        var newTap: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(desc, &newTap)
        guard tapStatus == noErr else {
            Log.capture.error("tap creation failed: status=\(tapStatus)")
            throw CaptureError.tapCreationFailed(tapStatus)
        }
        self.tapID = newTap
        Log.capture.info("tap created: id=\(newTap), uuid=\(desc.uuid.uuidString, privacy: .public)")

        let outUID: String
        do { outUID = try AudioObjectID.defaultSystemOutputUID() }
        catch { AudioHardwareDestroyProcessTap(tapID); throw error }
        Log.capture.info("default output UID: \(outUID, privacy: .public)")

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
            Log.capture.error("aggregate device creation failed: status=\(aggStatus)")
            AudioHardwareDestroyProcessTap(tapID)
            throw CaptureError.aggregateDeviceCreationFailed(aggStatus)
        }
        self.aggID = newAgg
        Log.capture.info("aggregate device created: id=\(newAgg)")

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
        Log.capture.info("tap format: sampleRate=\(asbd.mSampleRate, privacy: .public) channels=\(asbd.mChannelsPerFrame, privacy: .public) formatFlags=\(asbd.mFormatFlags, privacy: .public) nonInterleaved=\(nonInterleaved, privacy: .public)")

        // Ring stores stereo Float32 pairs — 8 bytes/frame regardless of source format.
        // Mono sources duplicate the single channel onto both L and R inside the IOProc
        // so the drainer's stride is uniform. The mono mixdown is recomputed on the
        // drain side (the IOProc must stay allocation-free and runtime-free).
        let stereoFrameBytes = 8
        let capacityBytes = Int(self.sampleRate) * stereoFrameBytes / 2
        let ring = RingBuffer(capacityBytes: capacityBytes)
        self.ring = ring

        let (stream, continuation) = AsyncStream<AudioFrame>.makeStream(bufferingPolicy: .bufferingNewest(8))

        // IOProc — DO NOT capture self strongly, DO NOT allocate, DO NOT touch Swift runtime.
        // Writes lockstep (L, R) Float32 pairs to the ring for every input frame:
        // interleaved sources are sampled position-by-position; non-interleaved ones
        // walk the per-channel buffers in lockstep so the L/R pair never desynchronises.
        let ringRef = Unmanaged.passUnretained(ring).toOpaque()
        let unsafeRing = OpaquePointer(ringRef)
        let ch = channelCount

        // Allocate stats on the heap; hand an opaque pointer to the IOProc so it can
        // update counters without touching the Swift runtime (same pattern as unsafeRing above).
        let stats = IOStats()
        self.ioStats = stats
        let statsRef = Unmanaged.passUnretained(stats).toOpaque()
        let unsafeStats = OpaquePointer(statsRef)

        var newProc: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&newProc, aggID, nil) { _, inData, _, _, _ in
            let ablPtr = UnsafePointer<AudioBufferList>(OpaquePointer(inData))
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: ablPtr))
            let r = Unmanaged<RingBuffer>.fromOpaque(UnsafeRawPointer(unsafeRing)).takeUnretainedValue()
            let s = Unmanaged<IOStats>.fromOpaque(UnsafeRawPointer(unsafeStats)).takeUnretainedValue()

            s.callbacks &+= 1
            let bufferCount = buffers.count
            if !nonInterleaved {
                // Interleaved: single buffer with layout [c0, c1, ..., c0, c1, ...]
                let buf = buffers[0]
                guard let data = buf.mData else { return }
                let p = data.assumingMemoryBound(to: Float.self)
                let totalFloats = Int(buf.mDataByteSize) / 4
                let frames = totalFloats / ch
                for i in 0..<frames {
                    let l: Float = p[i * ch + 0]
                    let r2: Float = ch >= 2 ? p[i * ch + 1] : l
                    var pair: (Float, Float) = (l, r2)
                    let m = (l + r2) * 0.5
                    s.peakAmp = s.peakAmp > abs(m) ? s.peakAmp : abs(m)
                    s.frames &+= 1
                    _ = r.write(&pair, byteCount: 8)
                }
            } else {
                // Non-interleaved: bufferCount == ch, each buffer is one channel of `frames` floats.
                let frames = bufferCount > 0 ? Int(buffers[0].mDataByteSize) / 4 : 0
                let pL = buffers[0].mData?.assumingMemoryBound(to: Float.self)
                let pR = (bufferCount >= 2) ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : pL
                guard let pL else { return }
                for i in 0..<frames {
                    let l: Float = pL[i]
                    let r2: Float = pR?[i] ?? l
                    var pair: (Float, Float) = (l, r2)
                    let m = (l + r2) * 0.5
                    s.peakAmp = s.peakAmp > abs(m) ? s.peakAmp : abs(m)
                    s.frames &+= 1
                    _ = r.write(&pair, byteCount: 8)
                }
            }
        }
        guard ioStatus == noErr, let pid = newProc else {
            Log.capture.error("IOProc creation failed: status=\(ioStatus)")
            AudioHardwareDestroyAggregateDevice(aggID); AudioHardwareDestroyProcessTap(tapID)
            throw CaptureError.ioProcStartFailed(ioStatus)
        }
        self.procID = pid
        Log.capture.info("IOProc registered")

        let startStatus = AudioDeviceStart(aggID, pid)
        guard startStatus == noErr else {
            Log.capture.error("AudioDeviceStart failed: status=\(startStatus)")
            AudioDeviceDestroyIOProcID(aggID, pid)
            AudioHardwareDestroyAggregateDevice(aggID); AudioHardwareDestroyProcessTap(tapID)
            throw CaptureError.ioProcStartFailed(startStatus)
        }
        Log.capture.info("AudioDeviceStart succeeded; capture is live")

        // Drainer: every ~5 ms, pull stereo Float32 pairs out of the ring and yield
        // 1024-frame chunks with mono mixdown + L/R channels in the AudioFrame.
        let sr = sampleRate
        drainQueue.async { [weak self] in
            guard let self else { return }
            Log.capture.info("drainer started")
            let chunkFrames = 1024
            var monoAccum  = [Float](); monoAccum.reserveCapacity(chunkFrames)
            var leftAccum  = [Float](); leftAccum.reserveCapacity(chunkFrames)
            var rightAccum = [Float](); rightAccum.reserveCapacity(chunkFrames)
            var lastYield = CACurrentMediaTime()
            var lastStatLog = CACurrentMediaTime()
            let silentTimeout = 0.5
            // Issue 1 fix: procID is read only on drainQueue; stop() writes it on drainQueue too
            // (via drainQueue.async in stop()), so this check is properly serialized.
            while self.procID != nil {
                let (ptr, bytes) = ring.peek()
                if let ptr, bytes >= 8 {
                    let frames = bytes / 8
                    let floats = ptr.assumingMemoryBound(to: Float.self)
                    for i in 0..<frames {
                        let l = floats[i * 2 + 0]
                        let r2 = floats[i * 2 + 1]
                        leftAccum.append(l)
                        rightAccum.append(r2)
                        monoAccum.append((l + r2) * 0.5)
                        if monoAccum.count == chunkFrames {
                            let frame = AudioFrame(samples: monoAccum,
                                                   sampleRate: SampleRate(hz: sr),
                                                   timestamp: HostTime(machAbsolute: mach_absolute_time()),
                                                   left: leftAccum,
                                                   right: rightAccum)
                            continuation.yield(frame)
                            monoAccum.removeAll(keepingCapacity: true)
                            leftAccum.removeAll(keepingCapacity: true)
                            rightAccum.removeAll(keepingCapacity: true)
                            lastYield = CACurrentMediaTime()
                        }
                    }
                    ring.markRead(byteCount: frames * 8)
                } else {
                    // No data; sleep ~5 ms.
                    Thread.sleep(forTimeInterval: 0.005)
                    let now = CACurrentMediaTime()
                    if now - lastYield > silentTimeout {
                        let silentBuf = Array<Float>(repeating: 0, count: 1024)
                        let silent = AudioFrame(samples: silentBuf,
                                                sampleRate: SampleRate(hz: sr),
                                                timestamp: HostTime(machAbsolute: mach_absolute_time()),
                                                left: silentBuf,
                                                right: silentBuf)
                        continuation.yield(silent)
                        lastYield = now
                    }
                }

                // Periodic IO stats — once per second, read and reset counters set by the IOProc.
                let statNow = CACurrentMediaTime()
                if statNow - lastStatLog >= 1.0 {
                    let cbs = stats.callbacks; stats.callbacks = 0
                    let frs = stats.frames;    stats.frames = 0
                    let peak = stats.peakAmp;  stats.peakAmp = 0
                    Log.capture.info("io: callbacks/s=\(cbs, privacy: .public) frames/s=\(frs, privacy: .public) peakAmp=\(peak, privacy: .public)")
                    lastStatLog = statNow
                }
            }
            continuation.finish()
            Log.capture.info("drainer exited")
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
                Log.capture.info("stop")
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
                self.ioStats = nil
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
