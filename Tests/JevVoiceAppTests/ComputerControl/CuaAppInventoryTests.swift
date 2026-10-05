import XCTest
import JevVoiceCore
@testable import JevVoice

@MainActor
final class CuaAppInventoryTests: XCTestCase {
    func testCachesNamesAndAdvisoryRuntimeHintsAndRefreshesAfterExpiry() async throws {
        // pid/running ride in the cache as advisory hints for fast-lane
        // ambiguity resolution only; dispatch authority always re-verifies
        // against a fresh driver snapshot.
        let inventory = CuaAppInventory()
        var reads = 0
        func fetch() async throws -> JSONValue {
            reads += 1
            return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture"), "pid": .number(Double(reads)), "running": .bool(true)])])])
        }
        let first = try await inventory.read(now: 0, fetch: fetch)
        let warm = try await inventory.read(now: 59, fetch: fetch)
        XCTAssertEqual(first, warm); XCTAssertEqual(reads, 1)
        XCTAssertEqual(warm["apps"]?.array?.first?["pid"], .number(1))
        XCTAssertEqual(warm["apps"]?.array?.first?["running"], .bool(true))
        _ = try await inventory.read(now: 60, fetch: fetch)
        XCTAssertEqual(reads, 2)
    }
}
