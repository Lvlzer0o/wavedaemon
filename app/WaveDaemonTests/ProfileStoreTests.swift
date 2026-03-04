import XCTest
@testable import WaveDaemon

final class ProfileStoreTests: XCTestCase {
    private var tempDirectoryURL: URL!

    override func setUpWithError() throws {
        tempDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WaveDaemonTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectoryURL {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
    }

    func testListProfilesReturnsOnlyYamlFilesSortedByName() throws {
        try "flat".write(to: tempDirectoryURL.appendingPathComponent("flat.yml"), atomically: true, encoding: .utf8)
        try "bass".write(to: tempDirectoryURL.appendingPathComponent("bass_boost.yml"), atomically: true, encoding: .utf8)
        try "laptop".write(to: tempDirectoryURL.appendingPathComponent("laptop.yaml"), atomically: true, encoding: .utf8)
        try "ignore".write(to: tempDirectoryURL.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let store = ProfileStore(profilesDirectoryURL: tempDirectoryURL)
        let names = try store.listProfiles().map(\.name)

        XCTAssertEqual(names, ["bass_boost.yml", "flat.yml", "laptop.yaml"])
    }

    func testLoadProfileRejectsUnsafePathTraversalName() throws {
        let store = ProfileStore(profilesDirectoryURL: tempDirectoryURL)

        XCTAssertThrowsError(try store.loadProfile(named: "../secret.yml"))
    }
}
