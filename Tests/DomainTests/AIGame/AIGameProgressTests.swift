import XCTest
@testable import Domain

final class AIGameProgressTests: XCTestCase {
    func test_codable_round_trip_preserves_all_fields() throws {
        let g = Genome(weights: (0..<Genome.expectedLength).map { Float($0) * 0.01 })
        let p = AIGameProgress(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            label: "snap A", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            generation: 7, bestFitness: 42.5, genomes: [g, g, g, g, g, g],
            worldSeed: 0xDEAD_BEEF, genomeLength: Genome.expectedLength
        )
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let data = try enc.encode(p)
        let back = try dec.decode(AIGameProgress.self, from: data)
        XCTAssertEqual(back, p)
    }
}
