import CoreAudio
import Domain

final class TCCAudioCapturePermission: PermissionRequesting, @unchecked Sendable {
    func current() async -> PermissionState {
        // No public API for "Audio Capture" TCC; we treat success/failure of a tiny throwaway tap
        // attempt as ground truth on first call. Cache the result.
        if let cached { return cached }
        let probe = await probe()
        cached = probe
        return probe
    }

    func request() async -> PermissionState {
        // Creating a tap will trigger the TCC prompt the first time; thereafter the user's choice persists.
        let result = await probe()
        cached = result
        return result
    }

    private var cached: PermissionState?

    private func probe() async -> PermissionState {
        // Construct a tap on the default output device with NO processes (passthrough).
        // If the OS rejects it with kAudioHardwareIllegalOperationError, treat as denied.
        let desc = CATapDescription(stereoMixdownOfProcesses: [])
        desc.uuid = UUID()
        var tapID: AudioObjectID = 0
        let status = AudioHardwareCreateProcessTap(desc, &tapID)
        defer { if tapID != 0 { AudioHardwareDestroyProcessTap(tapID) } }
        switch status {
        case noErr: return .granted
        case OSStatus(kAudioHardwareIllegalOperationError): return .denied
        default: return .undetermined
        }
    }
}
