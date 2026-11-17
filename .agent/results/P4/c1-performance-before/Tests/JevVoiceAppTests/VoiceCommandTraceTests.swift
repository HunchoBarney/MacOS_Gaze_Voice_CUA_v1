import Foundation
import LocalAuthentication
import Security
import XCTest
@testable import JevVoice

@MainActor
final class VoiceCommandTraceTests: XCTestCase {
    func testNativeUnhideTraceIsDistinctAndDoesNotInventDriverCalls() throws {
        let trace = VoiceCommandTrace(), turn = UUID(), task = UUID()
        for name in ["nativeUnhideBegin", "nativeUnhideEnd", "nativeUnhideFailed"] {
            let stage = try XCTUnwrap(VoiceCommandTrace.Stage(rawValue: name))
            trace.record(stage, turn: turn, task: task, at: 10)
        }
        XCTAssertEqual(trace.events.map(\.stage.rawValue),
                       ["nativeUnhideBegin", "nativeUnhideEnd", "nativeUnhideFailed"])
        XCTAssertTrue(trace.events.allSatisfy { $0.turn == turn && $0.task == task && $0.tool == nil })
        XCTAssertFalse(trace.events.contains { $0.stage == .driverBegin })
    }

    func testNativeTextTraceUsesIssuanceClockWithoutInventingDriverCalls() throws {
        let trace = VoiceCommandTrace(), turn = UUID(), task = UUID()
        let began = try XCTUnwrap(VoiceCommandTrace.Stage(rawValue: "nativeTextInsertionBegin"))
        let ended = try XCTUnwrap(VoiceCommandTrace.Stage(rawValue: "nativeTextInsertionEnd"))
        trace.record(began, turn: turn, task: task, tool: .typeText, at: 10)
        trace.record(ended, turn: turn, task: task, tool: .typeText, at: 11)
        XCTAssertEqual(trace.events.map(\.monotonic), [10, 11])
        XCTAssertTrue(trace.events.allSatisfy { $0.turn == turn && $0.task == task })
        XCTAssertFalse(trace.events.contains { $0.stage == .driverBegin })
    }

    func testPhysicalTrialFailureDistinguishesObservedForegroundFromTaskSuccess() {
        let observed = VoiceLiveTrial.completionFailureMessage(
            foregroundObserved: true, taskMessage: "No observable window")
        XCTAssertTrue(observed.contains("seen in front"))
        XCTAssertTrue(observed.contains("verification failed"))
        let missing = VoiceLiveTrial.completionFailureMessage(
            foregroundObserved: false, taskMessage: "No observable window")
        XCTAssertTrue(missing.contains("did not complete successfully"))
        XCTAssertFalse(missing.contains("seen in front"))
    }

    func testTraceBoundAndPayloadAllowlist() throws {
        let trace = VoiceCommandTrace(), turn = UUID()
        for _ in 0..<80 { trace.record(.driverBegin, turn: turn, tool: .init("SECRET instruction/key/window title")) }
        XCTAssertEqual(trace.events.count, 64)
        XCTAssertEqual(trace.dropped, 16)
        for _ in 0..<300 { trace.record(.workCreated, turn: UUID(), task: UUID()) }
        XCTAssertEqual(trace.events.count, 256)
        for event in trace.events {
            let bytes = try JSONEncoder().encode(event)
            XCTAssertLessThanOrEqual(bytes.count, 512)
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("SECRET"))
        }
        let data = try JSONSerialization.data(withJSONObject: trace.snapshot(since: 0))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("SECRET"))
    }

    func testTraceKeepsTurnTaskIdentityAndExposesIncompleteAwait() {
        let trace = VoiceCommandTrace(), turn = UUID(), task = UUID()
        trace.record(.coordinatorBegin, turn: turn)
        trace.record(.gazeBegin, turn: turn)
        XCTAssertEqual(trace.events.last?.stage, .gazeBegin)
        trace.record(.gazeEnd, turn: turn)
        trace.record(.workCreated, turn: turn, task: task)
        trace.record(.driverBegin, turn: turn, task: task, tool: .foreground)
        trace.record(.driverFailed, turn: turn, task: task, tool: .foreground)
        XCTAssertTrue(trace.events.allSatisfy { $0.turn == turn })
        XCTAssertEqual(trace.events.last?.task, task)
        XCTAssertEqual(trace.events.last?.stage, .driverFailed)
    }

    private struct EmptyKeys: APIKeyStore {
        func read() throws -> String? { nil }
        func save(_ apiKey: String) throws {}
        func delete() throws {}
    }

    func testDiagnosticCredentialInteractionPolicy() {
        XCTAssertFalse(Config.startupKeychainInteractionAllowed(
            environment: ["JARVIS_P3_GUI_AUDIT": "1"], arguments: ["JevVoice", "--p3-user-audit"]))
        XCTAssertTrue(Config.startupKeychainInteractionAllowed(environment: [:], arguments: ["JevVoice"]))
        XCTAssertTrue(Config.startupKeychainInteractionAllowed(
            environment: ["JARVIS_P3_GUI_AUDIT": "1"], arguments: ["JevVoice"]))
        var policies: [(String, Bool)] = []
        _ = VoiceUserAudit.diagnosticConfiguration(defaults: UserDefaults(suiteName: "trace-\(UUID())")!,
            environment: [:], store: { name, allowed in policies.append((name, allowed)); return EmptyKeys() })
        XCTAssertEqual(policies.map(\.0), ["typesafeAPIKey", "openAIAPIKey"])
        XCTAssertTrue(policies.allSatisfy { !$0.1 })
    }

    func testLegacyAndModernNoninteractiveKeychainPoliciesAreBothApplied() {
        let policy = KeychainAPIKeyStore.authenticationPolicy(allowUserInteraction: false)
        XCTAssertEqual(policy[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIFail as String)
        XCTAssertTrue((policy[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
        XCTAssertTrue(KeychainAPIKeyStore.authenticationPolicy(allowUserInteraction: true).isEmpty)
    }

    func testNetworkFreeTraceRequiresEveryDiagnosticCondition() {
        let env = ["JARVIS_P3_GUI_AUDIT": "1", "JARVIS_P3_GUI_AUDIT_TRACE_ONLY": "1"]
        XCTAssertTrue(VoiceUserAudit.isNetworkFreeTrace(environment: env, arguments: ["--p3-user-audit"]))
        XCTAssertFalse(VoiceUserAudit.isNetworkFreeTrace(environment: [:], arguments: ["--p3-user-audit"]))
        XCTAssertFalse(VoiceUserAudit.isNetworkFreeTrace(environment: env, arguments: []))
        XCTAssertFalse(VoiceUserAudit.isNetworkFreeTrace(
            environment: ["JARVIS_P3_GUI_AUDIT": "1"], arguments: ["--p3-user-audit"]))
        XCTAssertFalse(VoiceUserAudit.isNetworkFreeTrace(
            environment: ["JARVIS_P3_GUI_AUDIT_TRACE_ONLY": "1"], arguments: ["--p3-user-audit"]))
    }

    func testTypingIsolationIsNetworkFreeOnlyInsideDiagnosticApp() {
        let flag = "JARVIS_P3_GUI_AUDIT_TYPING_ONLY"
        let env = ["JARVIS_P3_GUI_AUDIT": "1", flag: "1"]
        XCTAssertTrue(VoiceUserAudit.isNetworkFreeTrace(environment: env, arguments: ["--p3-user-audit"]))
        XCTAssertFalse(VoiceUserAudit.isNetworkFreeTrace(environment: env, arguments: []))
        XCTAssertFalse(VoiceUserAudit.isNetworkFreeTrace(
            environment: [flag: "1"], arguments: ["--p3-user-audit"]))
        XCTAssertFalse(VoiceUserAudit.isNetworkFreeTrace(
            environment: ["JARVIS_P3_GUI_AUDIT": "1", flag: "0"], arguments: ["--p3-user-audit"]))
    }

    func testNetworkFreeDiagnosticHasNoHostedKeysOrLegacyMigration() {
        let suite = "diagnostic-no-keys-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("legacy-diagnostic-sentinel", forKey: "typesafeAPIKey")
        let env = ["JARVIS_P3_GUI_AUDIT": "1", "JARVIS_P3_GUI_AUDIT_TYPING_ONLY": "1",
                   "TYPESAFE_API_KEY": "typesafe-environment-sentinel",
                   "OPENAI_API_KEY": "openai-environment-sentinel"]
        let config = VoiceUserAudit.diagnosticConfiguration(defaults: defaults, environment: env,
            arguments: ["--p3-user-audit"], store: { _, _ in
                XCTFail("network-free diagnostic must not create a real credential store")
                return DiagnosticStore()
            })
        XCTAssertTrue(config.apiKey.isEmpty)
        XCTAssertTrue(config.openAIAPIKey.isEmpty)
        XCTAssertEqual(defaults.string(forKey: "typesafeAPIKey"), "legacy-diagnostic-sentinel")
    }

    private struct DiagnosticStore: APIKeyStore {
        func read() throws -> String? { nil }
        func save(_ apiKey: String) throws {}
        func delete() throws {}
    }

    func testAuditSettlementDoesNotPassOnFieldVisibilityAlone() {
        XCTAssertFalse(VoiceUserAudit.auditWorkSucceeded([
            (active: true, outcome: "pending", awaitingAnswer: false, awaitingApproval: false)
        ]))
        XCTAssertFalse(VoiceUserAudit.auditWorkSucceeded([
            (active: true, outcome: "done", awaitingAnswer: false, awaitingApproval: false)
        ]))
    }

    func testAuditSettlementRequiresOneSuccessfulUnaskedWork() {
        let done = (active: false, outcome: "done", awaitingAnswer: false, awaitingApproval: false)
        XCTAssertTrue(VoiceUserAudit.auditWorkSucceeded([done]))
        XCTAssertFalse(VoiceUserAudit.auditWorkSucceeded([]))
        XCTAssertFalse(VoiceUserAudit.auditWorkSucceeded([done, done]))
        XCTAssertFalse(VoiceUserAudit.auditWorkSucceeded([
            (active: false, outcome: "blocked", awaitingAnswer: false, awaitingApproval: false)
        ]))
        XCTAssertFalse(VoiceUserAudit.auditWorkSucceeded([
            (active: false, outcome: "done", awaitingAnswer: true, awaitingApproval: false)
        ]))
        XCTAssertFalse(VoiceUserAudit.auditWorkSucceeded([
            (active: false, outcome: "done", awaitingAnswer: false, awaitingApproval: true)
        ]))
    }
}
