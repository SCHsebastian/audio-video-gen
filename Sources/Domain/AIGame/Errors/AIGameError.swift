import Foundation

public enum AIGameError: Error, Equatable, Sendable {
    case invalidGenomeLength(expected: Int, got: Int)
    case progressNotFound(UUID)
    case progressIOFailed(String)
    case progressGenomeLengthMismatch(expected: Int, got: Int)
}
