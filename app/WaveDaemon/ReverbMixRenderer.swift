import Foundation

enum ReverbMixRendererError: LocalizedError {
    case missingConvolutionFilename
    case unsupportedWavFormat(String)
    case invalidWavFile(String)

    var errorDescription: String? {
        switch self {
        case .missingConvolutionFilename:
            return "Profile does not contain a convolution IR filename"
        case let .unsupportedWavFormat(reason):
            return "Unsupported IR format: \(reason)"
        case let .invalidWavFile(reason):
            return "Invalid IR file: \(reason)"
        }
    }
}

struct ReverbMixRenderer {
    struct PCM16MonoWav {
        let sampleRate: Int
        let samples: [Int16]
    }

    func renderMixedConfig(
        profileURL: URL,
        profileText: String,
        wetPercent: Double,
        dryPercent: Double
    ) throws -> String {
        let wet = max(0, min(100, wetPercent))
        let dry = max(0, min(100, dryPercent))

        let sourcePath = try extractConvolutionFilename(from: profileText)
        let sourceIRURL = try resolveSourceIRURL(path: sourcePath, profileURL: profileURL)
        let mixedIRURL = try renderMixedIR(
            sourceIRURL: sourceIRURL,
            profileURL: profileURL,
            wetPercent: wet,
            dryPercent: dry
        )

        return try replaceConvolutionFilename(in: profileText, with: mixedIRURL.path)
    }

    func readPCM16MonoWav(at url: URL) throws -> PCM16MonoWav {
        let data = try Data(contentsOf: url)
        guard data.count >= 44 else {
            throw ReverbMixRendererError.invalidWavFile("header too small")
        }

        guard data.prefix(4) == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8) else {
            throw ReverbMixRendererError.invalidWavFile("missing RIFF/WAVE header")
        }

        var offset = 12
        var fmtData: Data?
        var sampleData: Data?

        while offset + 8 <= data.count {
            let chunkID = data[offset..<offset + 4]
            let chunkSize = Int(readUInt32LE(from: data, offset: offset + 4))
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + chunkSize

            guard payloadEnd <= data.count else {
                throw ReverbMixRendererError.invalidWavFile("chunk extends past file")
            }

            if chunkID == Data("fmt ".utf8) {
                fmtData = Data(data[payloadStart..<payloadEnd])
            } else if chunkID == Data("data".utf8) {
                sampleData = Data(data[payloadStart..<payloadEnd])
            }

            offset = payloadEnd + (chunkSize % 2)
        }

        guard let fmtData else {
            throw ReverbMixRendererError.invalidWavFile("missing fmt chunk")
        }
        guard let sampleData else {
            throw ReverbMixRendererError.invalidWavFile("missing data chunk")
        }
        guard fmtData.count >= 16 else {
            throw ReverbMixRendererError.invalidWavFile("fmt chunk too short")
        }

        let audioFormat = Int(readUInt16LE(from: fmtData, offset: 0))
        let channels = Int(readUInt16LE(from: fmtData, offset: 2))
        let sampleRate = Int(readUInt32LE(from: fmtData, offset: 4))
        let bitsPerSample = Int(readUInt16LE(from: fmtData, offset: 14))

        guard audioFormat == 1 else {
            throw ReverbMixRendererError.unsupportedWavFormat("only PCM is supported")
        }
        guard channels == 1 else {
            throw ReverbMixRendererError.unsupportedWavFormat("only mono IR files are supported")
        }
        guard bitsPerSample == 16 else {
            throw ReverbMixRendererError.unsupportedWavFormat("only 16-bit PCM is supported")
        }
        guard sampleData.count % 2 == 0 else {
            throw ReverbMixRendererError.invalidWavFile("sample payload has odd byte count")
        }

        var samples: [Int16] = []
        samples.reserveCapacity(sampleData.count / 2)

        var index = sampleData.startIndex
        while index < sampleData.endIndex {
            let lo = UInt16(sampleData[index])
            let hi = UInt16(sampleData[index + 1]) << 8
            let value = Int16(bitPattern: hi | lo)
            samples.append(value)
            index += 2
        }

        return PCM16MonoWav(sampleRate: sampleRate, samples: samples)
    }

    func writePCM16MonoWav(_ wav: PCM16MonoWav, to url: URL) throws {
        guard wav.sampleRate > 0 else {
            throw ReverbMixRendererError.invalidWavFile("sample rate must be positive")
        }

        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let blockAlign: UInt16 = channels * (bitsPerSample / 8)
        let byteRate: UInt32 = UInt32(wav.sampleRate) * UInt32(blockAlign)
        let dataSize: UInt32 = UInt32(wav.samples.count * MemoryLayout<Int16>.size)
        let riffSize: UInt32 = 4 + (8 + 16) + (8 + dataSize)

        var data = Data()
        data.append("RIFF".data(using: .utf8)!)
        data.appendUInt32LE(riffSize)
        data.append("WAVE".data(using: .utf8)!)

        data.append("fmt ".data(using: .utf8)!)
        data.appendUInt32LE(16)
        data.appendUInt16LE(1)
        data.appendUInt16LE(channels)
        data.appendUInt32LE(UInt32(wav.sampleRate))
        data.appendUInt32LE(byteRate)
        data.appendUInt16LE(blockAlign)
        data.appendUInt16LE(bitsPerSample)

        data.append("data".data(using: .utf8)!)
        data.appendUInt32LE(dataSize)
        for sample in wav.samples {
            data.appendInt16LE(sample)
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private func renderMixedIR(
        sourceIRURL: URL,
        profileURL: URL,
        wetPercent: Double,
        dryPercent: Double
    ) throws -> URL {
        let sourceWav = try readPCM16MonoWav(at: sourceIRURL)

        let wetScale = wetPercent / 100.0
        let dryScale = dryPercent / 100.0
        let scaledSamples = applyWetDryMix(
            samples: sourceWav.samples,
            wetScale: wetScale,
            dryScale: dryScale
        )

        let stem = sourceIRURL.deletingPathExtension().lastPathComponent
        let wetTag = Int(wetPercent.rounded())
        let dryTag = Int(dryPercent.rounded())
        let mixedFileName = "\(stem)_wet\(wetTag)_dry\(dryTag).wav"
        let mixedIRURL = try runtimeIRDirectory(from: profileURL).appendingPathComponent(mixedFileName)

        try writePCM16MonoWav(
            PCM16MonoWav(sampleRate: sourceWav.sampleRate, samples: scaledSamples),
            to: mixedIRURL
        )

        return mixedIRURL
    }

    private func applyWetDryMix(samples: [Int16], wetScale: Double, dryScale: Double) -> [Int16] {
        guard !samples.isEmpty else {
            return samples
        }

        return samples.enumerated().map { index, sample in
            let scale = (index == 0) ? dryScale : wetScale
            let scaled = Int((Double(sample) * scale).rounded())
            return clampToInt16(scaled)
        }
    }

    private func runtimeIRDirectory(from profileURL: URL) throws -> URL {
        let repoRoot = profileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repoRoot.appendingPathComponent(".runtime/irs")
    }

    private func extractConvolutionFilename(from profileText: String) throws -> String {
        let regex = try NSRegularExpression(pattern: #"filename:\s*"([^"]+)""#)
        let fullRange = NSRange(profileText.startIndex..<profileText.endIndex, in: profileText)
        guard let match = regex.firstMatch(in: profileText, options: [], range: fullRange),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: profileText) else {
            throw ReverbMixRendererError.missingConvolutionFilename
        }
        return String(profileText[range])
    }

    private func replaceConvolutionFilename(in profileText: String, with newPath: String) throws -> String {
        let regex = try NSRegularExpression(pattern: #"filename:\s*"([^"]+)""#)
        let fullRange = NSRange(profileText.startIndex..<profileText.endIndex, in: profileText)
        guard let match = regex.firstMatch(in: profileText, options: [], range: fullRange),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: profileText) else {
            throw ReverbMixRendererError.missingConvolutionFilename
        }

        var updated = profileText
        updated.replaceSubrange(valueRange, with: newPath)
        return updated
    }

    private func resolveSourceIRURL(path: String, profileURL: URL) throws -> URL {
        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedPath.hasPrefix("/") {
            return URL(fileURLWithPath: normalizedPath).standardizedFileURL
        }

        let repoRoot = profileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if normalizedPath.hasPrefix("dsp/") {
            return repoRoot.appendingPathComponent(normalizedPath).standardizedFileURL
        }

        return profileURL
            .deletingLastPathComponent()
            .appendingPathComponent(normalizedPath)
            .standardizedFileURL
    }

    private func clampToInt16(_ value: Int) -> Int16 {
        if value > Int(Int16.max) { return Int16.max }
        if value < Int(Int16.min) { return Int16.min }
        return Int16(value)
    }

    private func readUInt16LE(from data: Data, offset: Int) -> UInt16 {
        let lo = UInt16(data[offset])
        let hi = UInt16(data[offset + 1]) << 8
        return lo | hi
    }

    private func readUInt32LE(from data: Data, offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1]) << 8
        let b2 = UInt32(data[offset + 2]) << 16
        let b3 = UInt32(data[offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0x00ff))
        append(UInt8((value >> 8) & 0x00ff))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0x000000ff))
        append(UInt8((value >> 8) & 0x000000ff))
        append(UInt8((value >> 16) & 0x000000ff))
        append(UInt8((value >> 24) & 0x000000ff))
    }

    mutating func appendInt16LE(_ value: Int16) {
        appendUInt16LE(UInt16(bitPattern: value))
    }
}
