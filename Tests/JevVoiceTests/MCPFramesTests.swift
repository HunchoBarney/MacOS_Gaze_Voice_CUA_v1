import XCTest
@testable import JevVoiceCore

final class MCPFramesTests: XCTestCase {
    func testSplitUnicodeAndMultipleMessages() throws {
        var frames = MCPFrames()
        let bytes = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"猫\"}\n{\"jsonrpc\":\"2.0\",\"method\":\"notification\"}\n".utf8)
        var values: [JSONValue] = []
        for byte in bytes { values += try frames.append(Data([byte])) }
        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(values[0]["result"], .string("猫"))
    }
    func testMalformedOrOversizeFailsClosed() throws {
        var frames = MCPFrames(limit: 32)
        XCTAssertThrowsError(try frames.append(Data(repeating: 65, count: 33)))
        frames = MCPFrames()
        XCTAssertThrowsError(try frames.append(Data("not-json\n".utf8)))
        frames = MCPFrames()
        XCTAssertThrowsError(try frames.append(Data("{\"id\":1}\n".utf8)))
    }
    func testNumbersCannotBecomeInvalidIDs() {
        XCTAssertNil(JSONValue.number(1.5).integer)
        XCTAssertNil(JSONValue.number(.infinity).integer)
        XCTAssertNil(JSONValue.number(1e30).integer)
        XCTAssertEqual(JSONValue.number(3).integer, 3)
    }
}
