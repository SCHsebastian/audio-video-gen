import Foundation
import Domain
import os.log

final class FileSystemAIGameProgressStore: AIGameProgressStoring, @unchecked Sendable {
    private let root: URL
    private let queue = DispatchQueue(label: "aigame.progress")
    private let log = Logger(subsystem: "dev.audiovideogen.AudioVisualizer", category: "aigame")

    /// Production initializer — places snapshots under
    /// `Application Support/AudioVisualizer/AIGameProgress`.
    init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        self.root = appSupport
            .appendingPathComponent("AudioVisualizer", isDirectory: true)
            .appendingPathComponent("AIGameProgress", isDirectory: true)
        ensureRoot()
    }

    /// Test initializer — pass a temp directory.
    init(rootDirectory: URL) {
        self.root = rootDirectory
        ensureRoot()
    }

    private func ensureRoot() {
        try? FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
    }

    /// ISO-8601 with fractional seconds — `Date` carries sub-millisecond
    /// precision, and the bare `.iso8601` strategy truncates to whole seconds,
    /// breaking exact round-trip equality.
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(Self.iso8601Formatter.string(from: date))
        }
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            guard let date = Self.iso8601Formatter.date(from: s) else {
                throw DecodingError.dataCorruptedError(
                    in: try dec.singleValueContainer(),
                    debugDescription: "invalid ISO-8601 date: \(s)")
            }
            return date
        }
        return d
    }

    private func url(for id: UUID) -> URL {
        root.appendingPathComponent("\(id.uuidString).json")
    }

    func list() throws -> [AIGameProgress] {
        try queue.sync {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)) ?? []
            var out: [AIGameProgress] = []
            for u in urls where u.pathExtension == "json" {
                if let data = try? Data(contentsOf: u),
                   let p = try? decoder().decode(AIGameProgress.self, from: data) {
                    out.append(p)
                } else {
                    log.warning("skipping unreadable AI Game progress at \(u.lastPathComponent, privacy: .public)")
                }
            }
            return out.sorted { $0.createdAt > $1.createdAt }
        }
    }

    func save(_ progress: AIGameProgress) throws -> AIGameProgress {
        try queue.sync {
            let data = try encoder().encode(progress)
            do {
                try data.write(to: url(for: progress.id), options: .atomic)
            } catch {
                throw AIGameError.progressIOFailed(String(describing: error))
            }
            // Decode immediately so the returned record matches what `load`
            // will produce — JSON date round-trip can drop sub-millisecond
            // precision, and callers compare returned vs. loaded for equality.
            return (try? decoder().decode(AIGameProgress.self, from: data)) ?? progress
        }
    }

    func load(id: UUID) throws -> AIGameProgress {
        try queue.sync {
            let u = url(for: id)
            guard FileManager.default.fileExists(atPath: u.path) else {
                throw AIGameError.progressNotFound(id)
            }
            do {
                let data = try Data(contentsOf: u)
                return try decoder().decode(AIGameProgress.self, from: data)
            } catch {
                throw AIGameError.progressIOFailed(String(describing: error))
            }
        }
    }

    func delete(id: UUID) throws {
        try queue.sync {
            let u = url(for: id)
            if FileManager.default.fileExists(atPath: u.path) {
                do {
                    try FileManager.default.removeItem(at: u)
                } catch {
                    throw AIGameError.progressIOFailed(String(describing: error))
                }
            }
        }
    }
}
