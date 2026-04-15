import Foundation

protocol DSPProcess: AnyObject {
    var executableURL: URL? { get set }
    var arguments: [String]? { get set }
    var isRunning: Bool { get }

    func run() throws
    func terminate()
}

extension Process: DSPProcess {}

enum DSPManagerError: LocalizedError {
    case executableNotFound(String)
    case configNotFound(String)
    case processExitedImmediately(Int32?, String?)
    case webSocketNeverBecameReady(host: String, port: Int, logTail: String?)
    case routingFailed(String)

    var errorDescription: String? {
        switch self {
        case let .executableNotFound(path):
            return "CamillaDSP binary not found or not executable at \(path)"
        case let .configNotFound(path):
            return "CamillaDSP config not found or unreadable at \(path)"
        case let .processExitedImmediately(status, logTail):
            let baseMessage: String
            if let status {
                baseMessage = "CamillaDSP exited immediately with status \(status)"
            } else {
                baseMessage = "CamillaDSP exited immediately"
            }
            return Self.withOptionalLogTail(baseMessage, logTail: logTail)
        case let .webSocketNeverBecameReady(host, port, logTail):
            let baseMessage = "CamillaDSP started but ws://\(host):\(port) never became ready"
            return Self.withOptionalLogTail(baseMessage, logTail: logTail)
        case let .routingFailed(message):
            return message
        }
    }

    private static func withOptionalLogTail(_ message: String, logTail: String?) -> String {
        guard let logTail, !logTail.isEmpty else {
            return message
        }
        return "\(message)\n\nRecent CamillaDSP log:\n\(logTail)"
    }
}

final class DSPManager {
    static let shared = DSPManager()

    typealias ProcessFactory = () -> DSPProcess
    typealias PortProbe = (_ host: String, _ port: Int, _ timeout: TimeInterval) -> Bool

    private let processFactory: ProcessFactory
    private let portProbe: PortProbe
    private let fileManager: FileManager
    private let executableURL: URL
    private let configURL: URL
    private let workingDirectoryURL: URL
    private let runtimeDirectoryURL: URL
    private let logFileURL: URL
    private let stateFileURL: URL
    private var daemonBindAddress: String
    private var daemonBindPort: Int
    private let logLevel: String
    private let startupTimeout: TimeInterval
    private let validatePaths: Bool
    private var autoRouteSystemOutput: Bool
    private var processingOutputDevice: String
    private let switchAudioSourcePath: String?

    private(set) var process: DSPProcess?
    private(set) var lastExitStatus: Int32?
    private(set) var lastRoutingMessage: String?
    private var previousSystemOutputDevice: String?

    init(
        processFactory: @escaping ProcessFactory = { Process() },
        portProbe: @escaping PortProbe = DSPManager.defaultPortProbe(host:port:timeout:),
        fileManager: FileManager = .default,
        executableURL: URL = DSPManager.defaultExecutableURL(),
        configURL: URL = DSPManager.defaultConfigURL(),
        workingDirectoryURL: URL = DSPManager.defaultWorkingDirectoryURL(),
        runtimeDirectoryURL: URL = DSPManager.defaultRuntimeDirectoryURL(),
        logFileURL: URL = DSPManager.defaultLogFileURL(),
        stateFileURL: URL = DSPManager.defaultStateFileURL(),
        daemonBindAddress: String = DSPManager.defaultDaemonBindAddress(),
        daemonBindPort: Int = DSPManager.defaultDaemonBindPort(),
        logLevel: String = "info",
        startupTimeout: TimeInterval = 3.0,
        validatePaths: Bool = true,
        autoRouteSystemOutput: Bool = DSPManager.defaultAutoRouteSystemOutput(),
        processingOutputDevice: String = DSPManager.defaultProcessingOutputDevice(),
        switchAudioSourcePath: String? = DSPManager.defaultSwitchAudioSourcePath()
    ) {
        self.processFactory = processFactory
        self.portProbe = portProbe
        self.fileManager = fileManager
        self.executableURL = executableURL
        self.configURL = configURL
        self.workingDirectoryURL = workingDirectoryURL
        self.runtimeDirectoryURL = runtimeDirectoryURL
        self.logFileURL = logFileURL
        self.stateFileURL = stateFileURL
        self.daemonBindAddress = daemonBindAddress
        self.daemonBindPort = daemonBindPort
        self.logLevel = logLevel
        self.startupTimeout = startupTimeout
        self.validatePaths = validatePaths
        self.autoRouteSystemOutput = autoRouteSystemOutput
        self.processingOutputDevice = processingOutputDevice
        self.switchAudioSourcePath = switchAudioSourcePath
    }

    var isDSPRunning: Bool {
        process?.isRunning == true
    }

    var configurationFilePath: String {
        configURL.path
    }

    var runtimeDirectoryPath: String {
        runtimeDirectoryURL.path
    }

    var logFilePath: String {
        logFileURL.path
    }

    func applyPreferences(_ preferences: WaveDaemonPreferencesSnapshot = WaveDaemonPreferences.load()) {
        daemonBindAddress = preferences.daemonBindAddress
        daemonBindPort = preferences.daemonBindPort

        autoRouteSystemOutput = preferences.autoRouteSystemOutput
        processingOutputDevice = preferences.processingOutputDevice
    }

    func setRuntimeWebSocketEndpoint(host: String, port: Int) {
        guard !host.isEmpty, (1...65_535).contains(port) else {
            return
        }

        wsAddress = host
        wsPort = port
    }

    func isWebSocketReachable(timeout: TimeInterval = 0.2) -> Bool {
        let probeHost = probeHostForDaemonBindAddress(daemonBindAddress)
        return portProbe(probeHost, daemonBindPort, timeout)
    }

    @discardableResult
    func startDSP() throws -> Bool {
        guard !isDSPRunning else {
            return false
        }

        // Transactional startup contract:
        // 1) validate paths, 2) launch process, 3) wait for readiness,
        // 4) route output, 5) rollback/cleanup on any failure.
        if validatePaths {
            guard fileManager.isExecutableFile(atPath: executableURL.path) else {
                throw DSPManagerError.executableNotFound(executableURL.path)
            }

            guard fileManager.isReadableFile(atPath: configURL.path) else {
                throw DSPManagerError.configNotFound(configURL.path)
            }

            try fileManager.createDirectory(
                at: runtimeDirectoryURL,
                withIntermediateDirectories: true
            )
        }

        let process = processFactory()
        process.executableURL = executableURL
        process.arguments = [
            "--loglevel", logLevel,
            "--logfile", logFileURL.path,
            "--address", daemonBindAddress,
            "--port", String(daemonBindPort),
            "--statefile", stateFileURL.path,
            configURL.path,
        ]

        if let nativeProcess = process as? Process {
            nativeProcess.currentDirectoryURL = workingDirectoryURL
            nativeProcess.terminationHandler = { [weak self] terminatedProcess in
                let status = terminatedProcess.terminationStatus
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let activeProcess = self.process as? Process, activeProcess === terminatedProcess {
                        self.process = nil
                    }
                    self.lastExitStatus = status
                }
                print("camilladsp exited: \(status)")
            }
        }

        try process.run()
        lastExitStatus = nil

        let probeHost = probeHostForDaemonBindAddress(daemonBindAddress)
        let deadline = Date().addingTimeInterval(startupTimeout)
        while Date() < deadline {
            if !process.isRunning {
                self.process = nil
                let status = (process as? Process)?.terminationStatus
                throw DSPManagerError.processExitedImmediately(status, readLogTail())
            }

            let remaining = deadline.timeIntervalSinceNow
            let probeTimeout = min(0.2, max(0.05, remaining))
            if portProbe(probeHost, daemonBindPort, probeTimeout) {
                if autoRouteSystemOutput {
                    let _ = ensureProcessingRoute()
                    if !isRoutedToProcessingDevice() {
                        process.terminate()
                        self.process = nil
                        _ = restoreSystemOutputRouteIfNeeded()
                        throw DSPManagerError.routingFailed(
                            "CamillaDSP started but output routing to \(processingOutputDevice) failed"
                        )
                    }
                }
                self.process = process
                return true
            }

            Thread.sleep(forTimeInterval: 0.05)
        }

        if !process.isRunning {
            self.process = nil
            let status = (process as? Process)?.terminationStatus
            throw DSPManagerError.processExitedImmediately(status, readLogTail())
        }

        process.terminate()
        self.process = nil
        throw DSPManagerError.webSocketNeverBecameReady(
            host: probeHost,
            port: daemonBindPort,
            logTail: readLogTail()
        )
    }

    @discardableResult
    func stopDSP() -> Bool {
        guard let process else {
            _ = restoreSystemOutputRouteIfNeeded()
            return false
        }

        if process.isRunning {
            process.terminate()
        }

        self.process = nil
        _ = restoreSystemOutputRouteIfNeeded()
        return true
    }

    @discardableResult
    func ensureProcessingRoute() -> String? {
        guard autoRouteSystemOutput else {
            lastRoutingMessage = nil
            return nil
        }

        guard let switchAudioSourcePath else {
            let message = "SwitchAudioSource not found; output routing unchanged"
            lastRoutingMessage = message
            return message
        }

        guard outputDeviceExists(named: processingOutputDevice, switchAudioSourcePath: switchAudioSourcePath) else {
            let message = "Output device '\(processingOutputDevice)' not found; routing unchanged"
            lastRoutingMessage = message
            return message
        }

        let currentOutput = currentOutputDeviceName(switchAudioSourcePath: switchAudioSourcePath)
        if previousSystemOutputDevice == nil {
            previousSystemOutputDevice = currentOutput
        }

        if currentOutput == processingOutputDevice {
            let message = "System output already routed to \(processingOutputDevice)"
            lastRoutingMessage = message
            return message
        }

        guard setOutputDevice(named: processingOutputDevice, switchAudioSourcePath: switchAudioSourcePath) else {
            let message = "Failed to route output to \(processingOutputDevice)"
            lastRoutingMessage = message
            return message
        }

        let message = "System output routed to \(processingOutputDevice)"
        lastRoutingMessage = message
        return message
    }

    @discardableResult
    func restoreSystemOutputRouteIfNeeded() -> String? {
        guard autoRouteSystemOutput else {
            return nil
        }

        guard let switchAudioSourcePath, let previous = previousSystemOutputDevice, !previous.isEmpty else {
            return nil
        }

        defer {
            previousSystemOutputDevice = nil
        }

        guard outputDeviceExists(named: previous, switchAudioSourcePath: switchAudioSourcePath) else {
            let message = "Previous output '\(previous)' is unavailable; leaving current output"
            lastRoutingMessage = message
            return message
        }

        let currentOutput = currentOutputDeviceName(switchAudioSourcePath: switchAudioSourcePath)
        if currentOutput == previous {
            let message = "System output already restored to \(previous)"
            lastRoutingMessage = message
            return message
        }

        guard setOutputDevice(named: previous, switchAudioSourcePath: switchAudioSourcePath) else {
            let message = "Failed to restore output to \(previous)"
            lastRoutingMessage = message
            return message
        }

        let message = "System output restored to \(previous)"
        lastRoutingMessage = message
        return message
    }

    private func readLogTail(maxLines: Int = 80) -> String? {
        guard let data = try? Data(contentsOf: logFileURL),
              let content = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        guard !lines.isEmpty else {
            return nil
        }

        return lines.suffix(maxLines).joined(separator: "\n")
    }

    private static func defaultExecutableURL() -> URL {
        let fileManager = FileManager.default
        let env = ProcessInfo.processInfo.environment

        if let explicitPath = env["CAMILLADSP_BIN"], !explicitPath.isEmpty {
            let url = URL(fileURLWithPath: explicitPath).standardizedFileURL
            if fileManager.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        if let path = env["PATH"] {
            for directory in path.split(separator: ":").map(String.init) {
                let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                    .appendingPathComponent("camilladsp")
                    .standardizedFileURL
                if fileManager.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }

        let candidates = [
            "/opt/homebrew/bin/camilladsp",
            "/usr/local/bin/camilladsp",
            "\(NSHomeDirectory())/.local/bin/camilladsp",
        ]

        if let match = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: match)
        }

        return URL(fileURLWithPath: "/usr/local/bin/camilladsp")
    }

    private static func defaultAutoRouteSystemOutput() -> Bool {
        WaveDaemonPreferences.currentAutoRouteSystemOutput()
    }

    private static func defaultProcessingOutputDevice() -> String {
        WaveDaemonPreferences.currentProcessingOutputDevice()
    }

    private static func defaultSwitchAudioSourcePath(fileManager: FileManager = .default) -> String? {
        let env = ProcessInfo.processInfo.environment

        if let explicitPath = env["SWITCH_AUDIO_SOURCE_BIN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicitPath.isEmpty,
           fileManager.isExecutableFile(atPath: explicitPath) {
            return explicitPath
        }

        let candidates = [
            "/opt/homebrew/bin/SwitchAudioSource",
            "/usr/local/bin/SwitchAudioSource",
        ]

        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0) })
    }

    private static func defaultConfigURL(fileManager: FileManager = .default) -> URL {
        if let overridePath = ProcessInfo.processInfo.environment["CAMILLADSP_CONFIG"], !overridePath.isEmpty {
            return URL(fileURLWithPath: overridePath).standardizedFileURL
        }

        let env = ProcessInfo.processInfo.environment
        var candidates: [URL] = []

        if let repoRoot = env["WAVE_DAEMON_REPO_ROOT"], !repoRoot.isEmpty {
            let repoURL = URL(fileURLWithPath: repoRoot, isDirectory: true)
            candidates.append(repoURL.appendingPathComponent("dsp/config.yml"))
        }

        if let sourceRoot = env["SRCROOT"], !sourceRoot.isEmpty {
            candidates.append(
                URL(fileURLWithPath: sourceRoot, isDirectory: true).appendingPathComponent("dsp/config.yml")
            )
        }

        if let projectDirectory = env["PROJECT_DIR"], !projectDirectory.isEmpty {
            candidates.append(
                URL(fileURLWithPath: projectDirectory, isDirectory: true)
                    .appendingPathComponent("../dsp/config.yml")
                    .standardizedFileURL
            )
        }

        let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        candidates.append(currentDirectory.appendingPathComponent("dsp/config.yml"))
        candidates.append(currentDirectory.appendingPathComponent("../dsp/config.yml").standardizedFileURL)

        if let bundledConfig = Bundle.main.url(forResource: "config", withExtension: "yml") {
            candidates.append(bundledConfig)
        }

        if let match = candidates.first(where: { fileManager.isReadableFile(atPath: $0.path) }) {
            return match
        }

        return candidates.first ?? currentDirectory.appendingPathComponent("dsp/config.yml")
    }

    private static func defaultRuntimeDirectoryURL(fileManager: FileManager = .default) -> URL {
        let env = ProcessInfo.processInfo.environment
        var candidates: [URL] = []

        if let explicit = env["CAMILLADSP_RUNTIME_DIR"], !explicit.isEmpty {
            candidates.append(URL(fileURLWithPath: explicit, isDirectory: true).standardizedFileURL)
        }

        if let repoRoot = env["WAVE_DAEMON_REPO_ROOT"], !repoRoot.isEmpty {
            let repoURL = URL(fileURLWithPath: repoRoot, isDirectory: true)
            candidates.append(repoURL.appendingPathComponent(".runtime"))
        }

        if let sourceRoot = env["SRCROOT"], !sourceRoot.isEmpty {
            candidates.append(URL(fileURLWithPath: sourceRoot, isDirectory: true).appendingPathComponent(".runtime"))
        }

        if let projectDirectory = env["PROJECT_DIR"], !projectDirectory.isEmpty {
            candidates.append(
                URL(fileURLWithPath: projectDirectory, isDirectory: true)
                    .appendingPathComponent("../.runtime")
                    .standardizedFileURL
            )
        }

        let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        candidates.append(currentDirectory.appendingPathComponent(".runtime"))
        candidates.append(currentDirectory.appendingPathComponent("../.runtime").standardizedFileURL)

        if let existing = candidates.first(where: { directoryExists($0, fileManager: fileManager) }) {
            return existing
        }

        return candidates.first ?? currentDirectory.appendingPathComponent(".runtime")
    }

    private static func defaultWorkingDirectoryURL(fileManager: FileManager = .default) -> URL {
        let env = ProcessInfo.processInfo.environment
        if let repoRoot = env["WAVE_DAEMON_REPO_ROOT"], !repoRoot.isEmpty {
            return URL(fileURLWithPath: repoRoot, isDirectory: true).standardizedFileURL
        }

        if let sourceRoot = env["SRCROOT"], !sourceRoot.isEmpty {
            return URL(fileURLWithPath: sourceRoot, isDirectory: true).standardizedFileURL
        }

        if let projectDirectory = env["PROJECT_DIR"], !projectDirectory.isEmpty {
            return URL(fileURLWithPath: projectDirectory, isDirectory: true)
                .appendingPathComponent("..")
                .standardizedFileURL
        }

        return URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            .standardizedFileURL
    }

    private static func defaultLogFileURL() -> URL {
        if let explicit = ProcessInfo.processInfo.environment["CAMILLADSP_LOGFILE"], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit).standardizedFileURL
        }

        return defaultRuntimeDirectoryURL().appendingPathComponent("camilladsp.log")
    }

    private static func defaultStateFileURL() -> URL {
        if let explicit = ProcessInfo.processInfo.environment["CAMILLADSP_STATEFILE"], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit).standardizedFileURL
        }

        return defaultRuntimeDirectoryURL().appendingPathComponent("state.json")
    }

    static func defaultWebSocketURLString() -> String {
        WaveDaemonPreferences.currentWebSocketURL()
    }

    private static func defaultDaemonBindAddress() -> String {
        WaveDaemonPreferences.currentDaemonBindAddress()
    }

    private static func defaultDaemonBindPort() -> Int {
        WaveDaemonPreferences.currentDaemonBindPort()
    }

    nonisolated private static func defaultPortProbe(host: String, port: Int, timeout: TimeInterval) -> Bool {
        guard (1...65_535).contains(port) else {
            return false
        }

        let lsofCandidates = ["/usr/sbin/lsof", "/usr/bin/lsof"]
        guard let lsofPath = lsofCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsofPath)
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return false
        }

        let start = Date()
        while process.isRunning {
            if Date().timeIntervalSince(start) >= timeout {
                process.terminate()
                return false
            }
            Thread.sleep(forTimeInterval: 0.01)
        }

        process.waitUntilExit()
        if process.terminationStatus != 0 {
            return false
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: outputData, encoding: .utf8) else {
            return false
        }

        if host.isEmpty || host == "127.0.0.1" || host == "localhost" {
            return !output.isEmpty
        }

        return output.localizedCaseInsensitiveContains(host)
    }

    private static func directoryExists(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    private func currentOutputDeviceName(switchAudioSourcePath: String) -> String? {
        let result = runProcess(path: switchAudioSourcePath, arguments: ["-c", "-t", "output"])
        guard result.exitCode == 0 else {
            return nil
        }

        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    private func outputDeviceExists(named deviceName: String, switchAudioSourcePath: String) -> Bool {
        let result = runProcess(path: switchAudioSourcePath, arguments: ["-a", "-t", "output"])
        guard result.exitCode == 0 else {
            return false
        }

        let lines = result.output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        return lines.contains(deviceName)
    }

    private func setOutputDevice(named deviceName: String, switchAudioSourcePath: String) -> Bool {
        let result = runProcess(path: switchAudioSourcePath, arguments: ["-s", deviceName, "-t", "output"])
        return result.exitCode == 0
    }

    private func runProcess(path: String, arguments: [String]) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (-1, "")
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: outputData, encoding: .utf8) ?? ""
        let stderr = String(data: errorData, encoding: .utf8) ?? ""

        return (process.terminationStatus, stdout + stderr)
    }

    private func isRoutedToProcessingDevice() -> Bool {
        guard autoRouteSystemOutput, let switchAudioSourcePath else {
            return true
        }
        return currentOutputDeviceName(switchAudioSourcePath: switchAudioSourcePath) == processingOutputDevice
    }

    private func probeHostForDaemonBindAddress(_ address: String) -> String {
        let normalized = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "0.0.0.0" || normalized == "*" {
            return "127.0.0.1"
        }
        if normalized == "::" {
            return "::1"
        }
        return address
    }
}
