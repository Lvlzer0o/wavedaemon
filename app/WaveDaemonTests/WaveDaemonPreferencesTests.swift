import XCTest
@testable import WaveDaemon

final class WaveDaemonPreferencesTests: XCTestCase {
    func testDaemonBindDefaultsFallBackToLegacyWebSocketEnv() {
        let (defaults, suiteName) = makeIsolatedUserDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let environment = [
            "CAMILLADSP_WS_ADDRESS": "10.0.0.5",
            "CAMILLADSP_WS_PORT": "9012",
        ]

        let snapshot = WaveDaemonPreferences.load(userDefaults: defaults, environment: environment)
        XCTAssertEqual(snapshot.daemonBindAddress, "10.0.0.5")
        XCTAssertEqual(snapshot.daemonBindPort, 9012)
    }

    func testClientURLAndDaemonBindAreIndependent() {
        let (defaults, suiteName) = makeIsolatedUserDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("ws://remote.example.com:9999", forKey: WaveDaemonPreferences.Keys.preferredWebSocketURL)
        defaults.set("0.0.0.0", forKey: WaveDaemonPreferences.Keys.daemonBindAddress)
        defaults.set(1234, forKey: WaveDaemonPreferences.Keys.daemonBindPort)

        let snapshot = WaveDaemonPreferences.load(userDefaults: defaults, environment: [:])
        XCTAssertEqual(snapshot.preferredWebSocketURL, "ws://remote.example.com:9999")
        XCTAssertEqual(snapshot.daemonBindAddress, "0.0.0.0")
        XCTAssertEqual(snapshot.daemonBindPort, 1234)
    }

    private func makeIsolatedUserDefaults() -> (UserDefaults, String) {
        let suiteName = "WaveDaemonPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
