import XCTest
@testable import WaveDaemon

final class ReverbMixRendererTests: XCTestCase {
    func testRenderMixedConfigCreatesRuntimeIRAndRewritesFilename() throws {
        let renderer = ReverbMixRenderer()
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("wavedaemon-reverb-tests-\(UUID().uuidString)", isDirectory: true)

        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let profilesDir = tempRoot.appendingPathComponent("dsp/profiles", isDirectory: true)
        let irsDir = tempRoot.appendingPathComponent("dsp/irs", isDirectory: true)
        try FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: irsDir, withIntermediateDirectories: true)

        let sourceIRURL = irsDir.appendingPathComponent("vocal_plate_hq.wav")
        try renderer.writePCM16MonoWav(
            .init(sampleRate: 48_000, samples: [1000, 2000, -2000]),
            to: sourceIRURL
        )

        let profileURL = profilesDir.appendingPathComponent("vocal_plate_hq.yml")
        let profileText = """
        filters:
          convolution_placeholder:
            type: Conv
            parameters:
              type: Wav
              filename: "dsp/irs/vocal_plate_hq.wav"
              channel: 0
        """
        try profileText.write(to: profileURL, atomically: true, encoding: .utf8)

        let mixedConfig = try renderer.renderMixedConfig(
            profileURL: profileURL,
            profileText: profileText,
            wetPercent: 50,
            dryPercent: 25
        )

        let mixedIRURL = tempRoot
            .appendingPathComponent(".runtime/irs", isDirectory: true)
            .appendingPathComponent("vocal_plate_hq_wet50_dry25.wav")

        XCTAssertTrue(mixedConfig.contains(mixedIRURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mixedIRURL.path))

        let mixedWav = try renderer.readPCM16MonoWav(at: mixedIRURL)
        XCTAssertEqual(mixedWav.sampleRate, 48_000)
        XCTAssertEqual(mixedWav.samples.count, 3)
        XCTAssertEqual(mixedWav.samples[0], 250)
        XCTAssertEqual(mixedWav.samples[1], 1000)
        XCTAssertEqual(mixedWav.samples[2], -1000)
    }

    func testRenderMixedConfigThrowsWhenProfileHasNoConvolutionFilename() throws {
        let renderer = ReverbMixRenderer()
        let profileURL = URL(fileURLWithPath: "/tmp/dsp/profiles/flat.yml")
        let profileText = "filters:\n  limiter:\n    type: Limiter\n"

        XCTAssertThrowsError(
            try renderer.renderMixedConfig(
                profileURL: profileURL,
                profileText: profileText,
                wetPercent: 50,
                dryPercent: 50
            )
        )
    }
}
