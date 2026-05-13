import CoreAudio
import Domain
import os.log

/// macOS TCC has no public read-only API for the "Audio Capture" entitlement,
/// so the only way to learn our state is to try creating a process tap and see
/// what the OS does. The first such attempt triggers the TCC prompt; that's
/// the contract we have.
///
/// **The bug this guards against:** every probe is a *new* prompt while the
/// user hasn't decided yet. If the app calls `permissions.current()` six times
/// before the user clicks "Allow", macOS stacks six prompts. Earlier versions
/// of this class re-probed on every `current()` and on every `request()`
/// regardless of cache, and concurrent callers all probed in parallel — which
/// is exactly how a single launch ended up showing the system dialog six
/// times.
///
/// This actor enforces three rules:
///
/// 1. Once we have a definitive answer (`granted` or `denied`), we never probe
///    again — neither `current()` nor `request()` re-probes.
/// 2. Only one probe is ever in flight. Concurrent callers `await` the same
///    `Task`, so two simultaneous `request()` calls cause exactly one prompt.
/// 3. `current()` no longer auto-probes. It returns the cached answer or
///    `.undetermined` without side-effects, so the visualizer can show the
///    permission gate without the OS prompt fighting it. The system prompt
///    appears only when the user explicitly hits "Grant" (i.e. on `request()`).
actor TCCAudioCapturePermission: PermissionRequesting {
    private var cached: PermissionState?
    private var inflight: Task<PermissionState, Never>?

    /// Read-only: returns whatever we already know. Never triggers a prompt.
    func current() async -> PermissionState {
        if let cached, cached != .undetermined { return cached }
        if let inflight { return await inflight.value }
        return .undetermined
    }

    /// Trigger the TCC prompt — but only if we don't already have a definitive
    /// answer and no probe is already in flight.
    func request() async -> PermissionState {
        if let cached, cached != .undetermined {
            Log.capture.info("permission.request: short-circuit (cached)")
            return cached
        }
        if let inflight {
            Log.capture.info("permission.request: awaiting in-flight probe")
            return await inflight.value
        }
        let task = Task<PermissionState, Never> {
            Log.capture.info("permission.request: probing TCC")
            return Self.probe()
        }
        inflight = task
        let result = await task.value
        inflight = nil
        if result != .undetermined { cached = result }
        Log.capture.info("permission.request: result=\(String(describing: result), privacy: .public)")
        return result
    }

    /// Synchronous probe — creates a zero-process tap. The first call blocks
    /// on the TCC prompt; subsequent calls (once the user has decided) return
    /// immediately.
    private static func probe() -> PermissionState {
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
