import XCTest
@testable import WaveDaemon

final class DSPManagerTests: XCTestCase {
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
            validatePaths: false,
            autoRouteSystemOutput: false
        )

        XCTAssertThrowsError(try manager.startDSP()) { error in
            guard case DSPManagerError.webSocketNeverBecameReady = error else {
                return XCTFail("Expected webSocketNeverBecameReady, got: \(error)")
            }
        }
        XCTAssertEqual(mockProcess.terminateCallCount, 1)
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
