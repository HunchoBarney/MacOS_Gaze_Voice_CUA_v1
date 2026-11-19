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

    func testLegacyAndModernNoninteractiveKeychainPoliciesAreBothApplied() {
        let policy = KeychainAPIKeyStore.authenticationPolicy(allowUserInteraction: false)
        XCTAssertEqual(policy[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIFail as String)
        XCTAssertTrue((policy[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
        XCTAssertTrue(KeychainAPIKeyStore.authenticationPolicy(allowUserInteraction: true).isEmpty)
    }
}
