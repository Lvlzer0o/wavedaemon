import Foundation

struct AudioProfile: Identifiable, Equatable {
    let name: String
    let fileURL: URL

    var id: String { name }
}

enum ProfileStoreError: LocalizedError {
    case unsafeProfileName

    var errorDescription: String? {
        switch self {
        case .unsafeProfileName:
            return "Profile name contains unsafe path characters"
        }
    }
}

struct ProfileStore {
    private let fileManager: FileManager
    private let explicitProfilesDirectoryURL: URL?

    init(
        fileManager: FileManager = .default,
        profilesDirectoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.explicitProfilesDirectoryURL = profilesDirectoryURL
    }

    func currentProfilesDirectoryURL() -> URL {
        if let explicitProfilesDirectoryURL {
            return explicitProfilesDirectoryURL
        }
        return Self.resolveProfilesDirectory(fileManager: fileManager)
    }

    func listProfiles() throws -> [AudioProfile] {
        let profilesDirectoryURL = currentProfilesDirectoryURL()
        let entries = try fileManager.contentsOfDirectory(
            at: profilesDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        return try entries
            .filter { url in
                let ext = url.pathExtension.lowercased()
                return ext == "yml" || ext == "yaml"
            }
            .filter { url in
                let values = try url.resourceValues(forKeys: [.isRegularFileKey])
                return values.isRegularFile == true
            }
            .map { url in
                AudioProfile(name: url.lastPathComponent, fileURL: url)
            }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    func loadProfile(named name: String) throws -> String {
        guard isSafeProfileName(name) else {
            throw ProfileStoreError.unsafeProfileName
        }

        let profilesDirectoryURL = currentProfilesDirectoryURL()
        let profileURL = profilesDirectoryURL.appendingPathComponent(name)
        return try String(contentsOf: profileURL, encoding: .utf8)
    }

    private func isSafeProfileName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("..")
    }

    private static func resolveProfilesDirectory(fileManager: FileManager) -> URL {
        var candidates: [URL] = []
        let env = ProcessInfo.processInfo.environment

        if let explicitProfilesPath = env["WAVE_DAEMON_PROFILES_DIR"], !explicitProfilesPath.isEmpty {
            candidates.append(URL(fileURLWithPath: explicitProfilesPath, isDirectory: true).standardizedFileURL)
        }

        if let repoRoot = env["WAVE_DAEMON_REPO_ROOT"], !repoRoot.isEmpty {
            candidates.append(URL(fileURLWithPath: repoRoot, isDirectory: true).appendingPathComponent("dsp/profiles"))
        }

        if let sourceRoot = env["SRCROOT"], !sourceRoot.isEmpty {
            candidates.append(
                URL(fileURLWithPath: sourceRoot, isDirectory: true)
                    .appendingPathComponent("dsp/profiles")
                    .standardizedFileURL
            )
        }

        if let projectDirectory = env["PROJECT_DIR"], !projectDirectory.isEmpty {
            candidates.append(
                URL(fileURLWithPath: projectDirectory, isDirectory: true)
                    .appendingPathComponent("../dsp/profiles")
                    .standardizedFileURL
            )
        }

        if let configPath = env["CAMILLADSP_CONFIG"], !configPath.isEmpty {
            let configURL = URL(fileURLWithPath: configPath).standardizedFileURL
            let dspDirectory = configURL.deletingLastPathComponent()
            candidates.append(dspDirectory.appendingPathComponent("profiles"))
        }

        if let configPathFromProcess = resolveConfigPathFromRunningProcess(fileManager: fileManager) {
            let configURL = URL(fileURLWithPath: configPathFromProcess).standardizedFileURL
            let dspDirectory = configURL.deletingLastPathComponent()
            candidates.append(dspDirectory.appendingPathComponent("profiles"))
        }

        if let repoRootFromSource = resolveRepoRootFromSourcePath(fileManager: fileManager) {
            candidates.append(repoRootFromSource.appendingPathComponent("dsp/profiles"))
        }

        for repoRoot in resolveHomeBasedRepoRoots(fileManager: fileManager) {
            candidates.append(repoRoot.appendingPathComponent("dsp/profiles"))
        }

        if let configPathFromState = resolveConfigPathFromStateFile(fileManager: fileManager, env: env) {
            let configURL = URL(fileURLWithPath: configPathFromState).standardizedFileURL
            let dspDirectory = configURL.deletingLastPathComponent()
            candidates.append(dspDirectory.appendingPathComponent("profiles"))
        }

        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        candidates.append(cwd.appendingPathComponent("dsp/profiles"))
        candidates.append(cwd.appendingPathComponent("../dsp/profiles").standardizedFileURL)

        if let bundledProfiles = Bundle.main.resourceURL?.appendingPathComponent("dsp/profiles") {
            candidates.append(bundledProfiles)
        }

        if let matched = candidates.first(where: { directoryExists($0, fileManager: fileManager) }) {
            return matched
        }

        return candidates.first ?? cwd.appendingPathComponent("dsp/profiles")
    }

    private static func directoryExists(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    private static func resolveConfigPathFromStateFile(
        fileManager: FileManager,
        env: [String: String]
    ) -> String? {
        let stateFileCandidates = resolveStateFileCandidates(fileManager: fileManager, env: env)

        for candidate in stateFileCandidates {
            guard fileManager.isReadableFile(atPath: candidate.path) else {
                continue
            }

            guard let content = try? String(contentsOf: candidate, encoding: .utf8) else {
                continue
            }

            for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.hasPrefix("config_path:") else {
                    continue
                }

                let value = line.dropFirst("config_path:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    return String(value)
                }
            }
        }

        return nil
    }

    private static func resolveStateFileCandidates(
        fileManager: FileManager,
        env: [String: String]
    ) -> [URL] {
        var candidates: [URL] = []

        if let explicitStatePath = env["CAMILLADSP_STATEFILE"], !explicitStatePath.isEmpty {
            candidates.append(URL(fileURLWithPath: explicitStatePath).standardizedFileURL)
        }

        if let runtimeDirectory = env["CAMILLADSP_RUNTIME_DIR"], !runtimeDirectory.isEmpty {
            candidates.append(
                URL(fileURLWithPath: runtimeDirectory, isDirectory: true)
                    .appendingPathComponent("state.json")
                    .standardizedFileURL
            )
        }

        if let repoRoot = env["WAVE_DAEMON_REPO_ROOT"], !repoRoot.isEmpty {
            candidates.append(
                URL(fileURLWithPath: repoRoot, isDirectory: true)
                    .appendingPathComponent(".runtime/state.json")
                    .standardizedFileURL
            )
        }

        if let repoRootFromSource = resolveRepoRootFromSourcePath(fileManager: fileManager) {
            candidates.append(repoRootFromSource.appendingPathComponent(".runtime/state.json"))
        }

        for repoRoot in resolveHomeBasedRepoRoots(fileManager: fileManager) {
            candidates.append(repoRoot.appendingPathComponent(".runtime/state.json"))
        }

        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        candidates.append(cwd.appendingPathComponent(".runtime/state.json"))
        candidates.append(cwd.appendingPathComponent("../.runtime/state.json").standardizedFileURL)

        return candidates
    }

    private static func resolveConfigPathFromRunningProcess(fileManager: FileManager) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-fal", "camilladsp"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        for rawLine in content.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.localizedCaseInsensitiveContains("camilladsp"),
                  !line.contains(" --check ")
            else {
                continue
            }

            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard !tokens.isEmpty else {
                continue
            }

            if let optionIndex = tokens.firstIndex(of: "--config"),
               tokens.indices.contains(optionIndex + 1) {
                let configPath = tokens[optionIndex + 1]
                if fileManager.isReadableFile(atPath: configPath) {
                    return configPath
                }
            }

            if let configToken = tokens.last(where: { token in
                token.hasSuffix(".yml") || token.hasSuffix(".yaml")
            }), fileManager.isReadableFile(atPath: configToken) {
                return configToken
            }
        }

        return nil
    }

    private static func resolveRepoRootFromSourcePath(fileManager: FileManager) -> URL? {
        let sourceURL = URL(fileURLWithPath: #filePath).standardizedFileURL
        var directory = sourceURL.deletingLastPathComponent()

        if directory.lastPathComponent == "WaveDaemon" {
            directory.deleteLastPathComponent()
        }

        if directory.lastPathComponent == "app" {
            let repoRoot = directory.deletingLastPathComponent()
            guard repoRoot.path != "/" else {
                return nil
            }

            let expectedProfiles = repoRoot.appendingPathComponent("dsp/profiles")
            if directoryExists(expectedProfiles, fileManager: fileManager) {
                return repoRoot
            }
        }

        return nil
    }

    private static func resolveHomeBasedRepoRoots(fileManager: FileManager) -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Coding_Space/wavedaemon"),
            home.appendingPathComponent("CodingSpace/wavedaemon"),
            home.appendingPathComponent("Developer/wavedaemon"),
            home.appendingPathComponent("Code/wavedaemon"),
            home.appendingPathComponent("code/wavedaemon"),
            home.appendingPathComponent("wavedaemon"),
        ]

        return candidates.filter { candidate in
            directoryExists(candidate, fileManager: fileManager)
        }
    }
}
