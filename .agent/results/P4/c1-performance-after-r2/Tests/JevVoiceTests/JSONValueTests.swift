import XCTest
@testable import JevVoiceCore

/// Contract: every driver/tool payload passes through JSONValue — its
/// accessors and wire coding are the shape the whole app reads.
final class JSONValueTests: XCTestCase {
    func testScalarAccessors() {
        XCTAssertEqual(JSONValue.string("a").string, "a")
        XCTAssertEqual(JSONValue.number(7).integer, 7)
        XCTAssertNil(JSONValue.number(2.5).integer)          // non-integral refuses
        XCTAssertNil(JSONValue.number(.infinity).integer)    // non-finite refuses
        XCTAssertEqual(JSONValue.bool(true).bool, true)
        XCTAssertNil(JSONValue.number(1).string)
        XCTAssertNil(JSONValue.string("x").bool)
    }

    func testObjectSubscriptAndNestedAccess() {
        let value: JSONValue = .object(["a": .object(["b": .number(3)])])
        XCTAssertEqual(value["a"]?["b"]?.integer, 3)
        XCTAssertNil(value["missing"])
        XCTAssertNil(value["a"]?["missing"]?.string)
        // Subscripting a non-object yields nil, never traps.
        XCTAssertNil(JSONValue.number(1)["a"])
    }

    func testArrayAccess() {
        let value: JSONValue = .array([.string("x"), .number(2)])
        XCTAssertEqual(value.array?.count, 2)
        XCTAssertNil(JSONValue.object([:]).array)
    }

    func testCodableRoundTrip() throws {
        let original: JSONValue = .object([
            "s": .string("hi"), "n": .number(-4.25), "b": .bool(false),
            "null": .null, "arr": .array([.number(1), .string("two")]),
            "obj": .object(["k": .string("v")]),
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    /// Ints on the wire decode as Double — `integer` is exact-only, so a
    /// drifted 3.0 reads as 3 but 3.5 refuses.
    func testNumericBoundary() {
        let decoded = try? JSONDecoder().decode(JSONValue.self,
                                                from: Data("{\"i\":3}".utf8))
        XCTAssertEqual(decoded?["i"]?.integer, 3)
    }
}
