import XCTest
@testable import AudioVisualizer
import Domain

final class FileSystemAIGameProgressStoreTests: XCTestCase {
    private var tempRoot: URL!
    private var store: FileSystemAIGameProgressStore!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("aigame-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = FileSystemAIGameProgressStore(rootDirectory: tempRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func sample(label: String = "x") -> AIGameProgress {
        AIGameProgress(
            id: UUID(), label: label, createdAt: Date(),
            generation: 1, bestFitness: 0,
            genomes: [Genome(weights: Array(repeating: 0, count: Genome.expectedLength))],
            worldSeed: 1, genomeLength: Genome.expectedLength
        )
    }

    func test_save_then_list_returns_one() throws {
        _ = try store.save(sample(label: "first"))
        let all = try store.list()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.label, "first")
    }

    func test_load_returns_saved_record() throws {
        let saved = try store.save(sample(label: "L"))
        let back = try store.load(id: saved.id)
        XCTAssertEqual(back, saved)
    }

    func test_delete_removes_file() throws {
        let saved = try store.save(sample())
        try store.delete(id: saved.id)
        XCTAssertEqual(try store.list().count, 0)
        XCTAssertThrowsError(try store.load(id: saved.id))
    }

    func test_corrupted_file_is_skipped_in_list() throws {
        _ = try store.save(sample(label: "good"))
        let bogus = tempRoot.appendingPathComponent("\(UUID()).json")
        try "{ not valid json".write(to: bogus, atomically: true, encoding: .utf8)
        let all = try store.list()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.label, "good")
    }

    func test_load_throws_progressNotFound_when_missing() {
        XCTAssertThrowsError(try store.load(id: UUID())) { err in
            guard case AIGameError.progressNotFound = err else {
                return XCTFail("wrong error: \(err)")
            }
        }
    }
}
