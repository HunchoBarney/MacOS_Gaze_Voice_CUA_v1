import XCTest
@testable import JevVoice

/// Contract: dwell auto-click gates on mode / kind / app exemption /
/// deny list / secure roles, nothing dangerous fires in any mode, and
/// the delay is f(share × criticality × learned multiplier) inside a
/// clamped band. The engine fires at most once per acquire and reports
/// holds that ended engaged-but-unfired as aborts.
final class DwellPolicyTests: XCTestCase {

    private func candidate(_ kind: IntentCandidate.Kind = .axElement,
                           role: String = "AXButton",
                           label: String = "Save",
                           id: String = "ax:1:2:tok",
                           app: String? = "Test",
                           windowTitle: String? = nil,
                           url: String? = nil) -> IntentCandidate {
        let r = CGRect(x: 0, y: 0, width: 80, height: 24)
        return IntentCandidate(id: id, kind: kind, frame: r, motorRect: r,
                               role: role, label: label, url: url,
                               appName: app, windowTitle: windowTitle)
    }

    private func policy(_ mode: DwellPolicy.Mode) -> DwellPolicy {
        DwellPolicy(mode: mode, deniedApps: [], userMultiplier: 1)
    }

    // MARK: mode + kind gating

    func testOffFiresNothing() {
        let p = policy(.off)
        for kind: IntentCandidate.Kind in [.axElement, .trafficLight, .dom,
                                           .menuBar, .ocr, .window, .chip,
                                           .agentCursor] {
            XCTAssertFalse(p.allows(candidate(kind)), "\(kind)")
        }
    }

    func testSafeReachesVerifiedKindsOnly() {
        let p = policy(.safe)
        XCTAssertTrue(p.allows(candidate(.axElement)))
        XCTAssertTrue(p.allows(candidate(.dom, role: "link")))
        XCTAssertTrue(p.allows(candidate(.menuBar, role: "menu bar item")))
        XCTAssertTrue(p.allows(candidate(.trafficLight,
                                         id: "traffic:1:2:minimize")))
        // The OCR floor and the window-blind click stay out of safe.
        XCTAssertFalse(p.allows(candidate(.ocr, role: "text")))
        XCTAssertFalse(p.allows(candidate(.window, role: "window")))
        // Chips and agent cursors never — chips are the overlay's own
        // dwell pick; cursors are observability, not controls.
        XCTAssertFalse(p.allows(candidate(.chip)))
        XCTAssertFalse(p.allows(candidate(.agentCursor)))
    }

    func testAllAddsTheFloorsButNeverChrome() {
        let p = policy(.all)
        XCTAssertTrue(p.allows(candidate(.window, role: "window")))
        XCTAssertTrue(p.allows(candidate(.ocr, role: "text")))
        XCTAssertFalse(p.allows(candidate(.chip)))
        XCTAssertFalse(p.allows(candidate(.agentCursor)))
    }

    // MARK: deny list — a wall in every mode

    func testDeniedLabelsNeverFire() {
        for label in ["Delete", "Empty Trash", "Send", "Submit Payment",
                      "Buy Now", "Quit", "Sign Out", "Close Tab",
                      "Force Quit", "Unsubscribe"] {
            for mode: DwellPolicy.Mode in [.safe, .all] {
                XCTAssertFalse(policy(mode).allows(candidate(label: label)),
                               "\(label) @ \(mode)")
            }
        }
    }

    /// Separator tricks don't evade the list — "Sign-Out" is "sign out".
    func testDenyNormalizesSeparators() {
        XCTAssertFalse(policy(.all).allows(candidate(label: "Sign-Out")))
        XCTAssertFalse(policy(.all).allows(candidate(label: "Force_Quit")))
    }

    /// The model loop's consequential phrases (CuaPolicy.deniedPatterns)
    /// are on dwell's wall too — financial and destructive multiword
    /// denials, not just single verbs.
    func testDeniedCuaPolicyPhrases() {
        for label in ["Transfer Money", "Wire Transfer", "Send Payment",
                      "Pay Now", "Place Order", "Factory Reset",
                      "Reset All Settings", "Delete Account",
                      "Remove Device", "Allow Remote Access",
                      "Share My Screen", "Enter Recovery"] {
            XCTAssertFalse(policy(.all).allows(candidate(label: label)),
                           "\(label)")
        }
    }

    /// The deny corpus is wider than the label — a "Confirm delete"
    /// window title, a remote-access app name, or a wire-transfer URL
    /// denies just as hard.
    func testDenyCorpusIncludesContextFields() {
        XCTAssertFalse(policy(.all).allows(
            candidate(label: "OK", windowTitle: "Confirm Delete")))
        XCTAssertFalse(policy(.all).allows(
            candidate(label: "OK", url: "https://x.test/wire-transfer")))
        XCTAssertFalse(policy(.all).allows(
            candidate(label: "OK", app: "Close.io CRM")))
    }

    /// Invisible and lookalike characters can't smuggle a denied label —
    /// ZWSP vanishes, a soft hyphen is a separator, Cyrillic folds to ASCII.
    func testDenyDefeatsObfuscation() {
        XCTAssertEqual(DwellPolicy.normalized("Dele\u{200B}te"), "delete")
        XCTAssertEqual(DwellPolicy.normalized("Sign\u{00AD}Out"), "sign out")
        XCTAssertEqual(DwellPolicy.normalized("Cl\u{043E}se"), "close")
        XCTAssertFalse(policy(.all).allows(candidate(label: "Dele\u{200B}te")))
        XCTAssertFalse(policy(.all).allows(candidate(label: "Sign\u{00AD}Out")))
        XCTAssertFalse(policy(.all).allows(candidate(label: "Cl\u{043E}se")))
        XCTAssertFalse(policy(.all).allows(candidate(label: "Tr4nsf3r M0ney")))
    }

    /// A token that normalizes to nothing (all-punctuation entries like
    /// ":(){") is inert, never an everything-deny.
    func testEmptyNormalizedTokenIsInert() {
        XCTAssertTrue(policy(.all).allows(candidate(label: "Save")))
    }

    func testSecureFieldsNeverFire() {
        XCTAssertFalse(policy(.all)
            .allows(candidate(role: "AXSecureTextField", label: "Password")))
    }

    /// The red close button is denied by its id, not its label — a
    /// renamed button can't slip the check.
    func testTrafficLightCloseDeniedByID() {
        XCTAssertFalse(policy(.all).allows(
            candidate(.trafficLight, label: "close", id: "traffic:1:2:close")))
        XCTAssertFalse(policy(.all).allows(
            candidate(.trafficLight, label: "go full", id: "traffic:1:2:fullscreen")))
        XCTAssertTrue(policy(.all).allows(
            candidate(.trafficLight, label: "the yellow minimize button",
                      id: "traffic:1:2:minimize")))
    }

    func testDeniedAppExemptsEveryCandidate() {
        let p = DwellPolicy(mode: .all, deniedApps: ["bank"], userMultiplier: 1)
        XCTAssertFalse(p.allows(candidate(app: "Bank")))
        XCTAssertTrue(p.allows(candidate(app: "Notes")))
    }

    // MARK: delay

    func testDelayBand() {
        let p = policy(.safe)
        let button = candidate()
        // Plain hold → base; a dominant share on a clickable role → fast.
        XCTAssertEqual(p.delay(for: button, share: 0.5), DwellPolicy.baseDelay,
                       accuracy: 0.001)
        XCTAssertEqual(p.delay(for: button, share: DwellPolicy.dominantShare),
                       DwellPolicy.fastDelay, accuracy: 0.001)
        // A dominant share on a non-clickable role does not go fast.
        let staticText = candidate(role: "AXStaticText")
        XCTAssertEqual(p.delay(for: staticText, share: 1),
                       DwellPolicy.baseDelay, accuracy: 0.001)
    }

    func testMultiplierAdaptsInsideClamp() {
        var p = policy(.safe)
        // A committed click shrinks the delay toward fluency.
        for _ in 0..<10 { p.recordCommit() }
        XCTAssertEqual(p.userMultiplier, 0.75, accuracy: 0.001)
        // Aborted holds grow it back, capped.
        for _ in 0..<40 { p.recordAbort() }
        XCTAssertEqual(p.userMultiplier, 1.6, accuracy: 0.001)
        XCTAssertEqual(p.delay(for: candidate(), share: 0.5),
                       DwellPolicy.baseDelay * 1.6, accuracy: 0.001)
    }

    // MARK: persistence

    func testDefaultsRoundTrip() {
        let suite = "dwell-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        var p = DwellPolicy(mode: .all, deniedApps: ["Bank"], userMultiplier: 1.2)
        p.save(to: defaults)
        let loaded = DwellPolicy.load(from: defaults)
        XCTAssertEqual(loaded.mode, .all)
        XCTAssertEqual(loaded.deniedApps, ["bank"])
        XCTAssertEqual(loaded.userMultiplier, 1.2, accuracy: 0.001)
        // Out-of-band values clamp rather than trusting the defaults.
        p.userMultiplier = 42
        p.save(to: defaults)
        XCTAssertEqual(DwellPolicy.load(from: defaults).userMultiplier, 1.6,
                       accuracy: 0.001)
    }

    /// The pinned vocabulary: off / safe / all, default safe — an
    /// unset key is `safe`, an unknown value is `safe`.
    func testModeDefaultAndUnknown() {
        let suite = "dwell-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        XCTAssertEqual(DwellPolicy.load(from: defaults).mode, .safe)
        defaults.set("nonsense", forKey: DwellPolicy.modeKey)
        XCTAssertEqual(DwellPolicy.load(from: defaults).mode, .safe)
    }
}

final class GazeDwellTests: XCTestCase {

    private func candidate(_ id: String = "a") -> IntentCandidate {
        let r = CGRect(x: 0, y: 0, width: 80, height: 24)
        return IntentCandidate(id: id, kind: .axElement, frame: r,
                               motorRect: r, role: "AXButton", label: "Save",
                               appName: "Test")
    }

    private let policy = DwellPolicy(mode: .safe, deniedApps: [], userMultiplier: 1)

    /// Hold past the delay fires once — further holds don't re-fire.
    func testFiresOncePerAcquire() {
        var d = GazeDwell()
        let c = candidate()
        XCTAssertEqual(d.advance(.acquire(c), share: 0.9, policy: policy), .none)
        XCTAssertEqual(d.advance(.hold(c, progress: 0.39), share: 0.9, policy: policy), .none)
        // Fast tier: dominant share + button → delay 0.4, met exactly.
        XCTAssertEqual(d.advance(.hold(c, progress: 0.4), share: 0.9, policy: policy), .fire(c))
        XCTAssertEqual(d.advance(.hold(c, progress: 0.9), share: 0.9, policy: policy), .none)
        // Release after firing is not an abort.
        XCTAssertEqual(d.advance(.release(c), share: 0, policy: policy), .none)
    }

    /// A denied candidate holds forever without firing — the engine
    /// trusts the policy gate, never the progress alone.
    func testDeniedNeverFires() {
        var d = GazeDwell()
        let c = candidate()
        var p = policy
        p.deniedApps = ["test"]
        _ = d.advance(.acquire(c), share: 0.9, policy: policy)
        XCTAssertEqual(d.advance(.hold(c, progress: 0.99), share: 0.9,
                                   policy: p), .none)
    }

    /// Release below the engagement floor is a glance, not an abort.
    func testQuickReleaseIsNotAbort() {
        var d = GazeDwell()
        let c = candidate()
        _ = d.advance(.acquire(c), share: 0.9, policy: policy)
        _ = d.advance(.hold(c, progress: 0.1), share: 0.9, policy: policy)
        XCTAssertEqual(d.advance(.release(c), share: 0, policy: policy), .none)
    }

    /// An engaged hold that ends without firing is an abort — the
    /// multiplier's "that fire was too eager" signal.
    func testEngagedReleaseIsAbort() {
        var d = GazeDwell()
        let c = candidate()
        var p = policy
        p.deniedApps = ["test"]   // the policy can't fire this app
        _ = d.advance(.acquire(c), share: 0.9, policy: p)
        _ = d.advance(.hold(c, progress: 0.6), share: 0.9, policy: p)
        XCTAssertEqual(d.advance(.release(c), share: 0, policy: p), .aborted)
    }

    /// Winner switch mid-hold: the old hold reports its abort (if
    /// engaged), the new winner starts a fresh clock.
    func testAcquireSwitchAbortsOldHold() {
        var d = GazeDwell()
        let a = candidate("a"), b = candidate("b")
        var p = policy
        p.deniedApps = ["test"]
        _ = d.advance(.acquire(a), share: 0.9, policy: p)
        _ = d.advance(.hold(a, progress: 0.7), share: 0.9, policy: p)
        XCTAssertEqual(d.advance(.acquire(b), share: 0.9, policy: p), .aborted)
        // And the new hold starts clean — progress 0 → none.
        XCTAssertEqual(d.advance(.hold(b, progress: 0.05), share: 0.9,
                               policy: p), .none)
    }

    /// Ambiguity pauses, never fires and never aborts.
    func testAmbiguousPauses() {
        var d = GazeDwell()
        let c = candidate()
        _ = d.advance(.acquire(c), share: 0.9, policy: policy)
        _ = d.advance(.hold(c, progress: 0.3), share: 0.9, policy: policy)
        XCTAssertEqual(d.advance(.ambiguous([c]), share: 0, policy: policy), .none)
        XCTAssertEqual(d.advance(.hold(c, progress: 0.41), share: 0.9, policy: policy),
                       .fire(c))
    }

    /// Feed loss (.none) ends the hold — a stalled winner can't fire,
    /// and a below-floor release isn't an abort. The scorer re-acquires
    /// before holding again, so the fresh hold starts clean.
    func testFeedLossEndsHold() {
        var d = GazeDwell()
        let c = candidate()
        _ = d.advance(.acquire(c), share: 0.9, policy: policy)
        _ = d.advance(.hold(c, progress: 0.3), share: 0.9, policy: policy)
        XCTAssertEqual(d.advance(.none, share: 0, policy: policy), .none)
        _ = d.advance(.acquire(c), share: 0.9, policy: policy)
        XCTAssertEqual(d.advance(.hold(c, progress: 0.2), share: 0.9, policy: policy),
                       .none)
    }
}
