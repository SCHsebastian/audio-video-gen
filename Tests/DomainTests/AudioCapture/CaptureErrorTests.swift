import XCTest
@testable import Domain

final class CaptureErrorTests: XCTestCase {
    func test_equality_for_typed_cases() {
        XCTAssertEqual(CaptureError.permissionDenied, CaptureError.permissionDenied)
        XCTAssertEqual(CaptureError.processNotFound(42), CaptureError.processNotFound(42))
        XCTAssertNotEqual(CaptureError.processNotFound(42), CaptureError.processNotFound(43))
        XCTAssertEqual(CaptureError.tapCreationFailed(-50), CaptureError.tapCreationFailed(-50))
    }
}
