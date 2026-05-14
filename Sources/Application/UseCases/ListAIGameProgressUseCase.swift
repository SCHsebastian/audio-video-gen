import Foundation
import Domain

public struct ListAIGameProgressUseCase: Sendable {
    private let store: AIGameProgressStoring
    public init(store: AIGameProgressStoring) { self.store = store }
    public func execute() throws -> [AIGameProgress] { try store.list() }
}
