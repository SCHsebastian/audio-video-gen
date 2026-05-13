import CoreAudio
import AVFoundation
import Foundation
import Domain

final class CoreAudioTapCapture: SystemAudioCapturing, @unchecked Sendable {
    private var tapID: AudioObjectID = 0
    private var aggID: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?
    private let drainQueue = DispatchQueue(label: "tap.drain", qos: .userInteractive)
    private var ring: RingBuffer?
    private var sampleRate: Double = 48_000
    private var channelCount: Int = 2
    private var isInterleaved: Bool = true
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
        let processList: [AudioObjectID]
        switch source {
        case .systemWide:
            processList = []   // empty list with stereoMixdown means "all processes on default output"
        case .process(let pid, _):
            processList = [try AudioObjectID.translatePID(pid)]
        }

        let desc: CATapDescription
        if processList.isEmpty {
            desc = CATapDescription(stereoMixdownOfProcesses: [])
        } else {
            desc = CATapDescription(stereoMixdownOfProcesses: processList)
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
        self.isInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        let bytesPerFrame = Int(asbd.mBytesPerFrame == 0 ? 4 * UInt32(channelCount) : asbd.mBytesPerFrame)

        // Allocate ring: 0.5 sec at the discovered rate.
        let capacityBytes = Int(self.sampleRate) * bytesPerFrame / 2
        let ring = RingBuffer(capacityBytes: capacityBytes)
        self.ring = ring

        let (stream, continuation) = AsyncStream<AudioFrame>.makeStream(bufferingPolicy: .bufferingNewest(8))

        // IOProc — DO NOT capture self strongly, DO NOT allocate, DO NOT touch Swift runtime.
        let ringRef = Unmanaged.passUnretained(ring).toOpaque()
        let unsafeRing = OpaquePointer(ringRef)
        var newProc: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&newProc, aggID, drainQueue) { _, inData, _, _, _ in
            // Non-interleaved float buffers; walk them and copy raw bytes into the ring.
            let abl = UnsafeBufferPointer(start: UnsafePointer(inData),
                                          count: 1).baseAddress!.pointee
            let bufferCount = Int(abl.mNumberBuffers)
            withUnsafePointer(to: abl) { ptr in
                ptr.withMemoryRebound(to: AudioBufferList.self, capacity: 1) { listPtr in
                    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: listPtr))
                    for i in 0..<bufferCount {
                        let b = buffers[i]
                        guard let data = b.mData else { continue }
                        let r = Unmanaged<RingBuffer>.fromOpaque(UnsafeRawPointer(unsafeRing)).takeUnretainedValue()
                        _ = r.write(data, byteCount: Int(b.mDataByteSize))
                    }
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

        // Drainer: every ~21 ms, pull 1024 mono frames out of the ring and yield.
        let sr = sampleRate
        let ch = channelCount
        let bpf = bytesPerFrame
        let interleaved = isInterleaved
        drainQueue.async { [weak self] in
            guard let self else { return }
            let chunkFrames = 1024
            var accumulator = [Float]()
            accumulator.reserveCapacity(chunkFrames)
            var lastYield = CACurrentMediaTime()
            let silentTimeout = 0.5
            while self.procID != nil {
                let (ptr, bytes) = ring.peek()
                if let ptr, bytes >= bpf {
                    let frames = bytes / bpf
                    let floats = ptr.assumingMemoryBound(to: Float.self)
                    if interleaved {
                        // Interleaved: sample layout is [L, R, L, R, ...]
                        for i in 0..<frames {
                            var sum: Float = 0
                            for c in 0..<ch { sum += floats[i * ch + c] }
                            accumulator.append(sum / Float(ch))
                            if accumulator.count == chunkFrames {
                                let frame = AudioFrame(samples: accumulator,
                                                       sampleRate: SampleRate(hz: sr),
                                                       timestamp: HostTime(machAbsolute: mach_absolute_time()))
                                continuation.yield(frame)
                                accumulator.removeAll(keepingCapacity: true)
                                lastYield = CACurrentMediaTime()
                            }
                        }
                    } else {
                        // Non-interleaved: the ring received `ch` consecutive contiguous channel buffers per callback,
                        // each `frames` floats long. Walk them in parallel.
                        let perChannel = frames / ch     // assumes producer wrote N×ch frames
                        for i in 0..<perChannel {
                            var sum: Float = 0
                            for c in 0..<ch { sum += floats[c * perChannel + i] }
                            accumulator.append(sum / Float(ch))
                            if accumulator.count == chunkFrames {
                                let frame = AudioFrame(samples: accumulator,
                                                       sampleRate: SampleRate(hz: sr),
                                                       timestamp: HostTime(machAbsolute: mach_absolute_time()))
                                continuation.yield(frame)
                                accumulator.removeAll(keepingCapacity: true)
                                lastYield = CACurrentMediaTime()
                            }
                        }
                    }
                    ring.markRead(byteCount: frames * bpf)
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
        // Remove the default-output-device change listener before tearing down hardware.
        if let listener = deviceChangeListener {
            var deviceAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &deviceAddr, drainQueue, listener)
            deviceChangeListener = nil
        }
        currentSource = nil

        if let pid = procID, aggID != 0 { AudioDeviceStop(aggID, pid); AudioDeviceDestroyIOProcID(aggID, pid) }
        procID = nil
        if aggID != 0 { AudioHardwareDestroyAggregateDevice(aggID); aggID = 0 }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID); tapID = 0 }
        ring = nil
    }
}
