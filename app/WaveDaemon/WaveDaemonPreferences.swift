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

    enum WebSocketURLStorageBehavior: Equatable {
        case invalid
        case sessionOnly(String)
        case persistent(String)
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
            switch webSocketURLStorageBehavior(from: value, environment: environment) {
            case let .persistent(normalized):
                if normalized != value {
                    userDefaults.set(normalized, forKey: Keys.preferredWebSocketURL)
                }
                return normalized
            case .invalid, .sessionOnly(_):
                userDefaults.removeObject(forKey: Keys.preferredWebSocketURL)
            }
        }

        return defaultWebSocketURLString(environment: environment)
    }

    static func normalizedWebSocketURL(
        from urlString: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        switch webSocketURLStorageBehavior(from: urlString, environment: environment) {
        case .invalid:
            return nil
        case let .sessionOnly(normalized), let .persistent(normalized):
            return normalized
        }
    }

    static func persistableWebSocketURL(
        from urlString: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard case let .persistent(normalized) = webSocketURLStorageBehavior(
            from: urlString,
            environment: environment
        ) else {
            return nil
        }

        return normalized
    }

    @discardableResult
    static func persistPreferredWebSocketURLIfSafe(
        _ urlString: String,
        userDefaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let normalized = persistableWebSocketURL(from: urlString, environment: environment) else {
            return false
        }

        userDefaults.set(normalized, forKey: Keys.preferredWebSocketURL)
        return true
    }

    static func webSocketURLStorageBehavior(
        from urlString: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> WebSocketURLStorageBehavior {
        guard var components = normalizedWebSocketComponents(from: urlString, environment: environment) else {
            return .invalid
        }

        if components.port == nil {
            components.port = defaultWebSocketPort(environment: environment)
        }

        guard let normalized = components.string else {
            return .invalid
        }

        if hasSensitiveWebSocketURLComponents(components) {
            return .sessionOnly(normalized)
        }

        return .persistent(normalized)
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
        guard let components = normalizedWebSocketComponents(from: urlString) else {
            return nil
        }

        let port = components.port ?? defaultWebSocketPort()

        return (components.host ?? "", port)
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

    private static func normalizedWebSocketComponents(
        from urlString: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URLComponents? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let candidate = trimmed.contains("://") ? trimmed : "ws://\(trimmed)"
        guard var components = URLComponents(string: candidate) else {
            return nil
        }

        switch components.scheme?.lowercased() {
        case "http":
            components.scheme = "ws"
        case "https":
            components.scheme = "wss"
        case "ws", "wss":
            break
        default:
            return nil
        }

        guard let host = components.host, !host.isEmpty else {
            return nil
        }

        if let port = components.port, !(1...65_535).contains(port) {
            return nil
        }

        if components.port == nil {
            components.port = defaultWebSocketPort(environment: environment)
        }

        components.host = host
        return components
    }

    private static func hasSensitiveWebSocketURLComponents(_ components: URLComponents) -> Bool {
        let hasCredentials = (components.user?.isEmpty == false) || (components.password?.isEmpty == false)
        let hasQuery = components.percentEncodedQuery?.isEmpty == false
        let hasFragment = components.percentEncodedFragment?.isEmpty == false

        return hasCredentials || hasQuery || hasFragment
    }
}
