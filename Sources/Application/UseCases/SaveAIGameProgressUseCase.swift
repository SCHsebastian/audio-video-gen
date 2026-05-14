import Foundation
import Domain

public struct SaveAIGameProgressUseCase: Sendable {
    private let store: AIGameProgressStoring
    public init(store: AIGameProgressStoring) { self.store = store }
    public func execute(progress: AIGameProgress) throws -> AIGameProgress {
        try store.save(progress)
    }
}
