import Foundation

public enum ObstacleKind: Equatable, Sendable {
    case spike     // jump over
    case ceiling   // duck under
    case pit       // gap in the ground
}
