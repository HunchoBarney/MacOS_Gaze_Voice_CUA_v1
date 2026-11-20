import XCTest
@testable import Jarvis
import JarvisCore

/// KAR-69: where the app can take a press back, Jarvis presses and offers
/// undo instead of asking first. Everything else still asks, and the never
/// list and the password refusal are untouched.
@MainActor
final class UndoOfferTests: XCTestCase {

    private typealias Item = UndoRegistry.MenuItem
    private let finder = "com.apple.finder", mail = "com.apple.mail"

    private func route(_ label: String, in bundle: String?, tool: String = "click",
                       args: [String: JSONValue] = [:], mailDelay: TimeInterval? = 10) -> UndoRegistry.Route? {
        UndoRegistry.route(tool: tool, args: args, label: label, bundleID: bundle,
                           mailUndoSendDelay: { mailDelay })
    }

    // MARK: - Undoable categories

    func testFinderMoveToTrashIsPutBack() {
        XCTAssertEqual(route("Move to Trash", in: finder)?.kind, .putBack)
        XCTAssertEqual(route("Move to Trash", in: finder)?.offer,
                       "Moved to Trash. Say \u{201C}undo\u{201D} to bring it back.")
        XCTAssertNil(route("Delete", in: finder), "Finder's undoable delete is Move to Trash")
    }

    func testMailDeleteIsUndoable() {
        XCTAssertEqual(route("Delete", in: mail)?.kind, .delete)
        XCTAssertEqual(route("Move to Trash", in: mail)?.kind, .delete)
    }

    func testMailArchiveIsUndoable() {
        let archive = route("Archive", in: mail)
        XCTAssertEqual(archive?.kind, .archive)
        XCTAssertEqual(archive?.covers(.delete), false, "archive never asked, so it skips no question")
    }

    func testDeleteInADocumentIsUndoable() {
        for bundle in ["com.apple.Notes", "com.apple.TextEdit", "com.apple.iWork.Pages",
                       "com.apple.iWork.Numbers", "com.apple.iWork.Keynote"] {
            XCTAssertEqual(route("Delete", in: bundle)?.kind, .delete, bundle)
        }
    }

    func testMailSendIsUndoableInsideItsUndoSendDelay() {
        XCTAssertEqual(route("Send", in: mail), UndoRegistry.Route(kind: .unsend, deadline: 7))
        XCTAssertEqual(route("Send", in: mail, mailDelay: 30)?.deadline, 27)
        XCTAssertEqual(route("", in: mail, tool: "hotkey",
                             args: ["keys": .array([.string("cmd"), .string("return")])])?.kind, .unsend,
                       "⌘Return in Mail is the same send")
        XCTAssertNil(route("Send", in: mail, mailDelay: 0), "Undo Send off")
        XCTAssertNil(route("Send", in: mail, mailDelay: nil), "Mail's setting unreadable")
        XCTAssertNil(route("Send Later", in: mail))
    }

    // MARK: - Must still ask

    func testWhatNothingCanUndoHasNoRoute() {
        XCTAssertNil(route("Pay Now", in: mail), "pay")
        XCTAssertNil(route("Place your order", in: "com.apple.Safari"), "pay")
        XCTAssertNil(route("FaceTime", in: "com.apple.FaceTime"), "call")
        XCTAssertNil(route("Call", in: mail), "call")
        XCTAssertNil(route("Allow", in: finder), "permission")
        XCTAssertNil(route("Allow", in: "com.apple.UserNotificationCenter"), "permission")
        XCTAssertNil(route("Sign Out", in: mail), "account")
        XCTAssertNil(route("", in: finder), "unnamed")
        XCTAssertNil(route("Delete Immediately…", in: finder), "permanent delete")
        XCTAssertNil(route("Delete All", in: mail), "wholesale delete")
        XCTAssertNil(route("Erase Deleted Items", in: mail), "permanent delete")
        XCTAssertNil(route("Send", in: "com.apple.MobileSMS"), "a send outside Mail")
        XCTAssertNil(route("Move to Trash", in: "com.example.unknown"), "an app we don't know")
        XCTAssertNil(route("Move to Trash", in: nil), "no app")
    }

    func testPolicySkipsTheQuestionOnlyForAnUndoableDeleteOrSend() {
        let trash = route("Move to Trash", in: finder)
        XCTAssertEqual(CuaPolicy.decide(tool: "click", args: [:], elementText: "Move to Trash",
                                        standingGrant: true, undo: trash), .allow)
        XCTAssertEqual(CuaPolicy.decide(tool: "click", args: [:], elementText: "Move to Trash",
                                        standingGrant: true), .askFirst(.delete), "no route, still asks")
        guard case .needsConfirm = CuaPolicy.decide(tool: "click", args: [:], elementText: "Move to Trash",
                                                    standingGrant: false, undo: trash) else {
            return XCTFail("an undo route doesn't replace the computer-use grant")
        }
        let unsend = UndoRegistry.Route(kind: .unsend, deadline: 7)
        XCTAssertEqual(CuaPolicy.decide(tool: "click", args: [:], elementText: "Send",
                                        standingGrant: true, undo: unsend), .allow)
        for (label, consequence) in [("Pay Now", Consequence.pay), ("FaceTime", .call), ("Allow", .permission),
                                     ("Sign Out", .account), ("", .unnamed)] {
            for passed in [trash, unsend] {
                XCTAssertEqual(CuaPolicy.decide(tool: "click", args: [:], elementText: label,
                                                standingGrant: true, undo: passed), .askFirst(consequence),
                               "\(label) asks whatever route a caller passes")
            }
        }
    }

    /// Software Update and the Apple menu's confirm dialogs: nothing takes
    /// a restart back, so these always ask and never get an undo route.
    func testRestartsAlwaysAskAndAreNeverUndoable() {
        for label in ["Update Now", "Upgrade Now", "Restart Now", "Install and Restart", "Restart", "Shut Down"] {
            XCTAssertEqual(Consequence.classify(label), .restart, label)
            XCTAssertEqual(CuaPolicy.decide(tool: "click", args: [:], elementText: label, standingGrant: true),
                           .askFirst(.restart), "\(label) asks even under the standing grant")
            for bundle in ["com.apple.finder", "com.apple.mail", "com.apple.Notes", "com.apple.systempreferences"] {
                XCTAssertNil(route(label, in: bundle), "\(label) in \(bundle)")
            }
            for passed in [UndoRegistry.Route(kind: .putBack, deadline: nil), UndoRegistry.Route(kind: .unsend, deadline: 7)] {
                XCTAssertEqual(CuaPolicy.decide(tool: "click", args: [:], elementText: label, standingGrant: true,
                                                undo: passed), .askFirst(.restart), label)
            }
        }
        XCTAssertEqual(Consequence.classify("Log Out"), .account, "Log Out still asks, as an account change")
        XCTAssertFalse(Consequence.covers(goal: "just do it", control: "Update Now"))
        XCTAssertFalse(Consequence.covers(goal: "restart Safari", control: "Restart"),
                       "a restart button needs its exact name after a press verb")
        XCTAssertTrue(Consequence.covers(goal: "click Restart", control: "Restart"))
        XCTAssertTrue(Consequence.restart.question(target: "Update Now").contains("restarts or shuts down"))
    }

    func testRestartAsksInTheLoop() async throws {
        let script = Script([copyItem, trashItem])
        let loop = await makeLoop(script, offers: UndoOffers(), bundle: "com.apple.systempreferences")
        await loop.bindSpokenGoal("update my Mac, just do it")
        var confirmed = false
        _ = try await loop.dispatch("click", target, elementText: "Update Now", denied: [], confirmed: &confirmed)
        XCTAssertEqual(script.asks.value, 1)
    }

    /// Mail's Format button is formatting, not a deletion (JARA-36).
    func testFormatIsNotADelete() {
        XCTAssertNil(Consequence.classify("Format"))
        XCTAssertNotNil(CuaPolicy.neverReason(text: "Format Disk"), "formatting a disk stays on the never list")
    }

    /// A "show me how" goal asks to be taught: when Jarvis does a step after
    /// all, a consequential press asks first (JARA-36, #559).
    func testAShowMeHowGoalCoversNoPress() {
        for goal in ["show me how to send Linda a photo", "how do I send Linda a photo",
                     "walk me through sending Linda a photo", "teach me to delete that email"] {
            XCTAssertFalse(Consequence.covers(goal: goal, control: "Send"), goal)
            XCTAssertFalse(Consequence.covers(goal: goal, control: "Delete"), goal)
        }
        XCTAssertTrue(Consequence.covers(goal: "send Linda a photo", control: "Send"))
    }

    func testNeverListAndPasswordsStayRefused() {
        let trash = UndoRegistry.Route(kind: .putBack, deadline: nil)
        for label in ["Empty Trash", "Delete Permanently", "Download AnyDesk", "Buy Gift Card"] {
            guard case .deny = CuaPolicy.decide(tool: "click", args: [:], elementText: label,
                                                standingGrant: true, undo: trash) else { return XCTFail(label) }
        }
        guard case .deny = CuaPolicy.decide(tool: "browser_click", args: [:],
                                            elementText: "amazon.com href=https://amaz0n-refunds.top",
                                            standingGrant: true, undo: trash) else {
            return XCTFail("scam link")
        }
        guard case .deny(let why) = CuaPolicy.decide(tool: "type_text", args: ["text": .string("hunter2")],
                                                     elementText: "Password", standingGrant: true, undo: trash) else {
            return XCTFail("password box")
        }
        XCTAssertTrue(why.contains("passwords"), why)
    }

    // MARK: - The loop

    private final class Script: @unchecked Sendable {
        let items: LockedBox<[Item?]>
        let calls = LockedBox<[(String, [String: JSONValue])]>([])
        let asks = LockedBox<Int>(0)
        let now = LockedBox<Date>(Date(timeIntervalSince1970: 1_000_000))
        init(_ items: [Item?]) { self.items = LockedBox(items) }
        func nextItem() -> Item? {
            let queue = items.value
            guard let first = queue.first else { return nil }
            if queue.count > 1 { items.set(Array(queue.dropFirst())) }
            return first
        }
    }

    private func makeLoop(_ script: Script, offers: UndoOffers, ask: Bool = true, mailDelay: TimeInterval? = 10,
                          bundle: String = "com.apple.finder") async -> DriveLoop {
        let support = UndoSupport(undoItem: { _ in script.nextItem() }, mailUndoSendDelay: { mailDelay },
                                  offers: offers, now: { script.now.value }, settle: {})
        let loop = DriveLoop(call: { tool, args in
                                 script.calls.set(script.calls.value + [(tool, args)])
                                 return .object(["effect": .string("confirmed")])
                             },
                             choose: { _, _ in nil },
                             ask: ask ? { _ in script.asks.set(script.asks.value + 1); return "yes" } : nil,
                             granted: { true }, undo: support)
        await loop.bindConsentIdentity(name: "App", bundleID: bundle)
        return loop
    }

    private let target: [String: JSONValue] = ["pid": .number(4242), "window_id": .number(7)]
    private let copyItem = Item(menu: "Edit", title: "Undo Copy", enabled: true)
    private let trashItem = Item(menu: "Edit", title: "Undo Move of \u{201C}a.txt\u{201D}", enabled: true)

    func testJarvisTrashesWithoutAskingAndOffersUndo() async throws {
        let script = Script([copyItem, copyItem, trashItem])
        let offers = UndoOffers()
        let loop = await makeLoop(script, offers: offers)
        var confirmed = false
        _ = try await loop.dispatch("click", target, elementText: "Move to Trash", denied: [], confirmed: &confirmed)
        XCTAssertEqual(script.asks.value, 0, "no question before the press")
        XCTAssertEqual(script.calls.value.map(\.0), ["click"])
        let result = await loop.settle(.done, DriveTask(goal: "tidy my desktop"), [], confirmedAny: true)
        XCTAssertEqual(result.spoken, UndoRegistry.Route(kind: .putBack, deadline: nil).offer)
        XCTAssertEqual(VoiceTaskCoordinator.describe(result, request: "tidy my desktop").1, result.spoken)
        let pending = try XCTUnwrap(offers.current)
        XCTAssertEqual(pending.item, trashItem)
        XCTAssertEqual(pending.expiresAt, script.now.value.addingTimeInterval(10))
        XCTAssertNil(offers.take(now: script.now.value.addingTimeInterval(11)), "the window is 10 s")
    }

    func testAnOfferFollowsAReasonWhenTheTaskStopsShort() async throws {
        let script = Script([copyItem, trashItem])
        let loop = await makeLoop(script, offers: UndoOffers())
        var confirmed = false
        _ = try await loop.dispatch("click", target, elementText: "Move to Trash", denied: [], confirmed: &confirmed)
        let result = await loop.settle(.blocked("I couldn't find the next file."), DriveTask(goal: "x"), [])
        XCTAssertEqual(VoiceTaskCoordinator.describe(result, request: "x").1,
                       "I couldn't find the next file. " + UndoRegistry.Route(kind: .putBack, deadline: nil).offer)
    }

    func testOneUnaskedPressPerTask() async throws {
        let script = Script([copyItem, trashItem, trashItem])
        let loop = await makeLoop(script, offers: UndoOffers())
        var confirmed = false
        _ = try await loop.dispatch("click", target, elementText: "Move to Trash", denied: [], confirmed: &confirmed)
        _ = try await loop.dispatch("click", target, elementText: "Move to Trash", denied: [], confirmed: &confirmed)
        XCTAssertEqual(script.asks.value, 1, "a second trash in the same task asks")
    }

    func testAPressThatLeftNoOfferStillSpendsTheTasksUnaskedPress() async throws {
        let script = Script([trashItem])
        let offers = UndoOffers()
        let loop = await makeLoop(script, offers: offers)
        var confirmed = false
        _ = try await loop.dispatch("click", target, elementText: "Move to Trash", denied: [], confirmed: &confirmed)
        XCTAssertEqual(script.asks.value, 0)
        _ = try await loop.dispatch("click", target, elementText: "Move to Trash", denied: [], confirmed: &confirmed)
        XCTAssertEqual(script.asks.value, 1, "an unchanged undo item must not let every later delete skip its question")
        XCTAssertNil(offers.current)
    }

    func testNoNewUndoMeansNoOffer() async throws {
        let script = Script([copyItem])
        let offers = UndoOffers()
        let loop = await makeLoop(script, offers: offers)
        var confirmed = false
        _ = try await loop.dispatch("click", target, elementText: "Move to Trash", denied: [], confirmed: &confirmed)
        let result = await loop.settle(.done, DriveTask(goal: "x"), [], confirmedAny: true)
        XCTAssertNil(result.spoken)
        XCTAssertNil(offers.current)
    }

    func testAnAppWithNoUndoCommandAsks() async throws {
        let script = Script([nil])
        let loop = await makeLoop(script, offers: UndoOffers())
        var confirmed = false
        _ = try await loop.dispatch("click", target, elementText: "Move to Trash", denied: [], confirmed: &confirmed)
        XCTAssertEqual(script.asks.value, 1)
    }

    func testWithNobodyToHearTheOfferItStillRefuses() async {
        let loop = await makeLoop(Script([copyItem, trashItem]), offers: UndoOffers(), ask: false)
        var confirmed = false
        do {
            _ = try await loop.dispatch("click", target, elementText: "Move to Trash", denied: [], confirmed: &confirmed)
            XCTFail("an agent with nobody listening must not act without asking")
        } catch {}
    }

    func testTheirWordsStillPressWithNoOffer() async throws {
        let script = Script([copyItem, trashItem])
        let offers = UndoOffers()
        let loop = await makeLoop(script, offers: offers)
        await loop.bindSpokenGoal("move that file to trash")
        var confirmed = false
        _ = try await loop.dispatch("click", target, elementText: "Move to Trash", denied: [], confirmed: &confirmed)
        let result = await loop.settle(.done, DriveTask(goal: "x"), [], confirmedAny: true)
        XCTAssertEqual(script.asks.value, 0)
        XCTAssertNil(result.spoken, "they asked for it, so it's a plain done")
    }

    func testMailSendOffersUnsendInsideMailsDelay() async throws {
        let compose = Item(menu: "Edit", title: "Undo Typing", enabled: true)
        let sent = Item(menu: "Edit", title: "Undo Send", enabled: true)
        let script = Script([compose, sent])
        let offers = UndoOffers()
        let loop = await makeLoop(script, offers: offers, bundle: "com.apple.mail")
        var confirmed = false
        _ = try await loop.dispatch("click", target, elementText: "Send", denied: [], confirmed: &confirmed)
        XCTAssertEqual(script.asks.value, 0)
        let pressed = script.now.value
        script.now.set(pressed.addingTimeInterval(2))
        let result = await loop.settle(.done, DriveTask(goal: "x"), [], confirmedAny: true)
        XCTAssertEqual(result.spoken, "Sent. Say \u{201C}undo\u{201D} to unsend it.")
        XCTAssertEqual(offers.current?.expiresAt, pressed.addingTimeInterval(7),
                       "never past Mail's own delay, less time to say it")
    }

    func testMailSendAsksWhenUndoSendIsOff() async throws {
        let script = Script([copyItem, copyItem])
        let loop = await makeLoop(script, offers: UndoOffers(), mailDelay: 0, bundle: "com.apple.mail")
        var confirmed = false
        _ = try await loop.dispatch("click", target, elementText: "Send", denied: [], confirmed: &confirmed)
        XCTAssertEqual(script.asks.value, 1)
    }

    func testPayAndCallStillAskInTheLoop() async throws {
        for label in ["Pay Now", "FaceTime"] {
            let script = Script([copyItem, trashItem])
            let loop = await makeLoop(script, offers: UndoOffers(), bundle: "com.apple.mail")
            var confirmed = false
            _ = try await loop.dispatch("click", target, elementText: label, denied: [], confirmed: &confirmed)
            XCTAssertEqual(script.asks.value, 1, label)
        }
    }

    // MARK: - Saying "undo"

    func testUndoWordsAreTheFastLaneUndo() {
        for goal in ["undo", "undo that", "take that back", "put it back"] {
            XCTAssertTrue(DriveLoop.asksToUndo(goal), goal)
        }
        XCTAssertFalse(DriveLoop.asksToUndo("redo"))
        XCTAssertFalse(DriveLoop.asksToUndo("send it"))
    }

    private func offered(_ offers: UndoOffers, at now: Date) {
        offers.offer(PendingUndo(route: UndoRegistry.Route(kind: .putBack, deadline: nil), pid: 4242, windowID: 7,
                                 bundleID: finder, item: trashItem, pressedAt: now).offered(at: now))
    }

    func testUndoChoosesThatExactItemInThatApp() async throws {
        let script = Script([trashItem, Item(menu: "Edit", title: "Redo Move", enabled: true)])
        let offers = UndoOffers()
        offered(offers, at: script.now.value)
        let loop = await makeLoop(script, offers: offers)
        let result = await loop.run(DriveTask(goal: "undo"), session: "s")
        let menuCalls = script.calls.value.filter { $0.0 == "invoke_menu" }
        XCTAssertEqual(menuCalls.count, 1)
        XCTAssertEqual(menuCalls.first?.1["path"], .array([.string("Edit"), .string(trashItem.title)]))
        XCTAssertEqual(menuCalls.first?.1["pid"], .number(4242))
        XCTAssertEqual(result.status, .done)
        XCTAssertEqual(result.spoken, "Put it back.")
        XCTAssertNil(offers.current, "an offer runs once")
    }

    func testUndoRefusesWhenTheAppMovedOn() async {
        let script = Script([Item(menu: "Edit", title: "Undo Typing", enabled: true)])
        let offers = UndoOffers()
        offered(offers, at: script.now.value)
        let loop = await makeLoop(script, offers: offers)
        let result = await loop.run(DriveTask(goal: "undo"), session: "s")
        XCTAssertTrue(script.calls.value.isEmpty, "never undoes whatever happens to be on top")
        guard case .blocked(let why) = result.status else { return XCTFail("\(result.status)") }
        XCTAssertTrue(why.contains("changed since"), why)
    }

    func testUndoThatDidNotTakeIsNotCalledDone() async {
        let script = Script([trashItem])
        let offers = UndoOffers()
        offered(offers, at: script.now.value)
        let loop = await makeLoop(script, offers: offers)
        let result = await loop.run(DriveTask(goal: "undo"), session: "s")
        guard case .blocked = result.status else { return XCTFail("\(result.status)") }
        XCTAssertEqual(result.blockedReason, "undo unverified")
    }

    func testUndoWithNoReadbackIsNotCalledDone() async {
        let script = Script([trashItem, nil])
        let offers = UndoOffers()
        offered(offers, at: script.now.value)
        let loop = await makeLoop(script, offers: offers)
        let result = await loop.run(DriveTask(goal: "undo"), session: "s")
        XCTAssertEqual(script.calls.value.filter { $0.0 == "invoke_menu" }.count, 1)
        guard case .blocked = result.status else { return XCTFail("\(result.status)") }
        XCTAssertEqual(result.blockedReason, "undo unverified", "an unreadable menu is no evidence the undo took")
    }

    func testAnOfferNeverOutlivesItsWindow() {
        let offers = UndoOffers()
        let now = Date(timeIntervalSince1970: 5_000)
        offered(offers, at: now)
        XCTAssertNotNil(offers.current)
        XCTAssertNil(offers.take(now: now.addingTimeInterval(10)))
        XCTAssertNil(offers.current, "an expired offer is dropped")
    }
}
