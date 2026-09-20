import XCTest
import JevVoiceCore
@testable import JevVoice

final class CuaVisualObservationTests: XCTestCase {
    private func fixture() -> JSONValue {
        .object([
            "schema": .string("cua.visual_regions_v1"),
            "capture": .object([
                "capture_id": .string("capture-a"),
                "source": .object(["kind": .string("window"), "pid": .number(12), "window_id": .number(34)]),
                "screenshot": .object(["reference": .string("immutable-png"), "width": .number(800), "height": .number(600), "mime_type": .string("image/png")]),
                "action_coordinate_space": .object(["kind": .string("affine"), "m11": .number(0.5), "m12": .number(0), "m21": .number(0), "m22": .number(0.5), "tx": .number(-1000), "ty": .number(200)])
            ]),
            "regions": .array([.object([
                "id": .string("text-1"), "kind": .string("text"), "text": .string("Continue"),
                "confidence": .number(0.95), "interactive": .bool(false),
                "bounds": .object(["x": .number(101), "y": .number(50), "width": .number(21), "height": .number(30)])
            ])])
        ])
    }

    func testOCRActionRetainsCaptureAndUnroundedScreenshotCoordinates() throws {
        let observation = try CuaVisualObservation(fixture(), captureID: "capture-a", pid: 12, window: 34)
        XCTAssertEqual(observation.actions.count, 1)
        let args = try XCTUnwrap(observation.actions.first?.arguments)
        XCTAssertEqual(args["x"], .number(111.5))
        XCTAssertEqual(args["y"], .number(65))
        XCTAssertEqual(args["capture_id"], .string("capture-a"))
        XCTAssertEqual(args["window_id"], .number(34))
    }

    func testWrongCaptureOrWindowIsRejected() {
        XCTAssertThrowsError(try CuaVisualObservation(fixture(), captureID: "old", pid: 12, window: 34))
        XCTAssertThrowsError(try CuaVisualObservation(fixture(), captureID: "capture-a", pid: 12, window: 35))
        XCTAssertThrowsError(try CuaVisualObservation(fixture(), captureID: "capture-a", pid: 13, window: 34))
    }

    func testOutOfBoundsAndDuplicateRegionsAreRejected() throws {
        var output = try XCTUnwrap(fixture().object)
        var regions = try XCTUnwrap(output["regions"]?.array)
        regions.append(regions[0])
        output["regions"] = .array(regions)
        XCTAssertThrowsError(try CuaVisualObservation(.object(output), captureID: "capture-a", pid: 12, window: 34))
        var region = try XCTUnwrap(regions[0].object)
        region["bounds"] = .object(["x": .number(799), "y": .number(50), "width": .number(21), "height": .number(30)])
        output["regions"] = .array([.object(region)])
        XCTAssertThrowsError(try CuaVisualObservation(.object(output), captureID: "capture-a", pid: 12, window: 34))
    }
}
