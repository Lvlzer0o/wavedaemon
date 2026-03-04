import XCTest
@testable import WaveDaemon

final class DSPManagerTests: XCTestCase {
    func testStartDSPStartsProcess() throws {
        let mockProcess = MockDSPProcess()
        let manager = DSPManager(
            processFactory: { mockProcess },
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            configURL: URL(fileURLWithPath: "/tmp/config.yml")
        )

        let didStart = try manager.startDSP()

        XCTAssertTrue(didStart)
        XCTAssertTrue(manager.isDSPRunning)
        XCTAssertEqual(mockProcess.runCallCount, 1)
        XCTAssertEqual(mockProcess.executableURL?.path, "/usr/bin/env")
        XCTAssertEqual(mockProcess.arguments, ["--config", "/tmp/config.yml"])
    }

    func testStopDSPTerminatesRunningProcess() throws {
        let mockProcess = MockDSPProcess()
        let manager = DSPManager(
            processFactory: { mockProcess },
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            configURL: URL(fileURLWithPath: "/tmp/config.yml")
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
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            configURL: URL(fileURLWithPath: "/tmp/config.yml")
        )

        XCTAssertFalse(manager.isDSPRunning)

        _ = try manager.startDSP()
        XCTAssertTrue(manager.isDSPRunning)

        mockProcess.isRunning = false
        XCTAssertFalse(manager.isDSPRunning)
    }
}

private final class MockDSPProcess: DSPProcess {
    var executableURL: URL?
    var arguments: [String]?
    var isRunning = false

    private(set) var runCallCount = 0
    private(set) var terminateCallCount = 0

    func run() throws {
        runCallCount += 1
        isRunning = true
    }

    func terminate() {
        terminateCallCount += 1
        isRunning = false
    }
}
