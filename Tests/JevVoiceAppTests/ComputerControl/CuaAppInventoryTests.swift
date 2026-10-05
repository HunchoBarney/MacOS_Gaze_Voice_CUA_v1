import XCTest
import JevVoiceCore
@testable import JevVoice

@MainActor
final class CuaAppInventoryTests: XCTestCase {
    /// The inventory shapes a list_apps response — it caches nothing, so
    /// every read is a fresh fetch and advisory pid/running hints pass
    /// through. Dispatch authority stays with fresh driver observations.
    func testShapesEachFetchWithoutCaching() async throws {
        let inventory = CuaAppInventory()
        var reads = 0
        func fetch() async throws -> JSONValue {
            reads += 1
            return .object(["apps": .array([.object(["name": .string("Fixture"), "bundle_id": .string("fixture"), "pid": .number(Double(reads)), "running": .bool(true)])])])
        }
        let first = try await inventory.read(fetch: fetch)
        let second = try await inventory.read(fetch: fetch)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(first["apps"]?.array?.first?["pid"], .number(1))
        XCTAssertEqual(second["apps"]?.array?.first?["pid"], .number(2))
        XCTAssertEqual(second["apps"]?.array?.first?["running"], .bool(true))
    }

    /// Rows without a name or bundle id are unaddressable — they drop
    /// rather than polluting the roster with entries nothing can resolve.
    func testUnnameableRowsAreDropped() async throws {
        let inventory = CuaAppInventory()
        let result = try await inventory.read {
            .object(["apps": .array([
                .object(["bundle_id": .string("no.name")]),
                .object(["name": .string("NoBundle")]),
                .object(["name": .string("Good"), "bundle_id": .string("test.good")])
            ])])
        }
        XCTAssertEqual(result["apps"]?.array?.count, 1)
        XCTAssertEqual(result["apps"]?.array?.first?["name"], .string("Good"))
    }

    /// A malformed list_apps response fails loudly — silently returning an
    /// empty roster would route every "open X" to a dead end.
    func testMalformedResponseThrows() async throws {
        let inventory = CuaAppInventory()
        do {
            _ = try await inventory.read { .object([:]) }
            XCTFail("a response with no apps array must throw")
        } catch {
            XCTAssertTrue(error is DriverConnectionError)
        }
    }
}
