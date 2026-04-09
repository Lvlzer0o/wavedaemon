import XCTest
@testable import WaveDaemon

final class DSPManagerTests: XCTestCase {
    func testWildcardBindAddressesProbeLoopback() throws {
        let wildcardCases = ["0.0.0.0", "::", "*"]

        for wildcard in wildcardCases {
            let mockProcess = MockDSPProcess()
            var probedHosts: [String] = []
            var probedPorts: [Int] = []
            let manager = DSPManager(
                processFactory: { mockProcess },
                portProbe: { host, port, _ in
                    probedHosts.append(host)
                    probedPorts.append(port)
                    return true
                },
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                configURL: URL(fileURLWithPath: "/tmp/config.yml"),
                runtimeDirectoryURL: URL(fileURLWithPath: "/tmp"),
                daemonBindAddress: wildcard,
                daemonBindPort: 4321,
                validatePaths: false,
                autoRouteSystemOutput: false
            )

            let didStart = try manager.startDSP()
            XCTAssertTrue(didStart, "Expected startup to succeed for wildcard \(wildcard)")
            XCTAssertTrue(probedHosts.allSatisfy { $0 == "127.0.0.1" })
            XCTAssertTrue(probedPorts.allSatisfy { $0 == 4321 })
            _ = manager.stopDSP()
        }
    }

    func testStartDSPStartsProcess() throws {
        let mockProcess = MockDSPProcess()
        let manager = DSPManager(
            processFactory: { mockProcess },
            portProbe: { _, _, _ in true },
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            configURL: URL(fileURLWithPath: "/tmp/config.yml"),
            runtimeDirectoryURL: URL(fileURLWithPath: "/tmp"),
            logFileURL: URL(fileURLWithPath: "/tmp/camilladsp.log"),
            stateFileURL: URL(fileURLWithPath: "/tmp/state.json"),
            daemonBindAddress: "127.0.0.1",
            daemonBindPort: 1234,
            validatePaths: false,
            autoRouteSystemOutput: false
        )

        let didStart = try manager.startDSP()

        XCTAssertTrue(didStart)
        XCTAssertTrue(manager.isDSPRunning)
        XCTAssertEqual(mockProcess.runCallCount, 1)
        XCTAssertEqual(mockProcess.executableURL?.path, "/usr/bin/env")
        XCTAssertEqual(
            mockProcess.arguments,
            [
                "--loglevel", "info",
                "--logfile", "/tmp/camilladsp.log",
                "--address", "127.0.0.1",
                "--port", "1234",
                "--statefile", "/tmp/state.json",
                "/tmp/config.yml",
            ]
        )
    }

    func testStopDSPTerminatesRunningProcess() throws {
        let mockProcess = MockDSPProcess()
        let manager = DSPManager(
            processFactory: { mockProcess },
            portProbe: { _, _, _ in true },
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            configURL: URL(fileURLWithPath: "/tmp/config.yml"),
            runtimeDirectoryURL: URL(fileURLWithPath: "/tmp"),
            daemonBindAddress: "127.0.0.1",
            daemonBindPort: 1234,
            validatePaths: false,
            autoRouteSystemOutput: false
        )

        _ = try manager.startDSP()
        let didStop = manager.stopDSP()

        XCTAssertTrue(didStop)
        XCTAssertEqual(mockProcess.terminateCallCount, 1)
        XCTAssertFalse(manager.isDSPRunning)
    }

    func testRunningStateReflectsProcessState() throws {
        let mockProcess = MockDSPProcess()
        let manager = DSPManager(
            processFactory: { mockProcess },
            portProbe: { _, _, _ in true },
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            configURL: URL(fileURLWithPath: "/tmp/config.yml"),
            runtimeDirectoryURL: URL(fileURLWithPath: "/tmp"),
            daemonBindAddress: "127.0.0.1",
            daemonBindPort: 1234,
            validatePaths: false,
            autoRouteSystemOutput: false
        )

        XCTAssertFalse(manager.isDSPRunning)

        _ = try manager.startDSP()
        XCTAssertTrue(manager.isDSPRunning)

        mockProcess.isRunning = false
        XCTAssertFalse(manager.isDSPRunning)
    }

    func testStartDSPThrowsIfProcessExitsImmediately() {
        let mockProcess = MockDSPProcess(keepsRunningAfterStart: false)
        let manager = DSPManager(
            processFactory: { mockProcess },
            portProbe: { _, _, _ in false },
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            configURL: URL(fileURLWithPath: "/tmp/config.yml"),
            runtimeDirectoryURL: URL(fileURLWithPath: "/tmp"),
            daemonBindAddress: "127.0.0.1",
            daemonBindPort: 1234,
            validatePaths: false,
            autoRouteSystemOutput: false
        )

        XCTAssertThrowsError(try manager.startDSP()) { error in
            guard case DSPManagerError.processExitedImmediately = error else {
                return XCTFail("Expected processExitedImmediately, got: \(error)")
            }
        }
        XCTAssertFalse(manager.isDSPRunning)
    }

    func testStartDSPThrowsIfWebSocketNeverBecomesReady() {
        let mockProcess = MockDSPProcess(keepsRunningAfterStart: true)
        let manager = DSPManager(
            processFactory: { mockProcess },
            portProbe: { _, _, _ in false },
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            configURL: URL(fileURLWithPath: "/tmp/config.yml"),
            runtimeDirectoryURL: URL(fileURLWithPath: "/tmp"),
            startupTimeout: 0.2,
            daemonBindAddress: "127.0.0.1",
            daemonBindPort: 1234,
            validatePaths: false,
            autoRouteSystemOutput: false
        )

        XCTAssertThrowsError(try manager.startDSP()) { error in
            guard case DSPManagerError.webSocketNeverBecameReady = error else {
                return XCTFail("Expected webSocketNeverBecameReady, got: \(error)")
            }
        }
        XCTAssertEqual(mockProcess.terminateCallCount, 1)
        XCTAssertNil(manager.process)
    }

    func testApplyPreferencesUsesDaemonBindEndpoint() throws {
        let mockProcess = MockDSPProcess()
        var probedHost: String?
        var probedPort: Int?
        let manager = DSPManager(
            processFactory: { mockProcess },
            portProbe: { host, port, _ in
                probedHost = host
                probedPort = port
                return true
            },
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            configURL: URL(fileURLWithPath: "/tmp/config.yml"),
            runtimeDirectoryURL: URL(fileURLWithPath: "/tmp"),
            logFileURL: URL(fileURLWithPath: "/tmp/camilladsp.log"),
            stateFileURL: URL(fileURLWithPath: "/tmp/state.json"),
            daemonBindAddress: "127.0.0.1",
            daemonBindPort: 1234,
            validatePaths: false,
            autoRouteSystemOutput: false
        )

        manager.applyPreferences(
            WaveDaemonPreferencesSnapshot(
                preferredWebSocketURL: "ws://remote.example.com:9999",
                daemonBindAddress: "0.0.0.0",
                daemonBindPort: 5678,
                autoRouteSystemOutput: false,
                processingOutputDevice: "System DSP Output",
                autoConnectOnLaunch: false
            )
        )

        _ = try manager.startDSP()
        XCTAssertEqual(probedHost, "127.0.0.1")
        XCTAssertEqual(probedPort, 5678)
        XCTAssertEqual(mockProcess.arguments?.contains("remote.example.com"), false)
        XCTAssertEqual(
            mockProcess.arguments,
            [
                "--loglevel", "info",
                "--logfile", "/tmp/camilladsp.log",
                "--address", "0.0.0.0",
                "--port", "5678",
                "--statefile", "/tmp/state.json",
                "/tmp/config.yml",
            ]
        )
    }

    func testRoutingFailureAfterReadinessTerminatesAndClearsState() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WaveDaemonTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let switchPath = tempRoot.appendingPathComponent("SwitchAudioSource")
        let script = """
        #!/usr/bin/env bash
        set -euo pipefail
        if [[ "$1" == "-a" ]]; then
          printf '%s\\n' "Built-in Output" "System DSP Output"
          exit 0
        fi
        if [[ "$1" == "-c" ]]; then
          printf '%s\\n' "Built-in Output"
          exit 0
        fi
        if [[ "$1" == "-s" ]]; then
          exit 0
        fi
        exit 1
        """
        try script.write(to: switchPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: switchPath.path)

        let mockProcess = MockDSPProcess()
        let manager = DSPManager(
            processFactory: { mockProcess },
            portProbe: { _, _, _ in true },
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            configURL: URL(fileURLWithPath: "/tmp/config.yml"),
            runtimeDirectoryURL: URL(fileURLWithPath: "/tmp"),
            daemonBindAddress: "127.0.0.1",
            daemonBindPort: 1234,
            validatePaths: false,
            autoRouteSystemOutput: true,
            processingOutputDevice: "System DSP Output",
            switchAudioSourcePath: switchPath.path
        )

        XCTAssertThrowsError(try manager.startDSP()) { error in
            guard case DSPManagerError.routingFailed = error else {
                return XCTFail("Expected routingFailed, got: \(error)")
            }
        }
        XCTAssertEqual(mockProcess.terminateCallCount, 1)
        XCTAssertNil(manager.process)
    }

    func testRuntimeEndpointOverridesPersistedEndpointForSessionOnlyPreflight() throws {
        var probes: [(host: String, port: Int)] = []
        let manager = DSPManager(
            processFactory: { MockDSPProcess() },
            portProbe: { host, port, _ in
                probes.append((host: host, port: port))
                return false
            },
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            configURL: URL(fileURLWithPath: "/tmp/config.yml"),
            runtimeDirectoryURL: URL(fileURLWithPath: "/tmp"),
            validatePaths: false,
            autoRouteSystemOutput: false
        )

        manager.applyPreferences(
            WaveDaemonPreferencesSnapshot(
                preferredWebSocketURL: "ws://127.0.0.1:1234",
                autoRouteSystemOutput: false,
                processingOutputDevice: "System DSP Output",
                autoConnectOnLaunch: false
            )
        )

        _ = manager.isWebSocketReachable(timeout: 0.01)

        let sessionOnlyInput = "ws://127.0.0.1:5678?token=abc"
        let connectionURL = try XCTUnwrap(WaveDaemonPreferences.normalizedWebSocketURL(from: sessionOnlyInput))
        let endpoint = try XCTUnwrap(WaveDaemonPreferences.parseWebSocketEndpoint(from: connectionURL))
        manager.setRuntimeWebSocketEndpoint(host: endpoint.host, port: endpoint.port)

        _ = manager.isWebSocketReachable(timeout: 0.01)

        XCTAssertEqual(probes.map(\.host), ["127.0.0.1", "127.0.0.1"])
        XCTAssertEqual(probes.map(\.port), [1234, 5678])
    }
}

private final class MockDSPProcess: DSPProcess {
    var executableURL: URL?
    var arguments: [String]?
    var isRunning = false
    private let keepsRunningAfterStart: Bool

    private(set) var runCallCount = 0
    private(set) var terminateCallCount = 0

    init(keepsRunningAfterStart: Bool = true) {
        self.keepsRunningAfterStart = keepsRunningAfterStart
    }

    func run() throws {
        runCallCount += 1
        isRunning = keepsRunningAfterStart
    }

    func terminate() {
        terminateCallCount += 1
        isRunning = false
    }
}
