import AppKit
import Foundation
import XCTest
@testable import Jarvis
import JarvisCore

/// The Terra step chooser on fake Responses payloads. No network, no
/// screen and no paid call.
final class TerraChooserTests: XCTestCase {
    private let candidates: [(id: String, description: String)] = [
        ("c0", "click 'Save' button"),
        ("c1", "click 'Delete' button"),
        ("done", "the goal is achieved"),
        ("reobserve", "look again"),
        ("stuck", "no safe step"),
    ]

    private func state(app: String = "com.apple.TextEdit", window: String = "Untitled",
                       steps: [String] = [], rows: String = "Save\nDelete") -> JSONValue {
        .object([
            "goal": .string("save the document"), "app": .string(app), "window": .string(window),
            "recent_steps": .array(steps.map(JSONValue.string)),
            "observed_content": .string(rows),
            "supplied_field_labels": .array([]),
            "_candidate_details": .object(["c0": .object(["tool": .string("click")])]),
            "_action_probability_floor": .number(0.7),
        ])
    }

    private static func payload(option: String, confidence: Double,
                                usage: String = #""usage":{"input_tokens":2000,"input_tokens_details":{"cached_tokens":1500},"output_tokens":20}"#) -> String {
        let answer = #"{\"option\":\"\#(option)\",\"confidence\":\#(confidence)}"#
        return #"{"status":"completed",\#(usage),"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"\#(answer)"}]}]}"#
    }

    private func client(_ json: String, seen: LockedBox<[Data]>? = nil,
                        usage: LockedBox<[TerraClient.Usage]>? = nil) -> TerraClient {
        var client = TerraClient(apiKey: { "sk-test" })
        client.transport = { request in
            seen?.set((seen?.value ?? []) + [request.httpBody ?? Data()])
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                                     httpVersion: nil, headerFields: nil)!)
        }
        if let usage { client.onUsage = { usage.set(usage.value + [$0]) } }
        return client
    }

    func testPicksTheOptionTerraNamesWithItsConfidence() async throws {
        let seen = LockedBox<[Data]>([])
        let choose = TerraChooser.make(client: client(Self.payload(option: "c0", confidence: 0.93), seen: seen))
        let choice = try await choose(state(), candidates)
        XCTAssertEqual(choice?.id, "c0")
        XCTAssertEqual(choice?.confidence ?? 0, 0.93, accuracy: 1e-9)
        XCTAssertNil(choice?.model, "Jev-only proofs must never accept a Terra pick")
        let body = try JSONDecoder().decode(JSONValue.self, from: try XCTUnwrap(seen.value.first))
        XCTAssertEqual(body["model"]?.string, "gpt-6.1-terra")
        XCTAssertEqual(body["store"]?.bool, false)
        XCTAssertEqual(body["reasoning"]?["effort"]?.string, "none")
        XCTAssertEqual(body["instructions"]?.string, TerraChooser.instructions)
        XCTAssertEqual(body["text"]?["format"]?["schema"], TerraChooser.schema)
        let text = body["input"]?.array?.first?["content"]?.array?.first?["text"]?.string ?? ""
        XCTAssertTrue(text.contains("c0: click 'Save' button [click]"), text)
        XCTAssertFalse(text.contains("_action_probability_floor"))
    }

    func testAnOptionOutsideTheListIsUnusableAndConfidenceIsClamped() async throws {
        let unknown = TerraChooser.make(client: client(Self.payload(option: "c9", confidence: 0.99)))
        let none = try await unknown(state(), candidates)
        XCTAssertNil(none)
        let high = TerraChooser.make(client: client(Self.payload(option: "c1", confidence: 7)))
        let clamped = try await high(state(), candidates)
        XCTAssertEqual(clamped?.confidence, 1)
    }

    func testAnActionBelowTheLoopsProbabilityFloorBecomesARejectedReobserve() async throws {
        let unsure = TerraChooser.make(client: client(Self.payload(option: "c0", confidence: 0.6)))
        let choice = try await unsure(state(), candidates)
        XCTAssertEqual(choice?.id, "reobserve")
        XCTAssertEqual(choice?.actionRejection, .selection)
        XCTAssertNil(choice?.confidence)
        let lowDone = TerraChooser.make(client: client(Self.payload(option: "done", confidence: 0.6)))
        let done = try await lowDone(state(), candidates)
        XCTAssertEqual(done?.id, "done")
        XCTAssertEqual(done?.actionRejection, nil)
    }

    func testAPasswordManagerWindowIsNeverSent() async {
        let seen = LockedBox<[Data]>([])
        let choose = TerraChooser.make(client: client(Self.payload(option: "c0", confidence: 1), seen: seen))
        for (app, window) in [("com.1password.1password", "Vault"), ("Notes", "Passwords")] {
            do {
                _ = try await choose(state(app: app, window: window), candidates)
                XCTFail("expected a refusal for \(app)")
            } catch {
                XCTAssertEqual(error as? TerraChooser.Refusal, .passwordManager)
            }
        }
        XCTAssertTrue(seen.value.isEmpty)
    }

    func testSecretsAndCardNumbersNeverReachThePrompt() {
        let prompt = TerraChooser.prompt(state: .object([
            "goal": .string("pay the bill"), "app": .string("Safari"),
            "observed_content": .string("Card number: 4111 1111 1111 1111\nName on card: Ann Lee\nPIN: 4321"),
            "screen_values": .string("Password=hunter2, CVV=123, City=Paris"),
            "recent_steps": .array([.string("typed 4111-1111-1111-1111 into a field")]),
        ]), candidates: [("c0", "click 'Pay 5555 5555 5555 4444' button")])
        for secret in ["4111", "hunter2", "4321", "=123", "5555"] {
            XCTAssertFalse(prompt.contains(secret), "\(secret) leaked: \(prompt)")
        }
        XCTAssertTrue(prompt.contains("City=Paris"))
        XCTAssertTrue(prompt.contains("Name on card: Ann Lee"))
        XCTAssertTrue(prompt.contains("Password=[hidden]"))
    }

    func testAWindowRowWithASensitiveLabelNeverSendsAnyPartOfItsValue() {
        let rows: [(String, String?)] = [("Payment: CVV", "987"), ("Password", "hunter, two\nthree"),
                                         ("City", "Paris"), ("Save", nil)]
        let prompt = TerraChooser.prompt(state: .object([
            "goal": .string("pay the bill"), "app": .string("Safari"),
            "observed_content": .string("Payment: CVV: 987\nPassword: hunter, two\nthree"),
            "screen_values": .string("Payment: CVV=987, Password=hunter, two\nthree"),
            "_rows": .object([
                "shown": .array(rows.map { .object(["label": .string($0.0), "value": $0.1.map(JSONValue.string) ?? .null]) }),
                "omitted": .number(2),
            ]),
        ]), candidates: [("c0", "click 'Pay' button")])
        for secret in ["987", "hunter", "two", "three"] {
            XCTAssertFalse(prompt.contains(secret), "\(secret) leaked: \(prompt)")
        }
        for kept in ["Payment: CVV: [hidden]", "Password: [hidden]", "City: Paris", "City=Paris", "\nSave\n",
                     "… 2 more element rows not listed"] {
            XCTAssertTrue(prompt.contains(kept), "missing \(kept): \(prompt)")
        }
    }

    func testALabelThatHoldsASeparatorIsStillReadAsALabel() {
        XCTAssertEqual(TerraChooser.redact("Payment: CVV: 123, City: Paris"), "Payment: CVV: [hidden], City: Paris")
        XCTAssertEqual(TerraChooser.redact("Card details: PIN=4321"), "Card details: PIN=[hidden]")
        XCTAssertEqual(TerraChooser.redact("Order: 12: shipped"), "Order: 12: shipped")
    }

    func testThePasswordManagerCheckUsesTheBoundWindowsOwner() async {
        let seen = LockedBox<[Data]>([])
        let choose = TerraChooser.make(client: client(Self.payload(option: "c0", confidence: 1), seen: seen))
        guard case .object(var fields) = state(app: "keychain", window: "login") else { return XCTFail() }
        fields["_app_identity"] = .object(["bundle_id": .string("com.apple.keychainaccess"),
                                           "name": .string("Keychain Access")])
        do {
            _ = try await choose(.object(fields), candidates)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? TerraChooser.Refusal, .passwordManager)
        }
        XCTAssertTrue(seen.value.isEmpty)
    }

    func testThePickerStateNamesTheBoundWindowsOwner() {
        let state = DriveCandidates.stateJSON(goal: "save", app: "text", window: "Untitled", options: [],
                                              recentSteps: [], context: nil,
                                              pid: Int(ProcessInfo.processInfo.processIdentifier))
        XCTAssertEqual(state["_app_identity"]?["name"]?.string,
                       NSRunningApplication.current.localizedName)
        XCTAssertNil(DriveCandidates.stateJSON(goal: "save", app: "text", window: "Untitled", options: [],
                                               recentSteps: [], context: nil)["_app_identity"])
    }

    func testStepsOfOneTaskShareTheirPromptPrefix() {
        let first = TerraChooser.prompt(state: state(steps: []), candidates: candidates)
        let second = TerraChooser.prompt(state: state(window: "Report", steps: ["clicked Save"],
                                                      rows: "Don't Save\nCancel"), candidates: candidates)
        let prefix = "Goal: save the document\nApp: com.apple.TextEdit\n"
        XCTAssertTrue(first.hasPrefix(prefix))
        XCTAssertTrue(second.hasPrefix(prefix))
    }

    func testUsageIsReportedAndPricedEvenWhenTheAnswerIsUnusable() async throws {
        let usage = LockedBox<[TerraClient.Usage]>([])
        let choose = TerraChooser.make(client: client(Self.payload(option: "c9", confidence: 1), usage: usage))
        _ = try await choose(state(), candidates)
        XCTAssertEqual(usage.value, [TerraClient.Usage(input: 2000, cached: 1500, output: 20)])
        let expected: Double = (500.0 * 1.25 + 1500.0 * 0.05 + 20.0 * 5.0) / 1_000_000.0
        XCTAssertEqual(usage.value.first?.dollars ?? 0, expected, accuracy: 1e-12)
    }
}
