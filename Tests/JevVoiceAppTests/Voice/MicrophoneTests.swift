import XCTest
@testable import JevVoice

@MainActor
final class MicrophoneTests: XCTestCase {
    private let devices = [MicrophoneDevice(hardwareID: 10, uid: "builtin", name: "MacBook microphone"),
                           MicrophoneDevice(hardwareID: 20, uid: "headset", name: "Headset")]
    func testExplicitInputStaysSelectedWhenSystemDefaultChanges() throws {
        XCTAssertEqual(try MicrophoneCatalog.resolve(uid: "builtin", devices: devices, defaultID: 20).hardwareID, 10)
        XCTAssertEqual(try MicrophoneCatalog.resolve(uid: "", devices: devices, defaultID: 20).hardwareID, 20)
    }
    func testMissingExplicitInputDoesNotFallBackToAnotherMicrophone() {
        XCTAssertThrowsError(try MicrophoneCatalog.resolve(uid: "disconnected", devices: devices, defaultID: 10))
        XCTAssertThrowsError(try MicrophoneCatalog.resolve(uid: nil, devices: [], defaultID: 10))
    }
    func testUIDResolvesNewHardwareIDAfterReconnection() throws {
        let reconnected = [MicrophoneDevice(hardwareID: 55, uid: "builtin", name: "MacBook microphone")]
        XCTAssertEqual(try MicrophoneCatalog.resolve(uid: "builtin", devices: reconnected, defaultID: 55).hardwareID, 55)
    }

    func testSettledIdleInputConfigurationRestoresTheTap() {
        XCTAssertEqual(
            MicrophoneInput.configurationResponse(
                engineRunning: true, sameDevice: true, sameFormat: true
            ),
            .restoreTap
        )
    }

    func testStableInputConfigurationDuringCaptureRestoresTapWithoutFailingCapture() {
        XCTAssertEqual(
            MicrophoneInput.configurationResponse(
                engineRunning: true, sameDevice: true, sameFormat: true
            ),
            .restoreTap
        )
    }

    func testUnavailableOrChangedInputConfigurationInterrupts() {
        let changes = [
            (false, true, true),
            (true, false, true),
            (true, true, false),
        ]
        for (running, sameDevice, sameFormat) in changes {
            XCTAssertEqual(
                MicrophoneInput.configurationResponse(
                    engineRunning: running, sameDevice: sameDevice, sameFormat: sameFormat
                ),
                .interrupt
            )
        }
    }
}
