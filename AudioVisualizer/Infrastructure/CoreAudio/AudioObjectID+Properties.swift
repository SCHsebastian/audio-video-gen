import CoreAudio
import Foundation
import Domain

extension AudioObjectID {
    static let system: AudioObjectID = AudioObjectID(kAudioObjectSystemObject)

    func read<T>(_ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                 default value: T) throws -> T {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var size: UInt32 = UInt32(MemoryLayout<T>.size)
        var out = value
        let status = AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &out)
        guard status == noErr else { throw CaptureError.tapCreationFailed(status) }
        return out
    }

    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString>.size)
        var cfStr: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &cfStr) {
            AudioObjectGetPropertyData(self, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let s = cfStr?.takeRetainedValue() else {
            throw CaptureError.tapCreationFailed(status)
        }
        return s as String
    }

    static func translatePID(_ pid: pid_t) throws -> AudioObjectID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var input = pid
        var output: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(.system, &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &input,
                                                &size, &output)
        guard status == noErr, output != 0 else { throw CaptureError.processNotFound(pid) }
        return output
    }

    static func defaultSystemOutputUID() throws -> String {
        let dev: AudioObjectID = try AudioObjectID.system.read(
            kAudioHardwarePropertyDefaultSystemOutputDevice, default: 0)
        guard dev != 0 else { throw CaptureError.defaultOutputDeviceUnavailable }
        return try dev.readString(kAudioDevicePropertyDeviceUID)
    }
}
