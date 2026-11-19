import XCTest
@testable import JarvisCore

/// Contract: MCPFrames is the newline-delimited JSON-RPC reader every
/// driver transport shares — partial lines buffer, malformed lines and
/// oversized frames fail closed.
final class MCPFramesTests: XCTestCase {
    private func frame(_ id: Int) -> Data {
        Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":{}}\n".utf8)
    }

    func testCompleteLinesDecode() throws {
        var f = MCPFrames()
        let out = try f.append(frame(1) + frame(2))
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0]["id"]?.integer, 1)
        XCTAssertEqual(out[1]["id"]?.integer, 2)
    }

    func testPartialLineBuffersAcrossAppends() throws {
        var f = MCPFrames()
        let bytes = frame(9)
        XCTAssertEqual(try f.append(bytes.prefix(5)), [])
        let rest = bytes.dropFirst(5)
        let out = try f.append(Data(rest))
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0]["id"]?.integer, 9)
    }

    func testMalformedLineThrows() {
        var f = MCPFrames()
        XCTAssertThrowsError(try f.append(Data("not json\n".utf8))) {
            XCTAssertEqual($0 as? DriverConnectionError, .malformed)
        }
    }

    func testNonJSONRPCVersionThrows() {
        var f = MCPFrames()
        XCTAssertThrowsError(try f.append(Data("{\"id\":1}\n".utf8))) {
            XCTAssertEqual($0 as? DriverConnectionError, .malformed)
        }
    }

    func testOversizedBufferedDataThrows() {
        var f = MCPFrames(limit: 8)
        XCTAssertThrowsError(try f.append(Data("x".utf8) + Data(repeating: 120, count: 16)))
    }

    func testOversizedLineThrowsEvenBeforeNewline() {
        var f = MCPFrames(limit: 8)
        // 20 bytes buffered without a newline already exceeds the limit.
        XCTAssertThrowsError(try f.append(Data(repeating: 120, count: 20)))
    }
}
