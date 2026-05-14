import Foundation
import Domain

public struct DeleteAIGameProgressUseCase: Sendable {
    private let store: AIGameProgressStoring
    public init(store: AIGameProgressStoring) { self.store = store }
    public func execute(id: UUID) throws { try store.delete(id: id) }
}
