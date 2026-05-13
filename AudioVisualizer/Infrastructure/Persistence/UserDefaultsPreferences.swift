import Foundation
import Domain

final class UserDefaultsPreferences: PreferencesStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "userPreferences.v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> UserPreferences {
        guard
            let data = defaults.data(forKey: key),
            let dto = try? JSONDecoder().decode(DTO.self, from: data)
        else { return .default }
        return dto.toDomain()
    }

    func save(_ prefs: UserPreferences) {
        let dto = DTO(domain: prefs)
        if let data = try? JSONEncoder().encode(dto) {
            defaults.set(data, forKey: key)
        }
    }

    /// Map persisted scene-order strings to `SceneKind`, drop unknowns, and
    /// append any cases the user has never seen (e.g. after upgrading to a
    /// build that adds new scenes) at the tail. Returns `allCases` for nil/
    /// empty input.
    private static func reconcileSceneOrder(from raw: [String]?) -> [SceneKind] {
        guard let raw, !raw.isEmpty else { return SceneKind.allCases }
        var seen: Set<SceneKind> = []
        var out: [SceneKind] = []
        for s in raw {
            if let k = SceneKind(rawValue: s), !seen.contains(k) {
                out.append(k); seen.insert(k)
            }
        }
        for k in SceneKind.allCases where !seen.contains(k) { out.append(k) }
        return out
    }

    private struct DTO: Codable {
        let sourceKind: String              // "systemWide" or "process"
        let pid: Int32?
        let bundleID: String?
        let scene: String
        let paletteName: String
        let language: String?
        let speed: Float?
        // New in v0.2 — all optional for backward compat.
        let audioGain: Float?
        let beatSensitivity: Float?
        let reduceMotion: Bool?
        let showDiagnostics: Bool?
        let maxFPS: Int?
        let sceneOrder: [String]?
        let shuffleEnabled: Bool?
        let shuffleIntervalSec: Int?

        init(domain p: UserPreferences) {
            switch p.lastSource {
            case .systemWide: sourceKind = "systemWide"; pid = nil; bundleID = nil
            case .process(let pid, let bid): sourceKind = "process"; self.pid = pid; bundleID = bid
            }
            scene = p.lastScene.rawValue
            paletteName = p.lastPaletteName
            language = p.lastLanguage.rawValue
            speed = p.speed
            audioGain = p.audioGain
            beatSensitivity = p.beatSensitivity
            reduceMotion = p.reduceMotion
            showDiagnostics = p.showDiagnostics
            maxFPS = p.maxFPS
            sceneOrder = p.sceneOrder.map(\.rawValue)
            shuffleEnabled = p.shuffleEnabled
            shuffleIntervalSec = p.shuffleIntervalSec
        }

        func toDomain() -> UserPreferences {
            let source: AudioSource = {
                if sourceKind == "process", let pid, let bundleID { return .process(pid: pid, bundleID: bundleID) }
                return .systemWide
            }()
            let scene = SceneKind(rawValue: scene) ?? .bars
            let lang = Language(rawValue: language ?? "") ?? .system
            return UserPreferences(
                lastSource: source,
                lastScene: scene,
                lastPaletteName: paletteName,
                lastLanguage: lang,
                speed: speed ?? 1.0,
                audioGain: audioGain ?? 1.0,
                beatSensitivity: beatSensitivity ?? 1.0,
                reduceMotion: reduceMotion ?? false,
                showDiagnostics: showDiagnostics ?? false,
                maxFPS: maxFPS ?? 120,
                sceneOrder: UserDefaultsPreferences.reconcileSceneOrder(from: sceneOrder),
                shuffleEnabled: shuffleEnabled ?? false,
                shuffleIntervalSec: shuffleIntervalSec ?? 180)
        }
    }
}
