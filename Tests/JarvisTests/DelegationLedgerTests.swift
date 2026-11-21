import XCTest
@testable import JarvisCore

final class DelegationLedgerTests: XCTestCase {
    private let key = DelegationKey(liveSessionID: "sess_1", delegationID: "del_1")

    func testADelegationIsAdmittedOnce() {
        var ledger = DelegationLedger()
        XCTAssertTrue(ledger.admit(key))
        XCTAssertFalse(ledger.admit(key))
        XCTAssertTrue(ledger.admit(DelegationKey(liveSessionID: "sess_2", delegationID: "del_1")),
                      "the key is the pair")
    }

    func testACommittedRequestIsNeverCommittedOrDeclinedAgain() {
        var ledger = DelegationLedger()
        let id = UUID()
        XCTAssertFalse(ledger.commit(key, request: id), "unseen")
        XCTAssertTrue(ledger.admit(key))
        XCTAssertTrue(ledger.commit(key, request: id))
        XCTAssertFalse(ledger.commit(key, request: UUID()))
        XCTAssertFalse(ledger.decline(key, reason: "late"))
        XCTAssertFalse(ledger.admit(key))
        XCTAssertEqual(ledger.state(of: key), .committed(id))
    }

    func testADeclinedDelegationStaysDeclined() {
        var ledger = DelegationLedger()
        XCTAssertTrue(ledger.admit(key))
        XCTAssertTrue(ledger.decline(key, reason: "barge-in"))
        XCTAssertFalse(ledger.commit(key, request: UUID()))
        XCTAssertEqual(ledger.state(of: key), .declined("barge-in"))
    }

    func testEachStretchOfWordsIsConsumedOnce() {
        var ledger = DelegationLedger()
        XCTAssertEqual(ledger.consume(session: "sess_1", through: 1200), 0)
        XCTAssertNil(ledger.consume(session: "sess_1", through: 1200))
        XCTAssertNil(ledger.consume(session: "sess_1", through: 900), "never goes back")
        XCTAssertEqual(ledger.consume(session: "sess_1", through: 2800), 1200)
        XCTAssertEqual(ledger.consume(session: "sess_2", through: 300), 0, "each session has its own clock")
        XCTAssertEqual(ledger.consumed(session: "sess_1"), 2800)
    }
}
