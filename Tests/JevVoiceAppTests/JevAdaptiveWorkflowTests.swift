import Foundation
import CryptoKit
import CoreGraphics
import XCTest
import JevVoiceCore
@testable import JevVoice

final class JevAdaptiveWorkflowTests: XCTestCase {
    enum Failure: Error { case unexpectedMutation, pixelsNotPermitted }

    final class Source: CaptureSource, @unchecked Sendable {
        let search: Bool
        var stage = 0
        var effects: [ActuationRequest] = []

        init(search: Bool) { self.search = search }

        var task: TaskBrief {
            TaskBrief(goal: search
                ? "Enter the supplied query in Search, then press Go"
                : "Continue to the next page, then finish setup",
                window: JevVoice.WindowRef(pid: 7, windowID: 42),
                values: search ? ["Search": "sample query"] : [:],
                successContains: [search ? "Search results loaded" : "Setup completed"])
        }

        func frontmostWindow() async throws -> JevVoice.WindowRef {
            JevVoice.WindowRef(pid: 7, windowID: 42)
        }

        func axTree(of window: JevVoice.WindowRef, depth: AXDepth) async throws -> AXSnapshot {
            let e = JevAdaptiveFixture.element
            let elements: [AXElement]
            if stage == 2 {
                elements = [e(9, search ? "Search results loaded" : "Setup completed", "AXStaticText", nil)]
            } else if search {
                elements = [e(1, "Search", "AXTextField", stage == 0 ? "" : "sample query"),
                            e(2, "Go", "AXButton", nil)]
            } else {
                elements = stage == 0
                    ? [e(1, "Next", "AXButton", nil), e(3, "Cancel", "AXButton", nil)]
                    : [e(2, "Finish", "AXButton", nil),
                       e(4, "Final setup page", "AXStaticText", nil)]
            }
            return AXSnapshot(windowTitle: "Synthetic workflow", snapshotID: "workflow-\(stage)",
                              elements: elements, treeMarkdown: "")
        }

        func screenshot(of window: JevVoice.WindowRef?, region: CGRect?) async throws -> CapturedImage {
            throw Failure.pixelsNotPermitted
        }

        func domSnapshot(of window: JevVoice.WindowRef) async throws -> DOMSnapshot {
            DOMSnapshot(url: "", title: "", indexedText: "", elements: [])
        }

        func settled(within timeout: Duration) async -> Bool { true }

        func act(_ request: ActuationRequest) throws -> TaskLoop.ActOutcome {
            guard stage < 2,
                  request.args["element_token"]?.string == "adaptive-\(stage + 1)",
                  request.args["pid"] == .number(7), request.args["window_id"] == .number(42),
                  request.tool == (search && stage == 0 ? "type_text" : "click") else {
                throw Failure.unexpectedMutation
            }
            if search && stage == 0 {
                guard request.args["text"]?.string == "sample query" else {
                    throw Failure.unexpectedMutation
                }
            }
            effects.append(request)
            stage += 1
            return TaskLoop.ActOutcome(effect: "confirmed", verified: true)
        }
    }

    func testActualLoopCompletesTwoStepWorkflowWithinFourRounds() async throws {
        for search in [false, true] {
            let source = Source(search: search)
            let decider = JevDecider(choose: { _, _ in
                DriveLoop.JevChoice(id: search && source.stage == 0 ? "t1" : "e\(source.stage + 1)",
                                    confidence: 1, doneVote: false)
            })
            let loop = TaskLoop(source: source, decider: decider,
                               actuate: source.act, consent: { _, _ in .allow })
            let result = await loop.run(source.task)
            guard case .done = result.outcome else {
                return XCTFail("expected verified workflow completion: \(result.outcome)")
            }
            XCTAssertEqual(source.effects.count, 2)
            XCTAssertLessThanOrEqual(result.roundsUsed, 4)
            XCTAssertEqual(result.verifiedEffects, 2)
        }
    }

    func testSecondStepConsentDenialCannotFinishWorkflow() async throws {
        let source = Source(search: false)
        let decider = JevDecider(choose: { _, _ in
            DriveLoop.JevChoice(id: "e\(source.stage + 1)", confidence: 1, doneVote: false)
        })
        let loop = TaskLoop(source: source, decider: decider, actuate: source.act,
                           consent: { _, _ in
            source.stage == 0 ? .allow : .deny(.safety("fixture consent denied"))
        })
        let result = await loop.run(source.task)
        if case .done = result.outcome { XCTFail("consent denial cannot finish setup") }
        XCTAssertEqual(source.effects.count, 1)
        XCTAssertEqual(source.stage, 1)
    }
}
