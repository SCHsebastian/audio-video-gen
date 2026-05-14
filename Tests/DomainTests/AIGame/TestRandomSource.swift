// Tests/DomainTests/AIGame/TestRandomSource.swift
import XCTest
@testable import Domain

final class TestRandomSource: RandomSource {
    private var values: [Float]
    private var index = 0
    init(_ values: [Float]) { self.values = values }
    func nextUnit() -> Float {
        defer { index = (index + 1) % values.count }
        return values[index]
    }
    func nextSigned() -> Float { nextUnit() * 2 - 1 }
    func nextGaussian() -> Float { nextSigned() }   // ±1 stand-in
}

final class TestRandomSourceTests: XCTestCase {
    func test_cycles_through_provided_values() {
        let r = TestRandomSource([0.1, 0.2, 0.3])
        XCTAssertEqual(r.nextUnit(), 0.1)
        XCTAssertEqual(r.nextUnit(), 0.2)
        XCTAssertEqual(r.nextUnit(), 0.3)
        XCTAssertEqual(r.nextUnit(), 0.1) // wraps
    }
}
