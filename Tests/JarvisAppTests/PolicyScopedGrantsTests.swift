import XCTest
@testable import Jarvis
import JarvisCore

/// Contract for scoped "Always for this app" grants: they persist in
/// policy.json beside the standing grant, they match on the exact
/// (actionKind × appBundleID) pair — a grant for app A never leaks to
/// app B or to another action — and they survive the standing-grant
/// toggle republishing the file.
final class PolicyScopedGrantsTests: XCTestCase {
    private var dir: URL!
    private var file: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("policy-\(UUID().uuidString)", isDirectory: true)
        file = dir.appendingPathComponent("policy.json")
        CuaPolicy.policyFileOverride = file
    }

    override func tearDown() {
        CuaPolicy.policyFileOverride = nil
        try? FileManager.default.removeItem(at: dir)
    }

    /// The consent file fails closed: a file without a `standingGrant`
    /// field, or one that doesn't parse, grants nothing.
    func testAPolicyFileWithoutTheGrantFieldGrantsNothing() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"version":2,"scopedGrants":[]}"#.utf8).write(to: file)
        XCTAssertFalse(CuaPolicy.readPolicyState().standingGrant)
        try Data("not json".utf8).write(to: file)
        XCTAssertFalse(CuaPolicy.readPolicyState().standingGrant)
        XCTAssertTrue(CuaPolicy.readPolicyState().scopedGrants.isEmpty)
    }

    /// grant → allows → revoke → no longer allows. Persisted through the
    /// file, so a second read path (the child process's posture) sees it.
    func testGrantPersistsAndRevokes() {
        CuaPolicy.grantAlways(actionKind: "click", appBundleID: "com.test.Safari")
        XCTAssertTrue(CuaPolicy.scopedGrantAllows(actionKind: "click",
                                                  appBundleID: "com.test.Safari"))
        XCTAssertEqual(CuaPolicy.scopedGrants().count, 1)

        // The row is really on disk in policy.json — no side channel.
        let onDisk = try? JSONDecoder().decode(
            JSONValue.self, from: Data(contentsOf: file))
        XCTAssertEqual(onDisk?["standingGrant"]?.bool, false)
        XCTAssertEqual(onDisk?["scopedGrants"]?.array?.first?["action"]?.string,
                       "click")
        XCTAssertEqual(onDisk?["scopedGrants"]?.array?.first?["bundle"]?.string,
                       "com.test.Safari")

        CuaPolicy.revokeAlways(actionKind: "click", appBundleID: "com.test.Safari")
        XCTAssertFalse(CuaPolicy.scopedGrantAllows(actionKind: "click",
                                                   appBundleID: "com.test.Safari"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                       "standing grant off + no scopes = file removed")
    }

    /// Scope is the pair, not the parts: app A's grant never answers for
    /// app B, and "click" never answers for "type_text".
    func testScopeMatchingDoesNotLeak() {
        CuaPolicy.grantAlways(actionKind: "click", appBundleID: "com.test.A")
        XCTAssertTrue(CuaPolicy.scopedGrantAllows(actionKind: "click",
                                                  appBundleID: "com.test.A"))
        XCTAssertFalse(CuaPolicy.scopedGrantAllows(actionKind: "click",
                                                   appBundleID: "com.test.B"),
                       "a grant for app A must not authorize app B")
        XCTAssertFalse(CuaPolicy.scopedGrantAllows(actionKind: "type_text",
                                                   appBundleID: "com.test.A"),
                       "a click grant must not authorize typing")
    }

    /// Matching is normalized — case and padding can't split the pair.
    func testScopeMatchingIsNormalized() {
        CuaPolicy.grantAlways(actionKind: "Click", appBundleID: "COM.TEST.A")
        XCTAssertTrue(CuaPolicy.scopedGrantAllows(actionKind: " click ",
                                                  appBundleID: "com.test.a "))
    }

    /// Duplicate "always" answers don't pile up rows.
    func testGrantDedupes() {
        CuaPolicy.grantAlways(actionKind: "click", appBundleID: "com.test.A")
        CuaPolicy.grantAlways(actionKind: "click", appBundleID: "com.test.A")
        XCTAssertEqual(CuaPolicy.scopedGrants().count, 1)
    }

    /// Republishing the standing grant — the app toggling computer use —
    /// preserves persisted scopes, and a grant write preserves the
    /// standing flag.
    func testStandingGrantTogglePreservesScopes() {
        CuaPolicy.grantAlways(actionKind: "click", appBundleID: "com.test.A")
        CuaPolicy.publishStateFile(standingGrant: false)
        XCTAssertTrue(CuaPolicy.scopedGrantAllows(actionKind: "click",
                                                  appBundleID: "com.test.A"),
                      "revoking the blanket grant keeps scoped grants")
        CuaPolicy.publishStateFile(standingGrant: true)
        XCTAssertTrue(CuaPolicy.scopedGrantAllows(actionKind: "click",
                                                  appBundleID: "com.test.A"))
        let onDisk = try? JSONDecoder().decode(
            JSONValue.self, from: Data(contentsOf: file))
        XCTAssertEqual(onDisk?["standingGrant"]?.bool, true)
    }

    /// Standing grant off + zero grants = the honest absent file.
    func testEmptyOffStateDeletesFile() {
        CuaPolicy.publishStateFile(standingGrant: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// A scoped grant in `decide` allows like the standing grant — and
    /// still loses to the deny list.
    func testDecideScopedGrant() {
        XCTAssertEqual(
            CuaPolicy.decide(tool: "click", args: [:], elementText: "Save File",
                             standingGrant: false, scopedGrant: true),
            .allow)
        guard case .deny = CuaPolicy.decide(
            tool: "click", args: [:], elementText: "Empty Trash",
            standingGrant: false, scopedGrant: true) else {
            return XCTFail("deny precedes even a scoped grant")
        }
        guard case .needsConfirm = CuaPolicy.decide(
            tool: "click", args: [:], elementText: "Save File",
            standingGrant: false, scopedGrant: false) else {
            return XCTFail("no grant at all still confirms")
        }
    }
}
