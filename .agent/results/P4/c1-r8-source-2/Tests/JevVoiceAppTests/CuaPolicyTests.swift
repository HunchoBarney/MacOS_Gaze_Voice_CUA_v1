import XCTest
@testable import JevVoice
import JevVoiceCore

/// Contract: CuaPolicy is the single consent choke point. Rule order —
/// observation always passes, denied driver-state tools always refuse,
/// the deny list blocks before any grant, the standing grant allows the
/// rest, otherwise the caller must confirm. Desktop scope is NOT a rule
/// here: it rides the explicit/autonomous split (a spoken deictic click
/// self-consents, a model pick needs the grant like everything else).
final class CuaPolicyTests: XCTestCase {
    private func decide(_ tool: String, args: [String: JSONValue] = [:],
                        elementText: String? = nil, grant: Bool = false) -> CuaPolicy.Decision {
        CuaPolicy.decide(tool: tool, args: args, elementText: elementText,
                         standingGrant: grant)
    }

    // MARK: Observation always passes

    func testObservationToolsPassWithoutGrant() {
        for tool in CuaPolicy.observationTools {
            XCTAssertEqual(decide(tool), .allow, tool)
        }
    }

    // MARK: Deny list precedes the grant

    func testDenyListBlocksEvenWithGrant() {
        // A protected label refuses whether or not the standing grant is on.
        for grant in [false, true] {
            guard case .deny = decide("click", elementText: "Empty Trash",
                                      grant: grant) else {
                return XCTFail("Empty Trash must deny, grant=\(grant)")
            }
            guard case .deny = decide("browser_navigate",
                                      args: ["url": .string("https://bank.example/transfer-money")],
                                      grant: grant) else {
                return XCTFail("money-transfer URL must deny, grant=\(grant)")
            }
            guard case .deny = decide("type_text",
                                      args: ["button": .string("rm -rf /")],
                                      grant: grant) else {
                return XCTFail("rm -rf must deny, grant=\(grant)")
            }
        }
    }

    /// Session-state tools are denied outright — not grant-able.
    func testDriverStateToolsDenied() {
        for tool in ["allow_app", "deny_app", "install_extension",
                     "stop_driver", "restart_driver", "set_driver_config",
                     "execute_script", "run_applescript", "shell_command"] {
            guard case .deny = decide(tool, grant: true) else {
                return XCTFail("\(tool) must deny even with grant")
            }
        }
    }

    // MARK: Desktop scope

    /// Desktop scope is not a policy denial: the (a)/(b) split handles it.
    /// With the grant a scoped click is an ordinary effect; without one it
    /// must still confirm — the consent question, never a refusal class.
    func testDesktopScopeRidesGrant() {
        XCTAssertEqual(decide("click",
                              args: ["scope": .string("desktop")],
                              grant: true), .allow)
        guard case .needsConfirm = decide("click",
                                          args: ["scope": .string("desktop")],
                                          grant: false) else {
            return XCTFail("desktop scope without grant must confirm, not refuse")
        }
    }

    // MARK: deniedPhrase — the seam explicit-consent lanes call

    func testDeniedPhraseMatchesNormalizedText() {
        XCTAssertEqual(CuaPolicy.deniedPhrase(in: "the Empty Trash menu item"),
                       "empty trash")
        // Separators normalize — "Confirm-Purchase" hits a protected
        // phrase whichever spelling the UI used.
        XCTAssertNotNil(CuaPolicy.deniedPhrase(in: "Confirm-Purchase now?"))
        XCTAssertNotNil(CuaPolicy.deniedPhrase(in: "https://x.example/place-order"))
        XCTAssertNil(CuaPolicy.deniedPhrase(in: "save the draft"))
        XCTAssertNil(CuaPolicy.deniedPhrase(in: ""))
    }

    // MARK: Grant gate

    func testEffectToolNeedsConfirmWithoutGrant() {
        guard case .needsConfirm = decide("click",
                                          args: ["element_index": .number(3)],
                                          elementText: "Save") else {
            return XCTFail("mutation without grant must ask")
        }
    }

    /// The confirm prompt names the tool and the target — the card the
    /// user approves says what it does, not a generic "computer use".
    func testConfirmPromptNamesToolAndTarget() {
        // The target must be benign — a deny-listed label refuses before
        // a prompt exists, and the prompt is what this test inspects.
        guard case .needsConfirm(let prompt) = decide("click",
                                                      elementText: "Open Folder") else {
            return XCTFail("expected a confirm prompt")
        }
        XCTAssertTrue(prompt.contains("click"), prompt)
        XCTAssertTrue(prompt.contains("Open Folder"), prompt)
    }

    /// An element-less mutation still names the tool it would run.
    func testConfirmPromptWithoutTargetNamesTool() {
        guard case .needsConfirm(let prompt) = decide("press_key") else {
            return XCTFail("expected a confirm prompt")
        }
        XCTAssertTrue(prompt.contains("press_key"), prompt)
    }

    func testEffectToolAllowedWithGrant() {
        XCTAssertEqual(decide("click", args: ["element_index": .number(3)],
                              elementText: "Save", grant: true), .allow)
        XCTAssertEqual(decide("type_text", args: ["text": .string("hi")],
                              grant: true), .allow)
    }

    /// Unknown tools are treated as effect tools — fail safe, not open.
    func testUnknownToolFailsSafe() {
        guard case .needsConfirm = decide("some_future_tool", grant: false) else {
            return XCTFail("unknown tool must not auto-allow")
        }
        XCTAssertEqual(decide("some_future_tool", grant: true), .allow)
    }

    /// User-typed literal text is NOT scanned for deny patterns — the deny
    /// corpus is the element's label plus navigation/button args only.
    func testLiteralTextNotDenyScanned() {
        // Typing a document that discusses rm -rf is not rm -rf.
        guard case .needsConfirm = decide("type_text",
                                          args: ["text": .string("never run rm -rf casually")]) else {
            return XCTFail("literal text must not trip the deny list")
        }
    }
}
