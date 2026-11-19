import XCTest
import CoreGraphics
import os
@testable import JevVoice

@MainActor
final class CommittedGazeHitTests: XCTestCase {
    typealias Hit = CommittedGazeHit.Hit<Int>
    private let point = CGPoint(x: 25, y: 25)
    private let frame = CGRect(x: 10, y: 10, width: 100, height: 40)

    private func hit(element: Int = 1, window: Int = 7, ancestors: [Int] = [3], pid: pid_t = 42,
                     wid: Int = 7, role: String = "AXButton", name: String = "Edit",
                     title: String = "Fixture", detail: String = "", frame: CGRect? = nil,
                     light: WindowControls.Kind? = nil) -> Hit {
        Hit(element: element, window: window, ancestors: ancestors, pid: pid, windowID: wid, windowTitle: title,
            role: role, name: name, detail: detail, frame: frame ?? self.frame, light: light)
    }

    private func candidate(id: String = "ax:42:7:s00000009:0", kind: IntentCandidate.Kind = .axElement,
                           label: String = "Edit", role: String = "AXButton") -> IntentCandidate {
        IntentCandidate(id: id, kind: kind, frame: frame, motorRect: frame, role: role,
                        label: label, pid: 42, windowID: 7, windowTitle: "Fixture")
    }

    func testBothEnumerationReadsRunOffMainAndCannotAuthorizePress() async throws {
        let reads = OSAllocatedUnfairLock(initialState: [Bool]())
        let initial = hit()
        let result = await CommittedGazeHit.capture(at: point, enumerating: { _ in
            reads.withLock { $0.append(Thread.isMainThread) }
            return initial
        }, press: { _ in XCTFail("Enumeration cannot post input"); return false })
        let witness = try XCTUnwrap(result)
        let corroborated = await witness.corroborates(candidate(), at: point)
        XCTAssertTrue(corroborated)
        XCTAssertFalse(witness.press(ifCurrent: { true }))
        XCTAssertEqual(reads.withLock { $0 }, [false, false])
    }

    func testFinalPressChecksSourceAfterRehitAndPreparation() throws {
        var order = [String]()
        var current = true
        let initial = hit()
        let witness = try XCTUnwrap(CommittedGazeHit.capture(at: point, read: { _ in
            order.append("hit")
            if order.count == 3 { current = false }
            return initial
        }, prepare: { _ in order.append("prepare"); return true },
           press: { _ in XCTFail("Revoked source"); return true }))
        XCTAssertTrue(witness.matches(candidate(), at: point))
        XCTAssertFalse(witness.press(ifCurrent: { order.append("source"); return current }))
        XCTAssertEqual(order, ["hit", "hit", "hit", "prepare", "source"])
        XCTAssertFalse(witness.press(ifCurrent: { true }))
    }

    func testNativeVisibilityRequiresSameGlobalHitAndFirstNormalWindow() {
        func row(_ layer: Int, _ pid: Int, _ id: Int) -> [String: Any] {
            [kCGWindowBounds as String: frame.dictionaryRepresentation,
             kCGWindowLayer as String: layer, kCGWindowOwnerPID as String: pid, kCGWindowNumber as String: id]
        }
        let target = row(0, 42, 7), passiveRing = row(101, 43, 9), hud = row(1000, 44, 10)
        func visible(_ rows: [[String: Any]], finalHit: Int?) -> Bool {
            CommittedGazeHit.confirmsVisibility(of: 1, at: point, pid: 42, id: 7, rows: rows) { finalHit }
        }
        XCTAssertTrue(visible([hud, passiveRing, target], finalHit: 1))
        XCTAssertFalse(visible([hud, target], finalHit: 2))
        XCTAssertFalse(visible([passiveRing, target], finalHit: nil))
        XCTAssertFalse(visible([row(0, 42, 8), target], finalHit: 1))
        XCTAssertFalse(visible([row(0, 55, 7), target], finalHit: 1))
        XCTAssertFalse(visible([hud, passiveRing], finalHit: 1))
        XCTAssertFalse(visible([[:], target], finalHit: 1))
    }

    func testStableNativeControlPressesRetainedObjectOnce() throws {
        for role in ["AXButton", "AXLink", "AXCheckBox"] {
            let initial = hit(role: role), c = candidate(role: role)
            var reads = 0, pressed: [Int] = []
            let witness = try XCTUnwrap(CommittedGazeHit.capture(at: point, read: { _ in
                reads += 1
                return initial
            }, press: { pressed.append($0); return true }))
            XCTAssertFalse(witness.press(ifCurrent: { true }))
            XCTAssertTrue(witness.describes(c, at: point))
            XCTAssertEqual(reads, 1)
            XCTAssertTrue(witness.matches(c, at: point))
            XCTAssertTrue(witness.press(ifCurrent: { true }))
            XCTAssertFalse(witness.press(ifCurrent: { true }))
            XCTAssertEqual(pressed, [initial.element])
            XCTAssertEqual(reads, 3)
        }
    }

    func testChangeBeforeEitherBoundaryBlocksWithoutRetargeting() throws {
        let c = candidate()
        for replacement in [nil, hit(element: 2), hit(window: 11), hit(wid: 8), hit(ancestors: [4]),
                            hit(pid: 21), hit(title: "New"), hit(name: "New"), hit(detail: "New"),
                            hit(role: "AXLink"), hit(frame: frame.offsetBy(dx: 1, dy: 1))] {
            for swapAfterMatch in [false, true] {
                var current: Hit? = hit()
                let witness = try XCTUnwrap(CommittedGazeHit.capture(at: point, read: { _ in current },
                    press: { _ in XCTFail("Unexpected AXPress"); return true }))
                if swapAfterMatch { XCTAssertTrue(witness.matches(c, at: point)) }
                current = replacement
                if !swapAfterMatch { XCTAssertFalse(witness.matches(c, at: point)) }
                XCTAssertFalse(witness.press(ifCurrent: { true }))
                current = hit()
                XCTAssertFalse(witness.matches(c, at: point), "A retired witness cannot rearm")
            }
        }
    }

    func testCandidateCannotSubstitutePixelProxyOrStructuralIdentity() throws {
        let initial = hit()
        var reads = 0
        let witness = try XCTUnwrap(CommittedGazeHit.capture(at: point, read: { _ in reads += 1; return initial },
            press: { _ in XCTFail("Unexpected AXPress"); return false }))
        var bad = [candidate(id: "ax:42:7:_idx_1"), candidate(id: "ax:42:7:opaque"),
                   candidate(id: "ax:99:7:s00000009:0"), candidate(id: "ax:42:8:s00000009:0"),
                   candidate(id: "ax:42:7:s00000009:0:1"), candidate(role: "AXGroup"), candidate(label: "")]
        for kind in [IntentCandidate.Kind.ocr, .dom, .window, .menuBar, .agentCursor, .chip, .trafficLight] {
            bad.append(candidate(kind: kind))
        }
        var drift = candidate()
        drift.motorRect = frame.offsetBy(dx: 1, dy: 0)
        bad.append(drift)
        for c in bad {
            XCTAssertFalse(witness.matches(c, at: point), c.id)
            XCTAssertFalse(witness.press(ifCurrent: { true }))
        }
        XCTAssertFalse(witness.matches(candidate(), at: CGPoint(x: 500, y: 500)))
        XCTAssertEqual(reads, 1)
    }

    func testTrafficLightNeedsExactWindowKindAndRetainedButton() throws {
        let light = WindowControls.Kind.minimize
        let c = candidate(id: "traffic:42:7:minimize", kind: .trafficLight, label: light.spokenName)
        var current = hit(name: "minimize", light: light)
        func capture() throws -> CommittedGazeHit {
            try XCTUnwrap(CommittedGazeHit.capture(at: point, read: { _ in current },
                press: { _ in XCTFail("Unexpected AXPress"); return true }))
        }
        let first = try capture()
        XCTAssertFalse(first.matches(candidate(id: "traffic:42:7:zoom", kind: .trafficLight,
                                               label: WindowControls.Kind.zoom.spokenName), at: point))
        XCTAssertFalse(first.matches(candidate(id: "traffic:42:99:minimize", kind: .trafficLight,
                                               label: light.spokenName), at: point))
        XCTAssertTrue(first.matches(c, at: point))
        XCTAssertTrue(first.representsSameElement(as: try capture()))
        current = hit(element: 22, name: "minimize", light: light)
        XCTAssertFalse(first.representsSameElement(as: try capture()))
        XCTAssertFalse(first.press(ifCurrent: { true }))
    }
}
