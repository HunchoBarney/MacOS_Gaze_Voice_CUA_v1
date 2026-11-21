import XCTest
import JarvisCore
@testable import Jarvis

/// OS-focus and RPC protocol fixtures, not speech-model or physical proof.
@MainActor
final class FocusedTextTargetTests: XCTestCase {
    private let payload = "P3 focused literal"

    private func loop(current: LockedBox<Bool>, value: LockedBox<String?>,
                      calls: LockedBox<[[String: JSONValue]]>, factory: LockedBox<Bool>,
                      reply: JSONValue, changeValue: Bool = true,
                      hasTarget: Bool = true, lease: AsyncLease? = nil,
                      currentProbe: (@Sendable () async -> Bool)? = nil) -> DriveLoop {
        let text = payload
        return DriveLoop.inert(call: { tool, args in
            if tool == "list_windows" {
                return .object(["windows": .array([.object([
                    "window_id": .number(7), "pid": .number(42), "is_on_screen": .bool(true),
                    "title": .string("Owned"), "bounds": .object([
                        "x": .number(0), "y": .number(0), "width": .number(400), "height": .number(300)
                    ])
                ])])])
            }
            if tool == "get_window_state" {
                return .object(["elements": .array((1...3).map { index in
                    .object(["role": .string("AXTextField"), "element_index": .number(Double(index)),
                             "element_token": .string("fixture-\(index)")])
                })])
            }
            if tool == "type_text" {
                calls.set(calls.value + [args])
                if changeValue { value.set("before " + text) }
                return reply
            }
            return .object([:])
        }, choose: { _, _ in nil }, ask: nil, granted: { true },
        resolver: AppResolver.fixture(listApps: {
            [.init(name: "Chrome", bundle: "com.google.Chrome", pid: 42)]
        }), focusLease: lease, focusedTextTarget: { pid, window in
            XCTAssertEqual(pid, 42); XCTAssertEqual(window, 7)
            factory.set(true)
            guard hasTarget else { return nil }
            return FocusedTextBinding(label: "Owned field", isCurrent: currentProbe ?? { current.value },
                                      value: { value.value })
        }, activateApp: { _ in }, frontmostBundleID: { "com.google.Chrome" })
    }

    private var task: DriveTask {
        DriveTask(goal: "type \"\(payload)\"", application: "com.google.Chrome", pid: 42,
                  windowID: 7, values: ["text": payload])
    }

    private func directNativeLoop(calls: LockedBox<[String]>, focusCalls: LockedBox<Int>,
                                  current: LockedBox<Bool>, value: LockedBox<String?>,
                                  hasTarget: Bool = true, confirmed: Bool = true,
                                  available: (@Sendable () -> Bool)? = nil,
                                  frontmost: String? = nil, typedValue: String? = nil,
                                  selection: (@Sendable () async -> NSRange?)? = nil,
                                  nativeInsert: FocusedTextBinding.NativeInsert? = nil,
                                  windowSnapshot: (@Sendable () async -> FocusedTextBinding.WindowSnapshot?)? = nil,
                                  receipts: LockedBox<[FocusedTextBinding.Insertion]>? = nil,
                                  reply: JSONValue? = nil) -> DriveLoop {
        let text = payload
        return DriveLoop.inert(call: { tool, args in
            calls.set(calls.value + [tool])
            if tool == "list_windows" {
                return .object(["windows": .array([.object([
                    "pid": .number(42), "window_id": .number(7), "is_on_screen": .bool(true),
                    "title": .string("Owned"), "bounds": .object([
                        "x": .number(0), "y": .number(0), "width": .number(400), "height": .number(300)
                    ])
                ])])])
            }
            if tool == "type_text" {
                XCTAssertEqual(args["session"], .string("voice-direct"))
                XCTAssertEqual(args["delivery_mode"], .string("background"))
                XCTAssertEqual(args["window_id"], .number(7))
                XCTAssertNil(args["element_token"])
                value.set(typedValue ?? "before " + text)
                return reply ?? .object(["verified": .bool(confirmed), "effect": .string(confirmed ? "confirmed" : "unverifiable")])
            }
            throw DriverConnectionError.refused("Unexpected exploratory call: \(tool)")
        }, choose: { _, _ in
            calls.set(calls.value + ["model"])
            return nil
        }, ask: nil, granted: { true }, explicitConsent: true, directSession: "voice-direct",
        resolver: AppResolver.fixture(listApps: {
            [.init(name: "TextEdit", bundle: "com.apple.TextEdit", pid: 42)]
        }), focusedTextTarget: { pid, window in
            focusCalls.set(focusCalls.value + 1)
            XCTAssertEqual(pid, 42); XCTAssertEqual(window, 7)
            guard available?() ?? hasTarget else { return nil }
            return FocusedTextBinding(label: "Owned", isCurrent: { current.value },
                                      value: { value.value }, selection: selection,
                                      insertSelectedText: nativeInsert, windowSnapshot: windowSnapshot)
        }, nativeTextEvent: { receipt in
            receipts?.set((receipts?.value ?? []) + [receipt])
        }, frontmostBundleID: { frontmost })
    }

    func testNativeWindowObservationReplacesOnlyExactInventoryAndKeepsTitlePolicy() async {
        for variant in ["exact", "title_denied", "stale", "wrong_pid", "wrong_window", "off_screen"] {
            let calls = LockedBox<[String]>([]), captures = LockedBox(0), attempts = LockedBox(0)
            let current = LockedBox(true), value = LockedBox<String?>("before ")
            let literal = payload
            let native: FocusedTextBinding.NativeInsert = { text, _, _ in
                attempts.set(attempts.value + 1)
                value.set("before " + text)
                let now = ProcessInfo.processInfo.systemUptime
                return .init(succeeded: true, issuedAt: now, returnedAt: now)
            }
            let snapshot: @Sendable () async -> FocusedTextBinding.WindowSnapshot? = {
                if variant == "stale" { current.set(false) }
                return .init(pid: variant == "wrong_pid" ? 43 : 42,
                             windowID: variant == "wrong_window" ? 8 : 7,
                             title: variant == "title_denied" ? "ForbiddenWindow" : "Owned",
                             isOnScreen: variant != "off_screen")
            }
            let loop = directNativeLoop(calls: calls, focusCalls: captures, current: current, value: value,
                selection: { NSRange(location: 7, length: 0) }, nativeInsert: native, windowSnapshot: snapshot)
            let request = DriveTask(goal: "type \"\(literal)\"", application: "com.apple.TextEdit", pid: 42,
                windowID: 7, values: ["text": literal], deny: variant == "title_denied" ? ["ForbiddenWindow"] : [])
            let result = await loop.run(request, session: "voice")
            let rejected = ["title_denied", "stale"].contains(variant)
            if variant == "title_denied" {
                guard case .blockedByConsent(let reason) = result.status else {
                    XCTFail("Expected permanent title-policy refusal"); continue
                }
                XCTAssertTrue(reason.contains("ForbiddenWindow"))
            } else if rejected {
                guard case .blocked = result.status else { XCTFail("Expected blocked: \(variant)"); continue }
            } else {
                XCTAssertEqual(result.status, .done, variant)
            }
            XCTAssertEqual(attempts.value, rejected ? 0 : 1, variant)
            XCTAssertEqual(captures.value, 1, "Never recapture another field after a window wait: \(variant)")
            XCTAssertEqual(calls.value, ["wrong_pid", "wrong_window", "off_screen"].contains(variant)
                           ? ["list_windows"] : [], variant)
        }
    }

    func testMissingPrefetchedFieldCannotRetargetAfterInventoryWait() async {
        let calls = LockedBox<[String]>([]), captures = LockedBox(0), writes = LockedBox(0)
        let value = LockedBox<String?>("before ")
        let driver = directNativeLoop(calls: calls, focusCalls: captures, current: LockedBox(true),
            value: value, available: { captures.value > 1 },
            selection: { NSRange(location: 7, length: 0) },
            nativeInsert: { text, _, _ in
                writes.set(writes.value + 1)
                value.set("before " + text)
                return .init(succeeded: true, issuedAt: 1, returnedAt: 2)
            })
        let request = DriveTask(goal: "type \"\(payload)\"", application: "com.apple.TextEdit",
                                windowID: 7, values: ["text": payload])
        let result = await driver.run(request, session: "voice")
        if case .blocked = result.status {} else { XCTFail("A later field must not replace missing capture") }
        XCTAssertEqual(captures.value, 1)
        XCTAssertEqual(writes.value, 0)
        XCTAssertEqual(value.value, "before ")
        XCTAssertEqual(calls.value, ["list_windows"])
    }

    func testNativeInsertionNeverRepeatsAfterAnyAttemptAndProvesExactBytes() async {
        for variant in ["success", "unsupported", "uncertain", "no_effect", "wrong_bytes", "error"] {
            let calls = LockedBox<[String]>([]), captures = LockedBox(0), attempts = LockedBox(0)
            let value = LockedBox<String?>("before "), receipts = LockedBox<[FocusedTextBinding.Insertion]>([])
            let text = payload
            let native: FocusedTextBinding.NativeInsert = { actual, before, selection in
                XCTAssertEqual(actual, text)
                XCTAssertEqual(before, "before ")
                XCTAssertEqual(selection, NSRange(location: 7, length: 0))
                attempts.set(attempts.value + 1)
                if variant == "unsupported" { return nil }
                if variant == "error" { throw DriverConnectionError.refused("changed field") }
                if variant != "no_effect" {
                    value.set(variant == "wrong_bytes" ? "corrupted" : "before " + actual)
                }
                return .init(succeeded: variant != "uncertain", issuedAt: 1, returnedAt: 2)
            }
            let driver = directNativeLoop(calls: calls, focusCalls: captures, current: LockedBox(true),
                value: value, selection: { NSRange(location: 7, length: 0) },
                nativeInsert: native, receipts: receipts)
            let request = DriveTask(goal: "type \"\(payload)\"", application: "com.apple.TextEdit",
                                    windowID: 7, values: ["text": payload])
            let result = await driver.run(request, session: "voice")
            XCTAssertEqual(attempts.value, 1, variant)
            XCTAssertEqual(calls.value.filter { $0 == "type_text" }.count, variant == "unsupported" ? 1 : 0, variant)
            XCTAssertEqual(receipts.value.count, ["unsupported", "error"].contains(variant) ? 0 : 1, variant)
            if let receipt = receipts.value.first {
                XCTAssertEqual(receipt.issuedAt, 1)
                XCTAssertEqual(receipt.returnedAt, 2)
            }
            if ["success", "unsupported"].contains(variant) { XCTAssertEqual(result.status, .done, variant) }
            else { XCTAssertNotEqual(result.status, .done, variant) }
        }
    }

    func testNativeInsertionReplacesTheExactUTF16Selection() async {
        let calls = LockedBox<[String]>([]), captures = LockedBox(0)
        let original = "a\u{1F951}z", text = payload
        let value = LockedBox<String?>(original)
        let driver = directNativeLoop(calls: calls, focusCalls: captures, current: LockedBox(true),
            value: value, selection: { NSRange(location: 1, length: 2) },
            nativeInsert: { actual, before, selection in
                XCTAssertEqual(before, original)
                XCTAssertEqual(selection, NSRange(location: 1, length: 2))
                value.set("a" + actual + "z")
                return .init(succeeded: true, issuedAt: 1, returnedAt: 2)
            })
        let request = DriveTask(goal: "type \"\(text)\"", application: "com.apple.TextEdit",
                                windowID: 7, values: ["text": text])
        let result = await driver.run(request, session: "voice")
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(value.value, "a" + text + "z")
        XCTAssertFalse(calls.value.contains("type_text"))
    }

    func testCancelledOrStaleNativeTargetNeverCallsEitherInserter() async {
        for cancelled in [false, true] {
            let calls = LockedBox<[String]>([]), captures = LockedBox(0), attempts = LockedBox(0)
            let driver = directNativeLoop(calls: calls, focusCalls: captures,
                current: LockedBox(cancelled), value: LockedBox("before "),
                selection: { NSRange(location: 7, length: 0) }, nativeInsert: { _, _, _ in
                    attempts.set(attempts.value + 1)
                    return nil
                })
            let request = DriveTask(goal: "type \"\(payload)\"", application: "com.apple.TextEdit",
                                    windowID: 7, values: ["text": payload])
            let task = Task { await driver.run(request, session: "voice") }
            if cancelled { task.cancel() }
            let result = await task.value
            XCTAssertNotEqual(result.status, .done)
            XCTAssertEqual(attempts.value, 0)
            XCTAssertFalse(calls.value.contains("type_text"))
        }
    }

    func testDirectNativeLiteralUsesCapturedAppAndFocusWithoutSnapshotOrModel() async {
        for frontmost in [nil, "fixture.other"] {
            let calls = LockedBox<[String]>([]), captures = LockedBox(0)
            let current = LockedBox(true), value = LockedBox<String?>("before ")
            let driver = directNativeLoop(calls: calls, focusCalls: captures, current: current,
                                          value: value, frontmost: frontmost)
            let request = DriveTask(goal: "type \"\(payload)\"", application: "com.apple.TextEdit",
                                    windowID: 7, values: ["text": payload])
            let result = await driver.run(request, session: "voice")
            XCTAssertEqual(result.status, .done)
            XCTAssertEqual(captures.value, 1)
            XCTAssertEqual(calls.value, ["list_windows", "type_text"])
        }
    }

    func testDirectNativeLiteralWithoutCapturedWindowCannotRetargetFocusedField() async {
        let calls = LockedBox<[String]>([]), captures = LockedBox(0)
        let driver = directNativeLoop(calls: calls, focusCalls: captures, current: LockedBox(true),
                                      value: LockedBox("before "), frontmost: "com.apple.TextEdit")
        let request = DriveTask(goal: "type \"\(payload)\"", application: "com.apple.TextEdit",
                                values: ["text": payload])
        let result = await driver.run(request, session: "voice")
        guard case .blocked = result.status else { return XCTFail("Missing capture must block") }
        XCTAssertEqual(captures.value, 0)
        XCTAssertTrue(calls.value.isEmpty)
    }

    func testDirectNativeLiteralMissingOrStaleFocusNeverFallsBackToPress() async {
        for hasTarget in [false, true] {
            let calls = LockedBox<[String]>([]), captures = LockedBox(0)
            let driver = directNativeLoop(calls: calls, focusCalls: captures, current: LockedBox(false),
                                          value: LockedBox("before "), hasTarget: hasTarget)
            let request = DriveTask(goal: "type \"\(payload)\"", application: "com.apple.TextEdit",
                                    windowID: 7, values: ["text": payload])
            let result = await driver.run(request, session: "voice")
            guard case .blocked = result.status else { return XCTFail("Missing or stale focus must block") }
            XCTAssertEqual(calls.value, ["list_windows"])
        }
    }

    func testDirectNativeLiteralMissingValueNeverSendsUnverifiableText() async {
        let calls = LockedBox<[String]>([]), captures = LockedBox(0)
        let driver = directNativeLoop(calls: calls, focusCalls: captures, current: LockedBox(true),
                                      value: LockedBox(nil))
        let request = DriveTask(goal: "type \"\(payload)\"", application: "com.apple.TextEdit",
                                windowID: 7, values: ["text": payload])
        let result = await driver.run(request, session: "voice")
        guard case .blocked = result.status else { return XCTFail("Unreadable focused value must block") }
        XCTAssertEqual(calls.value, ["list_windows"])
    }

    func testDirectNativeLiteralChecksExactSelectedRangeReplacement() async {
        for after in ["before \(payload)", "before \(payload) corrupted", "before \(payload.uppercased())"] {
            let calls = LockedBox<[String]>([]), captures = LockedBox(0)
            let driver = directNativeLoop(calls: calls, focusCalls: captures, current: LockedBox(true),
                value: LockedBox("before selected"), typedValue: after,
                selection: { NSRange(location: 7, length: 8) })
            let request = DriveTask(goal: "type \"\(payload)\"", application: "com.apple.TextEdit",
                                    windowID: 7, values: ["text": payload])
            let result = await driver.run(request, session: "voice")
            if after == "before \(payload)" {
                XCTAssertEqual(result.status, .done)
            } else {
                guard case .blocked = result.status else { return XCTFail("A substring is not exact insertion proof") }
            }
            XCTAssertEqual(calls.value, ["list_windows", "type_text"])
        }
    }

    func testDirectNativeLiteralInvalidOrMissingSelectionCannotDispatch() async {
        for range: NSRange? in [nil, NSRange(location: NSNotFound, length: 0), NSRange(location: 50, length: 0)] {
            let calls = LockedBox<[String]>([]), captures = LockedBox(0)
            let driver = directNativeLoop(calls: calls, focusCalls: captures, current: LockedBox(true),
                value: LockedBox("before "), selection: { range })
            let request = DriveTask(goal: "type \"\(payload)\"", application: "com.apple.TextEdit",
                                    windowID: 7, values: ["text": payload])
            let result = await driver.run(request, session: "voice")
            guard case .blocked = result.status else { return XCTFail("Unknown selection cannot dispatch") }
            XCTAssertEqual(calls.value, ["list_windows"])
        }
    }

    private var canonicalNativeReceipt: [String: JSONValue] {
        ["effect": .string("confirmed"), "route": .string("accessibility"),
         "delivery": .object(["mode": .string("background")]),
         "evidence": .array([.object(["kind": .string("value_readback")])]),
         "summary": .string("Text inserted")]
    }

    func testCanonicalNativeReceiptUsesExactFocusedReadbackWithoutLegacyVerifiedFlag() async {
        let calls = LockedBox<[String]>([]), captures = LockedBox(0)
        let driver = directNativeLoop(calls: calls, focusCalls: captures, current: LockedBox(true),
            value: LockedBox("before "), selection: { NSRange(location: 7, length: 0) },
            reply: .object(canonicalNativeReceipt))
        let request = DriveTask(goal: "type \"\(payload)\"", application: "com.apple.TextEdit",
                                windowID: 7, values: ["text": payload])
        let result = await driver.run(request, session: "voice")
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(result.dispatchedEffect)
        XCTAssertEqual(calls.value, ["list_windows", "type_text"])
    }

    func testCanonicalNativeReceiptCannotOverrideFalseUncertainOrMissingExactProof() async {
        for variant in ["false", "unverifiable", "partial", "refused", "unknown", "missing_delivery",
                        "missing_evidence", "empty_evidence", "wrong_route", "missing_summary",
                        "missing_selection", "wrong_value"] {
            var receipt = canonicalNativeReceipt
            switch variant {
            case "false": receipt["verified"] = .bool(false)
            case "unverifiable": receipt["effect"] = .string("unverifiable")
            case "partial": receipt["status"] = .string("partial")
            case "refused": receipt["refusal"] = .object(["code": .string("fixture_refusal")])
            case "unknown": receipt["execution_state"] = .string("unknown")
            case "missing_delivery": receipt.removeValue(forKey: "delivery")
            case "missing_evidence": receipt.removeValue(forKey: "evidence")
            case "empty_evidence": receipt["evidence"] = .array([])
            case "wrong_route": receipt["route"] = .string("keyboard")
            case "missing_summary": receipt.removeValue(forKey: "summary")
            default: break
            }
            let calls = LockedBox<[String]>([]), captures = LockedBox(0)
            let selection: (@Sendable () async -> NSRange?)? =
                variant == "missing_selection" ? nil : { NSRange(location: 7, length: 0) }
            let driver = directNativeLoop(calls: calls, focusCalls: captures, current: LockedBox(true),
                value: LockedBox("before "), typedValue: variant == "wrong_value" ? "corrupted \(payload)" : nil,
                selection: selection, reply: .object(receipt))
            let request = DriveTask(goal: "type \"\(payload)\"", application: "com.apple.TextEdit",
                                    windowID: 7, values: ["text": payload])
            let result = await driver.run(request, session: "voice")
            guard case .blocked = result.status else { return XCTFail("\(variant) cannot become Done") }
            XCTAssertFalse(result.dispatchedEffect)
            XCTAssertEqual(calls.value, ["list_windows", "type_text"], variant)
        }
    }

    func testBrowserCannotUseCanonicalNativeReceiptToConfirmWebAXEcho() async {
        let calls = LockedBox<[[String: JSONValue]]>([]), factory = LockedBox(false)
        let driver = loop(current: LockedBox(true), value: LockedBox("before "),
                          calls: calls, factory: factory, reply: .object(canonicalNativeReceipt))
        let result = await driver.run(task, session: "browser")
        guard case .blocked = result.status else { return XCTFail("Web echo is not renderer proof") }
        XCTAssertEqual(calls.value.count, 1)
        XCTAssertFalse(result.dispatchedEffect)
    }

    func testFocusedLiteralUsesOneForegroundWindowMutationAndExactReadback() async {
        let current = LockedBox(true), value = LockedBox<String?>("before")
        let calls = LockedBox<[[String: JSONValue]]>([]), factory = LockedBox(false)
        let driver = loop(current: current, value: value, calls: calls, factory: factory,
                          reply: .object(["verified": .bool(true), "effect": .string("confirmed")]))
        let result = await driver.run(task, session: "focused-owned")
        XCTAssertEqual(result.status, .done)
        XCTAssertTrue(result.dispatchedEffect)
        XCTAssertEqual(calls.value.count, 1)
        XCTAssertEqual(calls.value.first?["delivery_mode"], .string("foreground"))
        XCTAssertEqual(calls.value.first?["window_id"], .number(7))
        XCTAssertEqual(calls.value.first?["text"], .string(payload))
        XCTAssertNil(calls.value.first?["element_token"])
    }

    func testWebAXEchoAndMissingReadbackCannotBecomeDoneOrRetry() async {
        for verified in [false, true] {
            let current = LockedBox(true), value = LockedBox<String?>("before")
            let calls = LockedBox<[[String: JSONValue]]>([]), factory = LockedBox(false)
            let driver = loop(current: current, value: value, calls: calls, factory: factory,
                              reply: .object(["verified": .bool(verified),
                                              "effect": .string(verified ? "confirmed" : "unverifiable")]),
                              changeValue: !verified)
            let result = await driver.run(task, session: "unverified-owned")
            guard case .blocked = result.status else { return XCTFail("Unverified delivery cannot be Done") }
            XCTAssertFalse(result.dispatchedEffect)
            XCTAssertEqual(calls.value.count, 1)
            let (outcome, say) = VoiceTaskCoordinator.describe(result, request: task.goal)
            XCTAssertNotEqual(outcome, .done)
            XCTAssertTrue(say.contains("sent"))
        }
    }

    func testMissingOrStaleFocusedFieldNeverTypes() async {
        for available in [false, true] {
            let current = LockedBox(false), value = LockedBox<String?>("before")
            let calls = LockedBox<[[String: JSONValue]]>([]), factory = LockedBox(false)
            let driver = loop(current: current, value: value, calls: calls, factory: factory,
                              reply: .object([:]), hasTarget: available)
            let result = await driver.run(task, session: "no-focus")
            XCTAssertNotEqual(result.status, .done)
            XCTAssertTrue(calls.value.isEmpty)
        }
    }

    func testLeaseWaitRevalidatesFocusAndCancellationBeforeTyping() async {
        for cancelled in [false, true] {
            let current = LockedBox(true), value = LockedBox<String?>("before")
            let calls = LockedBox<[[String: JSONValue]]>([]), factory = LockedBox(false)
            let lease = AsyncLease()
            await lease.acquire()
            let driver = loop(current: current, value: value, calls: calls, factory: factory,
                              reply: .object([:]), lease: lease)
            let request = task
            let run = Task { await driver.run(request, session: "lease-focus") }
            for _ in 0..<150 {
                if factory.value { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(factory.value)
            if cancelled { run.cancel() } else { current.set(false) }
            await lease.release()
            let result = await run.value
            XCTAssertNotEqual(result.status, .done)
            XCTAssertTrue(calls.value.isEmpty)
        }
    }

    func testInvalidNativeIdentityFailsClosedWithoutAXTargetGuessing() async {
        let invalid = await FocusedTextBinding.capture(pid: -1, windowID: -1)
        XCTAssertNil(invalid)
        let invalidWindow = await FocusedTextBinding.focusedWindowID(pid: -1)
        XCTAssertNil(invalidWindow)
        XCTAssertNil(FocusedTextBinding.capturedWindowID(pid: 0))
        XCTAssertNil(FocusedTextBinding.capturedWindowID(pid: -1))
        XCTAssertNil(FocusedTextBinding.capturedWindowID(pid: Int.max))
    }

    func testCancellationDuringLastFocusValidationCannotDispatch() async {
        let current = LockedBox(true), value = LockedBox<String?>("before")
        let calls = LockedBox<[[String: JSONValue]]>([]), factory = LockedBox(false)
        let checks = LockedBox(0)
        let waiter = LockedBox<CheckedContinuation<Bool, Never>?>(nil)
        let driver = loop(current: current, value: value, calls: calls, factory: factory,
                          reply: .object([:]), currentProbe: {
            checks.set(checks.value + 1)
            if checks.value == 2 {
                return await withCheckedContinuation { waiter.set($0) }
            }
            return true
        })
        let request = task
        let run = Task { await driver.run(request, session: "cancel-validation") }
        for _ in 0..<150 {
            if waiter.value != nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(waiter.value)
        run.cancel()
        waiter.value?.resume(returning: true)
        let result = await run.value
        XCTAssertEqual(result.status, .cancelled)
        XCTAssertTrue(calls.value.isEmpty)
    }

    func testFocusedRoleGuardRejectsSecureSubrolesDisabledAndReadOnlyFields() {
        XCTAssertTrue(FocusedTextBinding.accepts(role: "AXTextField", subrole: nil, enabled: true, readOnly: false))
        XCTAssertFalse(FocusedTextBinding.accepts(role: "AXTextField", subrole: "AXSecureTextField", enabled: true, readOnly: false))
        XCTAssertFalse(FocusedTextBinding.accepts(role: "AXButton", subrole: nil, enabled: true, readOnly: false))
        XCTAssertFalse(FocusedTextBinding.accepts(role: "AXTextArea", subrole: nil, enabled: false, readOnly: false))
        XCTAssertFalse(FocusedTextBinding.accepts(role: "AXTextArea", subrole: nil, enabled: true, readOnly: true))
    }
}
