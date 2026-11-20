import ApplicationServices
import CoreGraphics
import Foundation
import XCTest
import JarvisCore
@testable import Jarvis

final class JevNativeObservationTests: XCTestCase {
    func testNativeReadDiagnosticsContainOnlyPhaseTimingAndStatus() {
        for (complete, status) in [(Optional<Bool>.none, "unavailable"),
                                   (false, "incomplete"), (true, "complete")] {
            let event = NativeWindowObservation.ReadDiagnostic(
                phase: .traversal, elapsedMs: 1.25, complete: complete, cancelled: false)
            XCTAssertEqual(event.message,
                "Native read phase=traversal totalMs=1.25 status=\(status) cancelled=false")
        }
        XCTAssertEqual(NativeWindowObservation.ReadDiagnostic(
            phase: .awaited, elapsedMs: 2.5, complete: nil, cancelled: true).message,
            "Native read phase=awaited totalMs=2.5 status=unavailable cancelled=true")
    }

    func testNativeReadStillRejectsInvalidScopeAndPrecancelledWork() async {
        for window in [
            Jarvis.WindowRef(pid: 0, windowID: 1),
            .init(pid: -1, windowID: 1), .init(pid: Int.max, windowID: 1),
            .init(pid: 1, windowID: 0), .init(pid: 1, windowID: -1),
            .init(pid: 1, windowID: Int.max),
        ] {
            let display = await NativeWindowObservation.read(window, depth: .standard)
            XCTAssertNil(display)
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await NativeWindowObservation.read(.init(pid: 0, windowID: 1), depth: .standard)
        }
        let display = await cancelled.value
        XCTAssertNil(display)
    }

    func testNativeAncestorRolesRequireFreshVerifiedUniqueFieldMapping() throws {
        let window = Jarvis.WindowRef(pid: 7, windowID: 42)
        let foreign = Jarvis.WindowRef(pid: 8, windowID: 43)
        let frame = CGRect(x: 10, y: 10, width: 200, height: 100)
        let roles = ["AXWindow", "AXScrollArea"]
        for shape in ["valid", "nil", "sdk-only", "incomplete", "foreign-window",
                      "foreign-field", "no-identity", "duplicate", "secure", "secure-parent",
                      "malformed", "missing-root", "menu"] {
            let role = shape == "secure" ? "AXSecureTextField" : "AXTextArea"
            let ancestry: [String]? = shape == "nil" ? nil
                : shape == "secure-parent" ? ["AXWindow", "AXSecureTextField"]
                : shape == "malformed" ? ["AXWindow", "AXGroup\nprivate-canary"]
                : shape == "missing-root" ? ["AXScrollArea"]
                : shape == "menu" ? ["AXWindow", "AXMenu"] : roles
            let element = AXElement(index: 3, token: nil, role: role, label: "Body",
                value: "SDK value", frame: frame, actions: ["AXSetValue"],
                nativeAncestorRoles: ["AXWindow", "AXToolbar"])
            let field = NativeWindowObservation.FieldValue(role: role, label: "Body",
                value: "native value", frame: frame,
                verifiedWindow: shape == "foreign-field" ? foreign : window,
                identity: shape == "no-identity" ? nil
                    : NativeFieldIdentity(AXUIElementCreateApplication(7)),
                nativeAncestorRoles: ancestry)
            let display = NativeWindowObservation.Display(elements: [], complete: shape != "incomplete",
                window: shape == "foreign-window" ? foreign : window,
                fieldValues: shape == "duplicate" ? [field, field] : [field])
            let snapshot = AXSnapshot(windowTitle: "Owned", snapshotID: "s1",
                elements: [element], treeMarkdown: "")
            let merged = NativeWindowObservation.applying(
                shape == "sdk-only" ? nil : display, to: snapshot, window: window)
            XCTAssertEqual(merged.elements[0].nativeAncestorRoles, shape == "valid" ? roles : nil, shape)
            let fact = ObservedGoalProof.facts(in: merged).first { $0.kind == .value }
            XCTAssertEqual(fact?.json["native_ancestor_roles"]?.array,
                           shape == "valid" ? roles.map(JSONValue.string) : nil, shape)
            if shape == "nil" {
                XCTAssertEqual(merged.elements[0].value, "native value")
                XCTAssertNotNil(merged.elements[0].nativeValue)
                XCTAssertTrue(merged.goalContextComplete)
            }
        }
    }

    func testReadOnlyAncestorRolesRequireCompleteBoundNativeRoot() {
        let window = Jarvis.WindowRef(pid: 7, windowID: 42)
        let roles = ["AXWindow", "AXGroup"]
        for shape in ["valid", "incomplete", "unscoped", "foreign", "malformed", "secure", "secure-node"] {
            let native = AXElement(index: -1, token: nil,
                role: shape == "secure-node" ? "AXSecureTextField" : "AXStaticText", label: "5",
                value: "5", frame: nil, actions: [],
                nativeAncestorRoles: shape == "malformed" ? ["AXGroup"]
                    : shape == "secure" ? ["AXWindow", "AXSecureTextField"] : roles)
            let sdk = AXElement(index: 1, token: nil, role: "AXStaticText", label: "SDK",
                value: nil, frame: nil, actions: [], nativeAncestorRoles: roles)
            let display = NativeWindowObservation.Display(elements: [native], complete: shape != "incomplete",
                window: shape == "unscoped" ? nil
                    : shape == "foreign" ? .init(pid: 8, windowID: 43) : window)
            let merged = NativeWindowObservation.applying(display, to: AXSnapshot(
                windowTitle: "Owned", snapshotID: "s1", elements: [sdk], treeMarkdown: ""), window: window)
            XCTAssertNil(merged.elements[0].nativeAncestorRoles, shape)
            XCTAssertEqual(merged.elements.first { $0.index == -1 }?.nativeAncestorRoles,
                           shape == "valid" ? roles : nil, shape)
        }
    }

    func testCapturePublishesNativeAncestryWithOneNativeObservationRead() async throws {
        actor Reads {
            var count = 0
            func read(_ window: Jarvis.WindowRef) -> NativeWindowObservation.Display {
                count += 1
                return .init(elements: [AXElement(index: -1, token: nil, role: "AXStaticText",
                    label: "5", value: "5", frame: nil, actions: [],
                    nativeAncestorRoles: ["AXWindow", "AXGroup"])], complete: true, window: window)
            }
        }
        let reads = Reads()
        let window = Jarvis.WindowRef(pid: 7, windowID: 42)
        let raw: JSONValue = .object(["structuredContent": .object([
            "pid": .number(7), "window_id": .number(42),
            "snapshot_id": .string("native-1"), "elements": .array([]),
        ])])
        let source = DriveLoop.DriveCaptureSource(observe: { _, _ in raw },
            window: window, session: "synthetic", nativeRead: { window, _ in await reads.read(window) })
        let snapshot = try await source.axTree(of: window, depth: .standard)
        let count = await reads.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(ObservedGoalProof.facts(in: snapshot).first?.json["native_ancestor_roles"]?.array,
                       [.string("AXWindow"), .string("AXGroup")])
    }

    func testNativeEntireFieldProvenanceRequiresVerifiedUniqueScope() throws {
        let window = Jarvis.WindowRef(pid: 7, windowID: 42)
        let document = try XCTUnwrap(NativeWindowObservation.documentSubject(
            window: window, identifier: "file:///tmp/native-private-document-canary.txt"))
        for shape in ["valid", "empty", "no-document", "sdk-only", "incomplete",
                      "unscoped", "foreign-window", "foreign-field", "foreign-document",
                      "unknown-owner", "duplicate", "label-only", "secure"] {
            let frame = shape == "label-only" ? nil : CGRect(x: 10, y: 10, width: 200, height: 100)
            let role = shape == "secure" ? "AXSecureTextField" : "AXTextArea"
            let value = shape == "empty" ? "" : "owned value\n"
            let foreign = Jarvis.WindowRef(pid: 8, windowID: 43)
            let element = AXElement(index: 3, token: "native-token", role: role, label: "Body",
                                    value: "SDK display", frame: frame, actions: ["AXSetValue"])
            let snapshot = AXSnapshot(windowTitle: "Owned", snapshotID: "s1",
                                      elements: [element], treeMarkdown: "")
            let field = NativeWindowObservation.FieldValue(
                role: role, label: "Body", value: value, frame: frame,
                verifiedWindow: shape == "unknown-owner" ? nil : shape == "foreign-field" ? foreign : window)
            let nativeDocument = shape == "foreign-document"
                ? NativeDocumentSubject(window: foreign, fingerprint: document.fingerprint) : document
            let display = NativeWindowObservation.Display(
                elements: [], complete: shape != "incomplete",
                window: shape == "unscoped" ? nil : shape == "foreign-window" ? foreign : window,
                fieldValues: shape == "duplicate" ? [field, field] : [field],
                nativeDocument: shape == "no-document" ? nil : nativeDocument)
            let result = NativeWindowObservation.applying(
                shape == "sdk-only" ? nil : display, to: snapshot, window: window)
            let fact = ObservedGoalProof.facts(in: result).first { $0.kind == .value }
            if ["valid", "empty", "no-document"].contains(shape) {
                XCTAssertEqual(result.elements[0].value, value, shape)
                XCTAssertEqual(fact?.json["native_value"]?["extent"]?.string, "entire_field", shape)
                XCTAssertEqual(fact?.json["native_value"]?["document_associated"]?.bool,
                               shape != "no-document", shape)
            } else {
                XCTAssertNil(result.elements[0].nativeValue, shape)
                XCTAssertNil(fact?.json["native_value"], shape)
            }
            let state = ObservedGoalProof.choiceState(snapshot: result,
                task: TaskBrief(goal: "Replace Body with supplied text", window: window),
                originalDocument: document)
            let serialized = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
            XCTAssertFalse(serialized.contains("native-private-document-canary"))
            XCTAssertFalse(serialized.contains(document.fingerprint.base64EncodedString()))
        }
    }

    func testIncomingNativeMetadataCannotSurviveWithoutNativeRead() throws {
        let window = Jarvis.WindowRef(pid: 7, windowID: 42)
        let document = try XCTUnwrap(NativeWindowObservation.documentSubject(
            window: window, identifier: "file:///tmp/document.txt"))
        let element = AXElement(index: 1, token: nil, role: "AXTextArea", label: "Body",
            value: "untrusted", frame: CGRect(x: 0, y: 0, width: 100, height: 100), actions: [],
            nativeValue: .init(window: window, document: document))
        let snapshot = AXSnapshot(windowTitle: "Owned", snapshotID: "s1",
            elements: [element], treeMarkdown: "", nativeDocument: document)
        let result = NativeWindowObservation.applying(nil, to: snapshot, window: window)
        XCTAssertNil(result.nativeDocument)
        XCTAssertNil(result.elements[0].nativeValue)
        XCTAssertNil(result.elements[0].value)
        XCTAssertFalse(result.goalContextComplete)
    }

    func testNativeDocumentIdentityIsOpaqueAndUnsupportedIsUnknown() throws {
        let window = Jarvis.WindowRef(pid: 7, windowID: 42)
        for identifier in [nil, "", " ", "not a URI"] {
            XCTAssertNil(NativeWindowObservation.documentSubject(window: window, identifier: identifier))
        }
        let a = try XCTUnwrap(NativeWindowObservation.documentSubject(
            window: window, identifier: "file:///tmp/private-document-A.txt"))
        let again = NativeWindowObservation.documentSubject(
            window: window, identifier: "file:///tmp/private-document-A.txt")
        let b = NativeWindowObservation.documentSubject(
            window: window, identifier: "file:///tmp/private-document-B.txt")
        XCTAssertEqual(a, again)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.fingerprint.count, 32)
        XCTAssertEqual(a.window, window)
    }

    private func element(_ index: Int, label: String, value: String? = nil,
                         role: String = "AXStaticText") -> DriveLoop.Element {
        DriveLoop.Element(index: index, token: nil, role: role, label: label,
                          value: value, frame: (0, 0, 100, 20), actions: [])
    }

    func testFingerprintSeesProgressAfterFirst160Rows() {
        let before = (0..<200).map { element($0, label: "Row \($0)", value: "0") }
        let after = (0..<200).map { element($0, label: "Row \($0)", value: $0 == 199 ? "1" : "0") }
        XCTAssertNotEqual(DriveLoop.fingerprint(of: before, title: "Synthetic"),
                          DriveLoop.fingerprint(of: after, title: "Synthetic"))
    }

    func testFingerprintPreservesTypedFieldBoundaries() {
        XCTAssertNotEqual(
            DriveLoop.fingerprint(of: [element(1, label: "foo", value: "bar")], title: "Synthetic"),
            DriveLoop.fingerprint(of: [element(1, label: "foob", value: "ar")], title: "Synthetic"))
    }

    func testDisplayOnlyLocalIDCannotBecomeEditableAction() {
        let display = element(-1, label: "Document", value: "Read-only contents", role: "AXTextArea")
        XCTAssertTrue(DriveCandidates.actionable([display], goal: "Enter supplied text", cap: nil).isEmpty)
    }

    func testWindowObservationExcludesSeparateMenuRootsAndText() throws {
        let raw: JSONValue = .object(["structuredContent": .object([
            "pid": .number(7), "window_id": .number(42),
            "snapshot_id": .string("native-1"), "window_title": .string("Synthetic"),
            "tree_markdown": .string("AXWindow Synthetic\nAXMenuItem PRIVATE_OS_METADATA_CANARY"),
            "elements": .array([
                .object(["element_index": .number(0), "role": .string("AXWindow"),
                         "label": .string("Synthetic"), "depth": .number(0)]),
                .object(["element_index": .number(1), "role": .string("AXButton"),
                         "label": .string("Continue"), "parent_index": .number(0),
                         "depth": .number(1), "actions": .array([.string("AXPress")])]),
                .object(["element_index": .number(5), "role": .string("AXMenuBar"),
                         "depth": .number(0)]),
                .object(["element_index": .number(6), "role": .string("AXMenuItem"),
                         "parent_index": .number(5), "depth": .number(1),
                         "label": .string("PRIVATE_OS_METADATA_CANARY")]),
            ]),
        ])])
        let snapshot = try DriveCandidates.axSnapshot(from: raw)
        XCTAssertTrue(snapshot.elements.contains { $0.label == "Continue" })
        XCTAssertFalse(snapshot.elements.contains { $0.label.contains("PRIVATE_OS_METADATA_CANARY") })
        XCTAssertFalse(snapshot.treeMarkdown.contains("PRIVATE_OS_METADATA_CANARY"))
        let fields = DriveCandidates.observationFields(
            elements: snapshot.elements.map(DriveCandidates.axToDrive),
            candidates: [], goal: "Continue", values: [:])
        XCTAssertFalse(fields["observed_content"]?.string?.contains("PRIVATE_OS_METADATA_CANARY") ?? false)
    }

    func testPublicReadOnlyStatusWithSecureWordIsStillLocalEvidence() {
        let status = DriveCandidates.driveToAX(element(1, label: "Secure backup complete"))
        let snapshot = AXSnapshot(windowTitle: "Synthetic", snapshotID: "s1",
                                  elements: [status], treeMarkdown: "")
        XCTAssertTrue(TaskLoop.successEvidence(in: snapshot, task: TaskBrief(
            goal: "Confirm the secure backup completed", successContains: ["Secure backup complete"])))
        let secret = DriveCandidates.driveToAX(element(
            2, label: "Password", value: "private-sentinel", role: "AXSecureTextField"))
        let privateSnapshot = AXSnapshot(windowTitle: "Synthetic", snapshotID: "s2",
                                         elements: [secret], treeMarkdown: "")
        XCTAssertFalse(TaskLoop.successEvidence(in: privateSnapshot, task: TaskBrief(
            goal: "Confirm input", successContains: ["private-sentinel"])))
    }

    func testSDKPlaceholderWithoutTrustedActualValueCannotMatchLiteralOrProveCurrentValue() async throws {
        let window = Jarvis.WindowRef(pid: 7, windowID: 42)
        let raw: JSONValue = .object(["structuredContent": .object([
            "pid": .number(7), "window_id": .number(42),
            "snapshot_id": .string("native-1"), "window_title": .string("Synthetic"),
            "elements": .array([
                .object(["element_index": .number(0), "role": .string("AXWindow"),
                         "label": .string("Synthetic"), "depth": .number(0)]),
                .object(["element_index": .number(1), "role": .string("AXTextField"),
                         "label": .string("Email"), "value": .string("Email"),
                         "parent_index": .number(0), "depth": .number(1)]),
            ]),
        ])])
        let source = DriveLoop.DriveCaptureSource(
            observe: { _, _ in raw }, window: window, session: "synthetic",
            nativeRead: { _, _ in .init(elements: [], complete: true) })
        let snapshot = try await source.axTree(of: window, depth: .standard)
        XCTAssertNil(snapshot.elements.first { $0.index == 1 }?.value)
        XCTAssertFalse(snapshot.goalContextComplete)
        XCTAssertTrue(ObservedGoalProof.facts(in: snapshot).isEmpty)
        let elements = snapshot.elements.map(DriveCandidates.axToDrive)
        let candidates = DriveCandidates.drafts(elements: elements,
            snapshotID: snapshot.snapshotID, windowTitle: snapshot.windowTitle,
            goal: "Enter the exact text Email in Email", cap: nil, url: nil)
        let fields = DriveCandidates.observationFields(elements: elements,
            candidates: candidates, goal: "Enter the exact text Email in Email",
            values: ["Email": "Email"])
        XCTAssertNotEqual(fields["_candidate_details"]?["t1"]?["literal_matches_current_value"], .bool(true))
    }

    func testObservedContentBoundsLargeWindowsButKeepsCandidatesAndRelevantRows() {
        let marker = element(200, label: "SEEK-MARKER-77", role: "AXLink")
        var elements = (0..<200).map { element($0, label: "fill line \($0)") }
        elements.insert(marker, at: 150)
        elements.append(element(201, label: "marker zone", role: "AXScrollArea"))
        let candidates = DriveCandidates.drafts(elements: elements,
            snapshotID: "s1", windowTitle: "Synthetic", goal: "press SEEK-MARKER-77",
            cap: nil, url: nil)
        let fields = DriveCandidates.observationFields(elements: elements,
            candidates: candidates, goal: "press SEEK-MARKER-77", values: [:])
        let observed = fields["observed_content"]?.string ?? ""
        let lines = observed.split(separator: "\n")
        XCTAssertTrue(lines.count <= DriveCandidates.observedContentLimit + 2)
        XCTAssertTrue(observed.contains("SEEK-MARKER-77"))
        XCTAssertTrue(observed.contains("marker zone"))
        XCTAssertTrue(observed.contains("more element rows not listed"))
        XCTAssertTrue(lines.contains("fill line 0"))
    }
}
