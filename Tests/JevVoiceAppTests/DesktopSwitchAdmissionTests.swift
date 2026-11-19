import XCTest
@testable import JevVoice

final class DesktopSwitchAdmissionTests: XCTestCase {
    func testSwitchStatusQuestionCannotRequestRemoteReasoning() {
        let proposal = VoiceAdmissionPolicy.propose("Did it switch?", context: VoiceAdmissionContext(), speech: true)
        XCTAssertEqual(proposal.route, .local)
        XCTAssertNil(DesktopSpaceTarget(command: "Did it switch?"))
    }
}
