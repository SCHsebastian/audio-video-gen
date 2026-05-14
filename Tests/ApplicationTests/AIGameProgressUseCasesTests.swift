import XCTest
@testable import Application
@testable import Domain

private final class StubStore: AIGameProgressStoring, @unchecked Sendable {
    var saved: [AIGameProgress] = []
    var deletedIDs: [UUID] = []
    func list() throws -> [AIGameProgress] { saved }
    func save(_ p: AIGameProgress) throws -> AIGameProgress { saved.append(p); return p }
    func load(id: UUID) throws -> AIGameProgress {
        guard let p = saved.first(where: { $0.id == id })
        else { throw AIGameError.progressNotFound(id) }
        return p
    }
    func delete(id: UUID) throws { deletedIDs.append(id); saved.removeAll { $0.id == id } }
}

final class AIGameProgressUseCasesTests: XCTestCase {
    private func sample(label: String = "x") -> AIGameProgress {
        AIGameProgress(id: UUID(), label: label, createdAt: Date(),
                       generation: 1, bestFitness: 0,
                       genomes: [Genome(weights: Array(repeating: 0,
                                  count: Genome.expectedLength))],
                       worldSeed: 1, genomeLength: Genome.expectedLength)
    }

    func test_save_persists_via_store() throws {
        let store = StubStore()
        let uc = SaveAIGameProgressUseCase(store: store)
        let s = try uc.execute(progress: sample(label: "Alpha"))
        XCTAssertEqual(s.label, "Alpha")
        XCTAssertEqual(store.saved.count, 1)
    }

    func test_list_returns_store_contents() throws {
        let store = StubStore()
        store.saved = [sample(label: "a"), sample(label: "b")]
        let uc = ListAIGameProgressUseCase(store: store)
        XCTAssertEqual(try uc.execute().map(\.label), ["a", "b"])
    }

    func test_load_returns_record() throws {
        let store = StubStore()
        let s = try store.save(sample(label: "z"))
        let uc = LoadAIGameProgressUseCase(store: store)
        XCTAssertEqual(try uc.execute(id: s.id).label, "z")
    }

    func test_load_throws_when_missing() {
        let store = StubStore()
        let uc = LoadAIGameProgressUseCase(store: store)
        XCTAssertThrowsError(try uc.execute(id: UUID()))
    }

    func test_delete_removes_record() throws {
        let store = StubStore()
        let s = try store.save(sample())
        let uc = DeleteAIGameProgressUseCase(store: store)
        try uc.execute(id: s.id)
        XCTAssertEqual(store.saved.count, 0)
    }
}
