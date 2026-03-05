import Foundation

struct WaveDaemonPreferencesSnapshot {
    let preferredWebSocketURL: String
    let autoRouteSystemOutput: Bool
    let processingOutputDevice: String
    let autoConnectOnLaunch: Bool
}

enum WaveDaemonPreferences {
    enum Keys {
        static let preferredWebSocketURL = "wavedaemon.preferredWebSocketURL"
        static let autoRouteSystemOutput = "wavedaemon.autoRouteSystemOutput"
        static let processingOutputDevice = "wavedaemon.processingOutputDevice"
        static let autoConnectOnLaunch = "wavedaemon.autoConnectOnLaunch"
    }

    static func load(
        userDefaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> WaveDaemonPreferencesSnapshot {
        WaveDaemonPreferencesSnapshot(
            preferredWebSocketURL: currentWebSocketURL(userDefaults: userDefaults, environment: environment),
            autoRouteSystemOutput: currentAutoRouteSystemOutput(
                userDefaults: userDefaults,
                environment: environment
            ),
            processingOutputDevice: currentProcessingOutputDevice(
                userDefaults: userDefaults,
                environment: environment
            ),
            autoConnectOnLaunch: currentAutoConnectOnLaunch(userDefaults: userDefaults)
        )
    }

    static func defaultWebSocketURLString(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        "ws://\(defaultWebSocketAddress(environment: environment)):\(defaultWebSocketPort(environment: environment))"
    }

    static func currentWebSocketURL(
        userDefaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let value = userDefaults.string(forKey: Keys.preferredWebSocketURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }

        return defaultWebSocketURLString(environment: environment)
    }

    static func defaultAutoRouteSystemOutput(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let rawValue = environment["WAVE_DAEMON_AUTO_ROUTE_OUTPUT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return rawValue != "0" && rawValue != "false" && rawValue != "no"
    }

    static func currentAutoRouteSystemOutput(
        userDefaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard userDefaults.object(forKey: Keys.autoRouteSystemOutput) != nil else {
            return defaultAutoRouteSystemOutput(environment: environment)
        }
        return userDefaults.bool(forKey: Keys.autoRouteSystemOutput)
    }

    static func defaultProcessingOutputDevice(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let candidates = [
            environment["WAVE_DAEMON_PROCESSING_OUTPUT_DEVICE"],
            environment["CAMILLADSP_PROCESSING_OUTPUT_DEVICE"],
            environment["CAMILLADSP_MULTI_OUTPUT_NAME"],
            environment["CAMILLADSP_MULTI_OUTPUT_FALLBACK"],
            environment["CAMILLADSP_RAW_OUTPUT_FALLBACK"],
            "System DSP Output",
            "Multi-Output Device",
            "BlackHole 2ch",
        ]

        for candidate in candidates {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        return "System DSP Output"
    }

    static func currentProcessingOutputDevice(
        userDefaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let value = userDefaults.string(forKey: Keys.processingOutputDevice)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }

        return defaultProcessingOutputDevice(environment: environment)
    }

    static func currentAutoConnectOnLaunch(userDefaults: UserDefaults = .standard) -> Bool {
        guard userDefaults.object(forKey: Keys.autoConnectOnLaunch) != nil else {
            return false
        }
        return userDefaults.bool(forKey: Keys.autoConnectOnLaunch)
    }

    static func parseWebSocketEndpoint(from urlString: String) -> (host: String, port: Int)? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let candidate = trimmed.contains("://") ? trimmed : "ws://\(trimmed)"
        guard var components = URLComponents(string: candidate) else {
            return nil
        }

        if components.scheme == "http" {
            components.scheme = "ws"
        } else if components.scheme == "https" {
            components.scheme = "wss"
        }

        guard let host = components.host, !host.isEmpty else {
            return nil
        }

        let port = components.port ?? defaultWebSocketPort()
        guard (1...65_535).contains(port) else {
            return nil
        }

        return (host, port)
    }

    static func resetToDefaults(userDefaults: UserDefaults = .standard) {
        userDefaults.set(defaultWebSocketURLString(), forKey: Keys.preferredWebSocketURL)
        userDefaults.set(defaultAutoRouteSystemOutput(), forKey: Keys.autoRouteSystemOutput)
        userDefaults.set(defaultProcessingOutputDevice(), forKey: Keys.processingOutputDevice)
        userDefaults.set(false, forKey: Keys.autoConnectOnLaunch)
    }

    private static func defaultWebSocketAddress(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let value = environment["CAMILLADSP_WS_ADDRESS"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false ? value! : "127.0.0.1")
    }

    private static func defaultWebSocketPort(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        guard let rawValue = environment["CAMILLADSP_WS_PORT"],
              let value = Int(rawValue),
              (1...65_535).contains(value) else {
            return 1234
        }
        return value
    }
}
