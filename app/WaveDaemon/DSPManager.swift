import Foundation

protocol DSPProcess: AnyObject {
    var executableURL: URL? { get set }
    var arguments: [String]? { get set }
    var isRunning: Bool { get }

    func run() throws
    func terminate()
}

extension Process: DSPProcess {}

final class DSPManager {
    static let shared = DSPManager()

    typealias ProcessFactory = () -> DSPProcess

    private let processFactory: ProcessFactory
    private let executableURL: URL
    private let configURL: URL

    private(set) var process: DSPProcess?

    init(
        processFactory: @escaping ProcessFactory = { Process() },
        executableURL: URL = DSPManager.defaultExecutableURL(),
        configURL: URL = DSPManager.defaultConfigURL()
    ) {
        self.processFactory = processFactory
        self.executableURL = executableURL
        self.configURL = configURL
    }

    var isDSPRunning: Bool {
        process?.isRunning == true
    }

    @discardableResult
    func startDSP() throws -> Bool {
        guard !isDSPRunning else {
            return false
        }

        let process = processFactory()
        process.executableURL = executableURL
        process.arguments = ["--config", configURL.path]

        try process.run()
        self.process = process
        return true
    }

    @discardableResult
    func stopDSP() -> Bool {
        guard let process else {
            return false
        }

        if process.isRunning {
            process.terminate()
        }

        self.process = nil
        return true
    }

    private static func defaultExecutableURL() -> URL {
        let homebrewPath = "/opt/homebrew/bin/camilladsp"
        if FileManager.default.isExecutableFile(atPath: homebrewPath) {
            return URL(fileURLWithPath: homebrewPath)
        }

        return URL(fileURLWithPath: "/usr/local/bin/camilladsp")
    }

    private static func defaultConfigURL() -> URL {
        let currentDirectory = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )

        return currentDirectory.appendingPathComponent("dsp/config.yml")
    }
}
