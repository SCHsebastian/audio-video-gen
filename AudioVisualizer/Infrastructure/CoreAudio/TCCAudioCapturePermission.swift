import CoreAudio
import Foundation
import Domain
import os.log

/// macOS TCC has no public read-only API for the "Audio Capture" entitlement,
/// so the only way to learn our state is to try creating a process tap. The
/// FIRST such attempt — across the entire lifetime of the app's TCC record —
/// triggers the OS dialog. After the user has answered, subsequent probes
/// return `noErr` (granted) or `kAudioHardwareIllegalOperationError` (denied)
/// **immediately and silently**, no UI involved.
///
/// We exploit that contract to make the permission state survive relaunches:
///
/// 1. On `init` we read a UserDefaults flag (`prompted`).
/// 2. If `prompted == true`, we run a synchronous probe immediately. Because
///    the OS has already remembered the answer, no UI appears, and the
///    result becomes our seeded cache. From the user's point of view, the
///    PermissionGate never shows on a granted relaunch.
/// 3. If `prompted == false`, we leave the cache empty. The first `request()`
///    call (triggered by the user clicking "Grant" in the in-app gate) does
///    the probe — which IS the only call that should ever surface the OS
///    dialog — and sets `prompted = true` so future launches take path (2).
///
/// In addition this actor enforces:
///
///  - Cache short-circuit: once we hold a definitive answer (`granted` /
///    `denied`), neither `current()` nor `request()` ever probes again.
///  - In-flight serialization: concurrent callers `await` the same probe
///    Task instead of stacking parallel TCC requests.
///  - Side-effect-free `current()`: it returns the cached answer or
///    `.undetermined`. It never triggers a prompt. Only `request()` does.
actor TCCAudioCapturePermission: PermissionRequesting {
    private var cached: PermissionState?
    private var inflight: Task<PermissionState, Never>?
    private let defaults: UserDefaults
    private static let promptedKey = "audioCapture.prompted.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // If we've prompted before, the OS already has a persistent answer.
        // Probing now is silent (no UI) and seeds the cache so the
        // PermissionGate doesn't flash on launch.
        if defaults.bool(forKey: Self.promptedKey) {
            let result = Self.probe()
            if result != .undetermined {
                self.cached = result
                Log.capture.info("permission.init: seeded cache from silent probe → \(String(describing: result), privacy: .public)")
            } else {
                Log.capture.notice("permission.init: stored 'prompted' flag but silent probe was inconclusive")
            }
        } else {
            Log.capture.info("permission.init: never prompted, cache empty")
        }
    }

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
        // Once we've crossed the OS-prompt boundary at least once, mark the
        // flag so future launches can silently seed their cache in init().
        defaults.set(true, forKey: Self.promptedKey)
        Log.capture.info("permission.request: result=\(String(describing: result), privacy: .public)")
        return result
    }

    /// Synchronous probe — creates a zero-process tap. Costs ~microseconds
    /// once the user has decided; only the very first call ever shows UI.
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
