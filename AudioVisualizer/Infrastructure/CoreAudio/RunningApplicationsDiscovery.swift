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

        // Step 1: collect raw entries
        struct RawEntry {
            let pid: pid_t
            let bundleID: String
            let parentBundleID: String   // == bundleID if not a helper
            let isProducingAudio: Bool
        }

        let raw: [RawEntry] = ids.compactMap { id -> RawEntry? in
            guard
                let pid = try? id.read(kAudioProcessPropertyPID, default: pid_t(0)), pid > 0,
                let bid = try? id.readString(kAudioProcessPropertyBundleID), !bid.isEmpty
            else { return nil }
            let isOutput: UInt32 = (try? id.read(kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) ?? 0
            return RawEntry(
                pid: pid,
                bundleID: bid,
                parentBundleID: Self.parentBundleID(of: bid),
                isProducingAudio: isOutput != 0)
        }

        // Step 2: group by parentBundleID, picking the best representative per group.
        // Best = the entry with isProducingAudio == true, else the first encountered.
        var grouped: [String: RawEntry] = [:]
        for entry in raw {
            if let existing = grouped[entry.parentBundleID] {
                if entry.isProducingAudio && !existing.isProducingAudio {
                    grouped[entry.parentBundleID] = entry
                }
            } else {
                grouped[entry.parentBundleID] = entry
            }
        }

        // Step 3: resolve display names via NSWorkspace
        let merged: [AudioProcessInfo] = grouped.values.map { entry in
            // Prefer the parent app's localized name; fall back to the raw bundle ID.
            let parentApp = workspace.first { $0.bundleIdentifier == entry.parentBundleID }
            let helperApp = workspace.first { $0.processIdentifier == entry.pid }
            let displayName = parentApp?.localizedName
                ?? helperApp?.localizedName
                ?? Self.prettifyBundleID(entry.parentBundleID)
            return AudioProcessInfo(
                pid: entry.pid,
                bundleID: entry.bundleID,    // store the actual audio helper's bundle ID for Fix B's lookup
                displayName: displayName,
                isProducingAudio: entry.isProducingAudio)
        }

        // Step 4: sort — audio-producing first, then alphabetical
        return merged.sorted { lhs, rhs in
            if lhs.isProducingAudio != rhs.isProducingAudio { return lhs.isProducingAudio }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    /// Strip helper suffixes to get the parent bundle ID.
    /// Examples:
    ///   "com.google.Chrome.helper.Audio" -> "com.google.Chrome"
    ///   "com.google.Chrome.helper"       -> "com.google.Chrome"
    ///   "com.apple.WebKit.WebContent"    -> "com.apple.WebKit"
    ///   "com.apple.WebKit.GPU"           -> "com.apple.WebKit"
    ///   "org.mozilla.plugincontainer"    -> "org.mozilla.plugincontainer"   (no change)
    ///   "com.spotify.client"             -> "com.spotify.client"            (no change)
    static func parentBundleID(of bid: String) -> String {
        // Heuristic 1: ".helper" suffix or substring
        if let range = bid.range(of: ".helper", options: [.caseInsensitive]) {
            return String(bid[..<range.lowerBound])
        }
        // Heuristic 2: WebKit-style children
        let webKitChildren = [".WebContent", ".Networking", ".GPU", ".Plugin"]
        for suffix in webKitChildren {
            if let range = bid.range(of: suffix, options: [.caseInsensitive, .backwards]),
               range.upperBound == bid.endIndex {
                return String(bid[..<range.lowerBound])
            }
        }
        return bid
    }

    /// For unknown helper bundle IDs that we couldn't resolve via NSWorkspace, produce a tidy fallback.
    /// "com.foo.MyApp" -> "MyApp"
    /// "tld.org.something" -> "something"
    static func prettifyBundleID(_ bid: String) -> String {
        let parts = bid.split(separator: ".")
        return parts.last.map(String.init) ?? bid
    }
}
