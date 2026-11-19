import Foundation
import XCTest
import JarvisCore
@testable import Jarvis

final class JevEditableValueTests: XCTestCase {
    private let window = Jarvis.WindowRef(pid: 7, windowID: 42)
    private let frame = CGRect(x: 10, y: 20, width: 200, height: 22)

    private func row(_ index: Int = 1, label: String = "Email", value: String = "Email",
                     role: String = "AXTextField", bounds: CGRect? = nil) -> AXElement {
        AXElement(index: index, token: "sdk-\(index)", role: role, label: label,
                  value: value, frame: bounds, actions: ["AXPress"])
    }

    private func field(_ value: String?, label: String = "Email",
                       role: String = "AXTextField", bounds: CGRect? = nil)
        -> NativeWindowObservation.FieldValue {
        .init(role: role, label: label, value: value, frame: bounds)
    }

    private func capture(_ rows: [AXElement], fields: [NativeWindowObservation.FieldValue],
                         complete: Bool = true, nativeWindow: Jarvis.WindowRef? = nil,
                         rooted: Bool = true) async throws -> AXSnapshot {
        var serialized: [JSONValue] = rooted ? [.object([
            "element_index": .number(0), "role": .string("AXWindow"),
            "label": .string("Synthetic"), "depth": .number(0),
        ])] : []
        serialized += rows.map { row in
            var data: [String: JSONValue] = [
                "element_index": .number(Double(row.index)),
                "element_token": .string(row.token!),
                "role": .string(row.role), "label": .string(row.label),
                "value": .string(row.value!), "depth": .number(1),
                "actions": .array(row.actions.map(JSONValue.string)),
            ]
            if rooted { data["parent_index"] = .number(0) }
            if let f = row.frame {
                data["frame"] = .object([
                    "x": .number(f.minX), "y": .number(f.minY),
                    "w": .number(f.width), "h": .number(f.height),
                ])
            }
            return .object(data)
        }
        let raw: JSONValue = .object(["structuredContent": .object([
            "pid": .number(7), "window_id": .number(42),
            "snapshot_id": .string("sdk-capture"), "window_title": .string("Synthetic"),
            "tree_markdown": .string("AXTextField Email value Email"),
            "elements": .array(serialized),
        ])])
        let display = NativeWindowObservation.Display(
            elements: [], complete: complete, window: nativeWindow ?? window, fieldValues: fields)
        return try await DriveLoop.DriveCaptureSource(
            observe: { _, _ in raw }, window: window, session: "synthetic",
            nativeRead: { _, _ in display }).axTree(of: window, depth: .standard)
    }

    private func literalMatch(_ snapshot: AXSnapshot, literal: String) -> JSONValue? {
        let elements = snapshot.elements.map(DriveCandidates.axToDrive)
        let drafts = DriveCandidates.drafts(elements: elements, snapshotID: snapshot.snapshotID,
            windowTitle: snapshot.windowTitle, goal: "Enter supplied text", cap: nil, url: nil)
        return DriveCandidates.observationFields(elements: elements, candidates: drafts,
            goal: "Enter supplied text", values: ["Email": literal]
        )["_candidate_details"]?["t1"]?["literal_matches_current_value"]
    }

    func testEmptyActualValueReplacesPlaceholderAndDoesNotSatisfyLiteral() async throws {
        let snapshot = try await capture([row(bounds: frame)], fields: [field("", bounds: frame)])
        XCTAssertEqual(snapshot.elements.first { $0.index == 1 }?.value, "")
        XCTAssertEqual(literalMatch(snapshot, literal: "Email"), .bool(false))
        XCTAssertTrue(snapshot.goalContextComplete)
        let facts = ObservedGoalProof.facts(in: snapshot)
        XCTAssertEqual(facts.map(\.content), [""])
        XCTAssertTrue(facts.allSatisfy { $0.kind == .value })
        XCTAssertFalse(TaskLoop.successEvidence(in: snapshot, task: TaskBrief(
            goal: "Enter Email in Email", successContains: ["Email"])))
    }

    func testOnlyActualEnteredValueCanSatisfyLiteral() async throws {
        let snapshot = try await capture([row(bounds: frame)],
                                        fields: [field("aster@example.test", bounds: frame)])
        XCTAssertEqual(snapshot.elements.first { $0.index == 1 }?.value, "aster@example.test")
        XCTAssertEqual(literalMatch(snapshot, literal: "aster@example.test"), .bool(true))
    }

    func testFailedValueReadIsUnknownNotEmptyOrPlaceholder() async throws {
        let snapshot = try await capture([row(bounds: frame)], fields: [field(nil, bounds: frame)])
        XCTAssertNil(snapshot.elements.first { $0.index == 1 }?.value)
        XCTAssertNotEqual(literalMatch(snapshot, literal: "Email"), .bool(true))
        XCTAssertFalse(snapshot.goalContextComplete)
    }

    func testSecureValueNeverPropagates() async throws {
        for role in ["AXTextField", "AXSecureTextField"] {
            let snapshot = try await capture([row(label: "Password", value: "private-sentinel", role: role)],
                fields: [field("private-sentinel", label: "Password", role: role)])
            XCTAssertNil(snapshot.elements.first { $0.index == 1 }?.value)
            XCTAssertTrue(ObservedGoalProof.facts(in: snapshot).isEmpty)
        }
    }

    func testDuplicateLabelsWithoutBoundsAreUnknown() async throws {
        let snapshot = try await capture([row(1), row(2)],
                                        fields: [field("A"), field("B")])
        XCTAssertTrue(snapshot.elements.filter { $0.index > 0 }.allSatisfy { $0.value == nil })
        XCTAssertFalse(snapshot.goalContextComplete)
    }

    func testOneNativeRowCannotCorrectTwoSDKRows() async throws {
        let snapshot = try await capture([row(1, bounds: frame), row(2, bounds: frame)],
                                        fields: [field("A", bounds: frame)])
        XCTAssertTrue(snapshot.elements.filter { $0.index > 0 }.allSatisfy { $0.value == nil })
        XCTAssertFalse(snapshot.goalContextComplete)
    }

    func testExactFramesDisambiguateDuplicateLabels() async throws {
        let other = frame.offsetBy(dx: 300, dy: 0)
        let snapshot = try await capture([row(1, bounds: frame), row(2, bounds: other)],
            fields: [field("A", bounds: frame), field("B", bounds: other)])
        XCTAssertEqual(snapshot.elements.first { $0.index == 1 }?.value, "A")
        XCTAssertEqual(snapshot.elements.first { $0.index == 2 }?.value, "B")
        XCTAssertTrue(snapshot.goalContextComplete)
    }

    func testFrameMismatchIsNotNearestMatched() async throws {
        let snapshot = try await capture([row(bounds: frame)],
                                        fields: [field("A", bounds: frame.offsetBy(dx: 3, dy: 0))])
        XCTAssertNil(snapshot.elements.first { $0.index == 1 }?.value)
        XCTAssertFalse(snapshot.goalContextComplete)
    }

    func testUniqueRoleAndLabelAllowMissingBoundsOnEitherSide() async throws {
        for missingSDK in [true, false] {
            let snapshot = try await capture([row(bounds: missingSDK ? nil : frame)],
                fields: [field("A", bounds: missingSDK ? frame : nil)])
            XCTAssertEqual(snapshot.elements.first { $0.index == 1 }?.value, "A")
        }
    }

    func testRoleMismatchDoesNotRewriteStaticText() async throws {
        let snapshot = try await capture([row(role: "AXStaticText", bounds: frame)],
                                        fields: [field("A", bounds: frame)])
        XCTAssertEqual(snapshot.elements.first { $0.index == 1 }?.value, "Email")
        XCTAssertFalse(snapshot.goalContextComplete)
    }

    func testEmptyLabelsRequireUniqueExactFrames() async throws {
        let unknown = try await capture([row(label: "")], fields: [field("A", label: "")])
        XCTAssertNil(unknown.elements.first { $0.index == 1 }?.value)
        let known = try await capture([row(label: "", bounds: frame)],
                                     fields: [field("A", label: "", bounds: frame)])
        XCTAssertEqual(known.elements.first { $0.index == 1 }?.value, "A")
    }

    func testCorrectionIsNotSpecificToEmailPlaceholder() async throws {
        for label in ["Name", "Search", "Untitled"] {
            let snapshot = try await capture([row(label: label, value: label, bounds: frame)],
                                            fields: [field("", label: label, bounds: frame)])
            XCTAssertEqual(snapshot.elements.first { $0.index == 1 }?.value, "")
        }
    }

    func testOriginalSDKActionAuthorityIsPreserved() async throws {
        let original = row(bounds: frame)
        let snapshot = try await capture([original], fields: [field("", bounds: frame)])
        let corrected = try XCTUnwrap(snapshot.elements.first { $0.index == 1 })
        XCTAssertEqual(corrected.index, original.index)
        XCTAssertEqual(corrected.token, original.token)
        XCTAssertEqual(corrected.role, original.role)
        XCTAssertEqual(corrected.label, original.label)
        XCTAssertEqual(corrected.frame, original.frame)
        XCTAssertEqual(corrected.actions, original.actions)
        XCTAssertEqual(snapshot.snapshotID, "sdk-capture")
        let drafts = DriveCandidates.drafts(elements: snapshot.elements.map(DriveCandidates.axToDrive),
            snapshotID: snapshot.snapshotID, windowTitle: snapshot.windowTitle,
            goal: "Enter supplied text", cap: nil, url: nil)
        guard case .request(let request) = drafts.first(where: { $0.id == "t1" })?.kind else {
            return XCTFail("missing SDK typing candidate")
        }
        XCTAssertEqual(request.args["element_token"], .string("sdk-1"))
        XCTAssertEqual(snapshot.elements.filter { $0.index > 0 }.count, 1)
    }

    func testWrongWindowAndPartialReadsCannotCorrectValues() async throws {
        for wrongWindow in [true, false] {
            let snapshot = try await capture([row(bounds: frame)], fields: [field("A", bounds: frame)],
                complete: wrongWindow, nativeWindow: wrongWindow
                    ? Jarvis.WindowRef(pid: 7, windowID: 99) : window)
            XCTAssertNil(snapshot.elements.first { $0.index == 1 }?.value)
            XCTAssertFalse(snapshot.goalContextComplete)
        }
    }

    func testFingerprintDetectsActualEmptyToPlaceholderLiteralTransition() async throws {
        let empty = try await capture([row(bounds: frame)], fields: [field("", bounds: frame)])
        let entered = try await capture([row(bounds: frame)], fields: [field("Email", bounds: frame)])
        XCTAssertNotEqual(TaskLoop.fingerprint(of: empty), TaskLoop.fingerprint(of: entered))
    }

    func testSDKMarkdownCannotRestorePlaceholderAsActualEvidence() async throws {
        let snapshot = try await capture([row(bounds: frame)], fields: [field("", bounds: frame)],
                                        rooted: false)
        XCTAssertFalse(snapshot.treeMarkdown.contains("Email value Email"))
        XCTAssertFalse(TaskLoop.successEvidence(in: snapshot, task: TaskBrief(
            goal: "Enter Email in Email", successContains: ["Email"])))
    }
}
