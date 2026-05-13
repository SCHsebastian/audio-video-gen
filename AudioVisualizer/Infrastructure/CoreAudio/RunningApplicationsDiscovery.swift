import AppKit
import CoreAudio
import Domain

final class RunningApplicationsDiscovery: ProcessDiscovering, @unchecked Sendable {
    func listAudioProcesses() async throws -> [AudioProcessInfo] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(.system, &addr, 0, nil, &size)
        guard status == noErr else { throw CaptureError.tapCreationFailed(status) }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(.system, &addr, 0, nil, &size, &ids)
        guard status == noErr else { throw CaptureError.tapCreationFailed(status) }

        let workspace = NSWorkspace.shared.runningApplications
        return ids.compactMap { id -> AudioProcessInfo? in
            guard
                let pid = try? id.read(kAudioProcessPropertyPID, default: pid_t(0)), pid > 0,
                let bid = try? id.readString(kAudioProcessPropertyBundleID), !bid.isEmpty
            else { return nil }
            let app = workspace.first { $0.processIdentifier == pid }
            let name = app?.localizedName ?? bid
            let isOutput: UInt32 = (try? id.read(kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) ?? 0
            return AudioProcessInfo(pid: pid, bundleID: bid, displayName: name, isProducingAudio: isOutput != 0)
        }
    }
}
