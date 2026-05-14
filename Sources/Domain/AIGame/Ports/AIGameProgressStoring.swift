import Foundation

/// Persistence port for AI Game training snapshots. Adapters live in
/// Infrastructure (e.g. file-system JSON store).
public protocol AIGameProgressStoring: Sendable {
    func list() throws -> [AIGameProgress]
    /// Persists the snapshot. Implementations may rewrite `id` / `createdAt`
    /// if the caller passed sentinel values. Returns the persisted record.
    func save(_ progress: AIGameProgress) throws -> AIGameProgress
    func load(id: UUID) throws -> AIGameProgress
    func delete(id: UUID) throws
}
