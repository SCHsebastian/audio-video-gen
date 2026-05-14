import Foundation

public enum AIGameEvent: String, Equatable, Sendable, CaseIterable {
    case catastrophicMutation
    case cull
    case jumpBoost
    case earthquake
    case bonusObstacleWave
    case lineageSwap
}
