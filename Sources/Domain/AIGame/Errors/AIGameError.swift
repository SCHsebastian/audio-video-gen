// Sources/Domain/AIGame/Errors/AIGameError.swift
import Foundation

public enum AIGameError: Error, Equatable, Sendable {
    case invalidGenomeLength(expected: Int, got: Int)
}
