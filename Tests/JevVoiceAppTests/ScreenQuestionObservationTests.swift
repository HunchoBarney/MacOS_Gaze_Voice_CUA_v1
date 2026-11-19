import ApplicationServices
import XCTest
@testable import JevVoice

final class ScreenQuestionObservationTests: XCTestCase {
    typealias Reader = ScreenQuestionObservation
    private let scope = Reader.Window(bundleID: "example.fixture", pid: 7, windowID: 41)
    private let question = "What does the Minimize button in this window do?"

    func testInquiryBoundaryDoesNotCaptureUnrelatedLookupOrAuthorizeAnUnboundPoint() {
        let appRequest = "I would like Calculator on my screen."
        var fixture = VoiceAdmissionContext()
        XCTAssertTrue(Reader.isScreenInquiry(appRequest, context: fixture))
        fixture.entities = [.init(name: "Calculator", id: " ", canOpenLocally: true)]
        XCTAssertTrue(Reader.isScreenInquiry(appRequest, context: fixture))
        fixture.entities = [.init(name: "Calculator", id: "fixture.calc", canOpenLocally: true)]
        XCTAssertFalse(Reader.isScreenInquiry(appRequest, context: fixture))
        for text in ["What is a button?", "What is screen printing?", "Search the web for how screen printing works"] {
            XCTAssertFalse(Reader.isScreenInquiry(text), text)
            XCTAssertNotEqual(VoiceAdmissionPolicy.propose(text, context: .init(), speech: true).intent, "screen_question")
        }
        for text in ["Click that button", "Open what I am pointing at", "Click it"] {
            let result = VoiceAdmissionPolicy.propose(text, context: .init(), speech: true)
            XCTAssertEqual(result.route, .clarify); XCTAssertEqual(result.reason, "unbound_pointing")
        }
    }

    func testWholeFinalOnlyAdmitsNamedCurrentWindowQuestions() {
        XCTAssertEqual(Reader.requestedControl(in: question), .minimize)
        XCTAssertEqual(Reader.requestedControl(in: "What does the Close button in the current window do?"), .close)
        for text in ["What does this button do?", "What does that button do?", "What's on my screen?",
                     "What is a button?", "What does Close do?", "Click the Minimize button",
                     "Do not " + question, "Type: " + question, "“" + question + "”",
                     question + " Then click it.", "What does the Zoom button in this window do?",
                     "What does the Close button in my other window do?"] {
            XCTAssertNil(Reader.requestedControl(in: text), text)
        }
    }

    private final class Graph: ScreenQuestionAXSource {
        var appAllowed = true
        var window: UInt32 = 41
        var modal = false
        var focused = 1
        var focusRole = "AXGroup"
        var classOfWindow = "AXStandardWindow"
        var buttonOwner: pid_t = 7
        var buttonWindow = 1
        var buttonTopLevel: Int? = 1
        var buttonKind = "AXMinimizeButton"
        var enabled = true
        var calls: [String] = []
        var focusChangedDuringRead = false

        func activeApplication(_ scope: Reader.Window) -> Int? {
            appAllowed && scope.bundleID == "example.fixture" && scope.pid == 7 ? 0 : nil
        }

        func node(_ parent: Int, _ attribute: String) -> Int? {
            calls.append(attribute)
            switch (parent, attribute) {
            case (0, kAXFocusedWindowAttribute): return 1
            case (0, kAXFocusedUIElementAttribute):
                return focusChangedDuringRead && calls.contains(kAXMinimizeButtonAttribute) ? 4 : focused
            case (1, kAXMinimizeButtonAttribute): return 2
            case (1, kAXCloseButtonAttribute): return 6
            case (2, kAXWindowAttribute): return buttonWindow
            case (6, kAXWindowAttribute): return 1
            case (2, kAXTopLevelUIElementAttribute), (6, kAXTopLevelUIElementAttribute): return buttonTopLevel
            case (3, kAXParentAttribute): return 1
            default: return nil
            }
        }

        func name(_ node: Int, _ attribute: String) -> String? {
            calls.append(attribute)
            switch (node, attribute) {
            case (1, kAXRoleAttribute): return kAXWindowRole
            case (1, kAXSubroleAttribute): return classOfWindow
            case (2, kAXRoleAttribute): return kAXButtonRole
            case (2, kAXSubroleAttribute): return buttonKind
            case (6, kAXRoleAttribute): return kAXButtonRole
            case (6, kAXSubroleAttribute): return kAXCloseButtonSubrole
            case (3, kAXRoleAttribute): return focusRole
            default: return nil
            }
        }

        func flag(_ node: Int, _ attribute: String) -> Bool? {
            calls.append(attribute)
            switch (node, attribute) {
            case (1, kAXModalAttribute): return modal
            case (1, kAXMinimizedAttribute): return false
            case (2, kAXEnabledAttribute), (6, kAXEnabledAttribute): return enabled
            default: return nil
            }
        }

        func owned(_ node: Int, by pid: pid_t) -> Bool { (node == 2 ? buttonOwner : 7) == pid }
        func windowNumber(_ node: Int) -> UInt32? { node == 1 ? window : nil }
    }

    func testObservationReadsOnlyNamedControlMetadataFromCurrentWindow() {
        let graph = Graph()
        graph.focused = 3
        XCTAssertEqual(graph.target(in: scope, control: .minimize), .init(window: 1, button: 2, focus: 3))
        let permitted = Set([kAXFocusedWindowAttribute, kAXFocusedUIElementAttribute,
                             kAXRoleAttribute, kAXSubroleAttribute, kAXMinimizedAttribute, kAXModalAttribute,
                             kAXParentAttribute, kAXMinimizeButtonAttribute, kAXWindowAttribute,
                             kAXTopLevelUIElementAttribute, kAXEnabledAttribute])
        XCTAssertTrue(Set(graph.calls).isSubset(of: permitted))
        XCTAssertEqual(graph.calls.filter { $0 == kAXMinimizeButtonAttribute }.count, 1)
        graph.calls = []
        XCTAssertEqual(graph.target(in: scope, control: .close), .init(window: 1, button: 6, focus: 3))
        XCTAssertFalse(graph.calls.contains(kAXMinimizeButtonAttribute))
    }

    func testDeniedProtectedUnknownAndStaleContextsStopBeforeButtonRead() {
        let cases: [(Graph) -> Void] = [
            { $0.appAllowed = false }, { $0.window = 42 }, { $0.modal = true },
            { $0.classOfWindow = "AXDialog" }, { $0.focused = 4 },
            { $0.focused = 3; $0.focusRole = "AXSecureTextField" },
            { $0.focused = 3; $0.focusRole = "AXTextField" },
            { $0.focused = 3; $0.focusRole = "AXSheet" },
        ]
        for change in cases {
            let graph = Graph()
            change(graph)
            XCTAssertNil(graph.target(in: scope, control: .minimize))
            XCTAssertFalse(graph.calls.contains(kAXMinimizeButtonAttribute))
        }
    }

    func testWrongOwnerWrongKindDisabledAndChangedFocusReject() {
        for change: (Graph) -> Void in [
            { $0.buttonOwner = 8 }, { $0.buttonWindow = 88 }, { $0.buttonKind = "AXCloseButton" },
            { $0.buttonTopLevel = 99 }, { $0.buttonTopLevel = nil },
            { $0.enabled = false }, { $0.focusChangedDuringRead = true },
        ] {
            let graph = Graph()
            change(graph)
            XCTAssertNil(graph.target(in: scope, control: .minimize))
        }
    }

    private actor Reads {
        var targets: [Reader.Target<Int>?]
        private(set) var calls = 0
        init(_ targets: [Reader.Target<Int>?]) { self.targets = targets }
        func read(_ window: Reader.Window, _ control: Reader.Control) -> Reader.Target<Int>? {
            calls += 1
            guard window.windowID == 41, control == .minimize, !targets.isEmpty else { return nil }
            return targets.removeFirst()
        }
    }

    @MainActor
    func testUnknownFinalNeverReadsAndKnownTargetMustStillBeCurrent() async {
        let first = Reader.Target(window: 1, button: 2, focus: 3)
        for altered: Reader.Target<Int>? in [.init(window: 4, button: 2, focus: 3),
                                              .init(window: 1, button: 7, focus: 3),
                                              .init(window: 1, button: 2, focus: 5), nil] {
            let reads = Reads([first, first, altered])
            for unknown in ["What does this button do?", "What's on my screen?"] {
                let noBinding = await Reader.bind(final: unknown, window: scope, isCurrent: { true },
                                                  clock: { 0 }, read: { await reads.read($0, $1) })
                XCTAssertNil(noBinding)
            }
            let before = await reads.calls
            XCTAssertEqual(before, 0)
            let bound = await Reader.bind(final: question, window: scope, isCurrent: { true },
                                          clock: { 0 }, read: { await reads.read($0, $1) })
            let verified = await bound?.verifiedControl()
            XCTAssertEqual(verified?.rawValue, "Minimize")
            let changed = await bound?.verifiedControl()
            XCTAssertNil(changed)
            let retired = await bound?.verifiedControl()
            XCTAssertNil(retired)
            let total = await reads.calls
            XCTAssertEqual(total, 3)
        }
    }

    @MainActor
    func testExpiredAndSupersededTurnsCannotReleaseAnObservation() async {
        for expire in [false, true] {
            var clock = 10.0
            var current = true
            let reads = Reads([.init(window: 1, button: 2, focus: 3)])
            let bound = await Reader.bind(final: question, window: scope, isCurrent: { current },
                                          clock: { clock }, read: { await reads.read($0, $1) })
            XCTAssertNotNil(bound)
            if expire { clock = 18 } else { current = false }
            let result = await bound?.verifiedControl()
            XCTAssertNil(result)
            let count = await reads.calls
            XCTAssertEqual(count, 1)
        }
    }

    @MainActor
    private final class Turn {
        var current = true
        var calls = 0
        func read(revokeAt call: Int) -> Reader.Target<Int> {
            calls += 1
            if calls == call { current = false }
            return .init(window: 1, button: 2, focus: 3)
        }
    }

    @MainActor
    func testRevocationDuringEitherReadPreventsRelease() async {
        for revokeAt in [0, 1, 2] {
            let turn = Turn()
            if revokeAt == 0 { turn.current = false }
            let bound = await Reader.bind(final: question, window: scope, isCurrent: { turn.current },
                                          clock: { 0 }, read: { _, _ in await turn.read(revokeAt: revokeAt) })
            XCTAssertEqual(bound != nil, revokeAt == 2)
            let result = await bound?.verifiedControl()
            XCTAssertNil(result)
            XCTAssertEqual(turn.calls, revokeAt)
        }
    }
}
