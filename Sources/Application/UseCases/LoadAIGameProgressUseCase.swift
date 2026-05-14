import Foundation
import Domain

public struct LoadAIGameProgressUseCase: Sendable {
    private let store: AIGameProgressStoring
    public init(store: AIGameProgressStoring) { self.store = store }
    public func execute(id: UUID) throws -> AIGameProgress { try store.load(id: id) }
}
