import XCTest
import Metal
@testable import AudioVisualizer
import Domain

final class AIGameOfflineSeedTests: XCTestCase {
    func test_aigame_export_with_progress_seeds_population() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available")
        }
        guard let queue = device.makeCommandQueue() else {
            throw XCTSkip("Cannot create command queue")
        }
        guard let library = device.makeDefaultLibrary() else {
            throw XCTSkip("No default Metal library available")
        }
        let renderer = MetalVisualizationRenderer.makeOfflineRenderer(
            device: device, queue: queue, library: library)

        let g = Genome(weights: (0..<Genome.expectedLength).map { _ in Float.random(in: -1...1) })
        let progress = AIGameProgress(
            id: UUID(), label: "L", createdAt: Date(),
            generation: 9, bestFitness: 50,
            genomes: Array(repeating: g, count: 6),
            worldSeed: 12345, genomeLength: Genome.expectedLength)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seed-test-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        try renderer.begin(output: url,
                           options: RenderOptions.make(.hd720, .fps30),
                           scene: .aigame,
                           palette: PaletteFactory.xpNeon,
                           aiGameProgress: progress)

        XCTAssertEqual(renderer.peekAIGameSeedProgress()?.generation, 9)

        await renderer.cancel()
    }
}
