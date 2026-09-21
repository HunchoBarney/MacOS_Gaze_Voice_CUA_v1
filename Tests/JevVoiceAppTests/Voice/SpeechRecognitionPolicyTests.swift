import XCTest
@testable import JevVoice

final class SpeechRecognitionPolicyTests: XCTestCase {
    @MainActor
    func testSupportedRecognitionRequiresLocalProcessing() async throws {
        let request = try SpeechRecognizer.makeRecognitionRequest(supportsOnDeviceRecognition: true)
        XCTAssertTrue(request.requiresOnDeviceRecognition)
        XCTAssertTrue(request.shouldReportPartialResults)
    }

    @MainActor
    func testUnsupportedRecognitionFailsWithoutCreatingRequest() async {
        XCTAssertThrowsError(try SpeechRecognizer.makeRecognitionRequest(supportsOnDeviceRecognition: false)) { error in
            XCTAssertTrue(error.localizedDescription.localizedCaseInsensitiveContains("on-device"))
        }
    }
}
