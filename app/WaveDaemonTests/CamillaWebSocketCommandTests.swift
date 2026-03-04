import XCTest
@testable import WaveDaemon

final class CamillaWebSocketCommandTests: XCTestCase {
    func testToggleMuteCommandEncodesAsJSONStringCommand() throws {
        let payload = try CamillaCommand.toggleMute.encodedMessage()

        let object = try JSONSerialization.jsonObject(
            with: Data(payload.utf8),
            options: [.fragmentsAllowed]
        ) as? String

        XCTAssertEqual(object, "ToggleMute")
    }

    func testSetVolumeCommandEncodesWithNumericValue() throws {
        let payload = try CamillaCommand.setVolume(-6.5).encodedMessage()

        let object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        let value = object?["SetVolume"] as? NSNumber

        XCTAssertNotNil(value)
        XCTAssertEqual(value?.doubleValue ?? 0, -6.5, accuracy: 0.0001)
    }

    func testSetConfigCommandEncodesFullProfileText() throws {
        let profileText = "filters:\n  eq_band_01:\n    gain: 1.5"
        let payload = try CamillaCommand.setConfig(profileText).encodedMessage()

        let object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        let value = object?["SetConfig"] as? String

        XCTAssertEqual(value, profileText)
    }
}
