import SwiftUI
import Combine

struct ContentView: View {
    private enum ReverbStyle: String, CaseIterable, Identifiable {
        case smallRoom = "Small Room"
        case vocalPlate = "Vocal Plate"
        case largeHall = "Large Hall"

        var id: String { rawValue }

        var profileStem: String {
            switch self {
            case .smallRoom:
                return "small_room"
            case .vocalPlate:
                return "vocal_plate"
            case .largeHall:
                return "large_hall"
            }
        }
    }

    private enum ReverbQuality: String, CaseIterable, Identifiable {
        case standard = "Standard"
        case high = "High"

        var id: String { rawValue }
    }

    @StateObject private var camilla = CamillaWebSocket()

    private let profileStore = ProfileStore()
    private let dspManager = DSPManager.shared

    @State private var websocketURL = DSPManager.defaultWebSocketURLString()
    @State private var profiles: [AudioProfile] = []
    @State private var selectedProfileName = ""
    @State private var reverbStyle: ReverbStyle = .vocalPlate
    @State private var reverbQuality: ReverbQuality = .high
    @State private var lastDryProfileName = "flat.yml"
    @State private var volumeDB: Double = 0
    @State private var statusMessage = "Disconnected"
    @State private var isDSPRunning = false
    @State private var isStartingDSP = false
    @State private var isConnecting = false
    @State private var lastReportedExitStatus: Int32?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("WaveDaemon")
                .font(.title2)
                .bold()

            HStack(spacing: 12) {
                Button("Start DSP", action: startDSP)
                    .disabled(isStartingDSP || isDSPRunning)
                    .accessibilityIdentifier("startDSPButton")

                Button("Stop DSP", action: stopDSP)
                    .disabled(!isDSPRunning)
                    .accessibilityIdentifier("stopDSPButton")

                Text(isDSPRunning ? "DSP Running" : "DSP Stopped")
                    .foregroundStyle(isDSPRunning ? .green : .secondary)
                    .accessibilityIdentifier("dspStateText")
            }

            TextField("WebSocket URL", text: $websocketURL)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("websocketURLField")

            HStack(spacing: 12) {
                Button("Connect", action: connect)
                    .disabled(camilla.isConnected || isConnecting)
                    .accessibilityIdentifier("connectButton")

                Button("Disconnect", action: disconnect)
                    .disabled(!camilla.isConnected)
                    .accessibilityIdentifier("disconnectButton")

                Text(camilla.isConnected ? "Connected" : "Disconnected")
                    .foregroundStyle(camilla.isConnected ? .green : .secondary)
                    .accessibilityIdentifier("connectionStateText")
            }

            Divider()

            HStack(spacing: 12) {
                Picker("Profile", selection: $selectedProfileName) {
                    ForEach(profiles) { profile in
                        Text(profile.name).tag(profile.name)
                    }
                }
                .disabled(profiles.isEmpty)
                .accessibilityIdentifier("profilePicker")

                Button("Apply Profile", action: applyProfile)
                    .disabled(!camilla.isConnected || selectedProfileName.isEmpty)
                    .accessibilityIdentifier("applyProfileButton")

                Button("Refresh", action: loadProfiles)
                    .accessibilityIdentifier("refreshProfilesButton")
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Reverb")
                    .font(.headline)

                HStack(spacing: 12) {
                    Picker("Style", selection: $reverbStyle) {
                        ForEach(ReverbStyle.allCases) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                    .accessibilityIdentifier("reverbStylePicker")

                    Picker("Quality", selection: $reverbQuality) {
                        ForEach(ReverbQuality.allCases) { quality in
                            Text(quality.rawValue).tag(quality)
                        }
                    }
                    .accessibilityIdentifier("reverbQualityPicker")
                }

                HStack(spacing: 12) {
                    Button("Apply Reverb", action: applyReverb)
                        .disabled(!camilla.isConnected)
                        .accessibilityIdentifier("applyReverbButton")

                    Button("Bypass Reverb", action: bypassReverb)
                        .disabled(!camilla.isConnected)
                        .accessibilityIdentifier("bypassReverbButton")
                }

                Text("High quality uses generated *_hq impulse responses when available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Volume: \(volumeDB.formatted(.number.precision(.fractionLength(1)))) dB")
                    .accessibilityIdentifier("volumeLabel")

                Slider(
                    value: $volumeDB,
                    in: -60...12,
                    step: 0.5,
                    onEditingChanged: handleVolumeEditing
                )
                .disabled(!camilla.isConnected)
                .accessibilityIdentifier("volumeSlider")

                HStack(spacing: 12) {
                    Button("Set Volume", action: sendVolume)
                        .disabled(!camilla.isConnected)
                        .accessibilityIdentifier("setVolumeButton")

                    Button(camilla.isMuted ? "Unmute" : "Mute", action: toggleMute)
                        .disabled(!camilla.isConnected)
                        .accessibilityIdentifier("toggleMuteButton")
                }
            }

            Text(statusMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("statusMessageText")
        }
        .padding()
        .frame(minWidth: 520)
        .task {
            refreshDSPRunningState()
            loadProfiles()
        }
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            let wasRunning = isDSPRunning
            refreshDSPRunningState()

            if wasRunning && !isDSPRunning, let exitStatus = dspManager.lastExitStatus,
               exitStatus != lastReportedExitStatus {
                lastReportedExitStatus = exitStatus
                if camilla.isConnected {
                    camilla.disconnect()
                }
                statusMessage = "CamillaDSP exited unexpectedly (\(exitStatus))"
            }
        }
    }

    private func startDSP() {
        guard !isStartingDSP else { return }

        isStartingDSP = true
        Task {
            defer { isStartingDSP = false }

            do {
                let started = try dspManager.startDSP()
                refreshDSPRunningState()

                if started {
                    if let routingMessage = dspManager.lastRoutingMessage, !routingMessage.isEmpty {
                        statusMessage = "CamillaDSP started. \(routingMessage)"
                    } else {
                        statusMessage = "CamillaDSP started"
                    }
                    lastReportedExitStatus = nil
                } else {
                    statusMessage = "CamillaDSP already running"
                }
            } catch {
                refreshDSPRunningState()
                statusMessage = "Failed to start DSP: \(error.localizedDescription)"
            }
        }
    }

    private func stopDSP() {
        let didStop = dspManager.stopDSP()
        if camilla.isConnected {
            camilla.disconnect()
        }

        refreshDSPRunningState()
        let baseMessage = didStop ? "CamillaDSP stopped" : "CamillaDSP was not running"
        if let routingMessage = dspManager.lastRoutingMessage, !routingMessage.isEmpty {
            statusMessage = "\(baseMessage). \(routingMessage)"
        } else {
            statusMessage = baseMessage
        }
    }

    private func connect() {
        guard !isConnecting else { return }
        isConnecting = true

        Task {
            defer { isConnecting = false }

            do {
                let routingMessage = dspManager.ensureProcessingRoute()
                if !dspManager.isDSPRunning && !dspManager.isWebSocketReachable(timeout: 0.2) {
                    do {
                        _ = try dspManager.startDSP()
                        refreshDSPRunningState()
                        try await Task.sleep(for: .milliseconds(350))
                    } catch {
                        if !dspManager.isWebSocketReachable(timeout: 0.2) {
                            throw error
                        }
                        refreshDSPRunningState()
                        statusMessage = "Using existing CamillaDSP instance"
                    }
                } else {
                    refreshDSPRunningState()
                }

                try await camilla.connect(urlString: websocketURL)
                try await camilla.refreshState()
                volumeDB = camilla.currentVolume
                if let routingMessage, !routingMessage.isEmpty {
                    statusMessage = "Connected to CamillaDSP. \(routingMessage)"
                } else {
                    statusMessage = "Connected to CamillaDSP"
                }
            } catch {
                refreshDSPRunningState()
                statusMessage = "Connection failed: \(error.localizedDescription)"
            }
        }
    }

    private func disconnect() {
        camilla.disconnect()
        refreshDSPRunningState()
        statusMessage = "Disconnected"
    }

    private func loadProfiles() {
        do {
            profiles = try profileStore.listProfiles()
            if !profiles.contains(where: { $0.name == selectedProfileName }) {
                selectedProfileName = profiles.first?.name ?? ""
            }

            if let flatProfile = profiles.first(where: { $0.name == "flat.yml" }) {
                lastDryProfileName = flatProfile.name
            } else if !lastDryProfileName.isEmpty,
                      !profiles.contains(where: { $0.name == lastDryProfileName }) {
                lastDryProfileName = ""
            }

            if profiles.isEmpty {
                statusMessage = "No profiles found in dsp/profiles"
            }
        } catch {
            profiles = []
            selectedProfileName = ""
            statusMessage = """
            Failed to load profiles: \(error.localizedDescription)
            Path: \(profileStore.currentProfilesDirectoryURL().path)
            """
        }
    }

    private func applyProfile() {
        guard !selectedProfileName.isEmpty else {
            statusMessage = "Pick a profile first"
            return
        }

        guard let selectedProfile = profiles.first(where: { $0.name == selectedProfileName }) else {
            statusMessage = "Selected profile is no longer available. Refresh and try again."
            return
        }

        performProfileApply(
            selectedProfile,
            statusPrefix: "Applied profile",
            updateDryBaseline: !isReverbProfileName(selectedProfile.name)
        )
    }

    private func applyReverb() {
        guard camilla.isConnected else {
            statusMessage = "Connect to CamillaDSP first"
            return
        }

        guard let profile = resolvedReverbProfile() else {
            statusMessage = "No reverb profile found for \(reverbStyle.rawValue) (\(reverbQuality.rawValue))"
            return
        }

        selectedProfileName = profile.name
        performProfileApply(profile, statusPrefix: "Applied reverb", updateDryBaseline: false)
    }

    private func bypassReverb() {
        guard camilla.isConnected else {
            statusMessage = "Connect to CamillaDSP first"
            return
        }

        let fallbackNames = [lastDryProfileName, "flat.yml", "laptop_speakers.yml"]
        guard let profile = fallbackNames
            .compactMap({ name in profiles.first(where: { $0.name == name }) })
            .first else {
            statusMessage = "No dry profile found. Select a profile and click Apply Profile."
            return
        }

        selectedProfileName = profile.name
        performProfileApply(profile, statusPrefix: "Bypassed reverb with", updateDryBaseline: true)
    }

    private func performProfileApply(
        _ profile: AudioProfile,
        statusPrefix: String,
        updateDryBaseline: Bool
    ) {
        Task {
            do {
                let configText = try String(contentsOf: profile.fileURL, encoding: .utf8)
                try await camilla.applyProfile(configText: configText)
                if updateDryBaseline && !isReverbProfileName(profile.name) {
                    lastDryProfileName = profile.name
                }
                statusMessage = "\(statusPrefix): \(profile.name)"
            } catch {
                statusMessage = "Profile apply failed: \(error.localizedDescription)"
            }
        }
    }

    private func resolvedReverbProfile() -> AudioProfile? {
        let preferredNames = preferredReverbProfileNames(for: reverbStyle, quality: reverbQuality)
        return preferredNames.compactMap { name in
            profiles.first(where: { $0.name == name })
        }.first
    }

    private func preferredReverbProfileNames(
        for style: ReverbStyle,
        quality: ReverbQuality
    ) -> [String] {
        let standardName = "\(style.profileStem).yml"
        switch quality {
        case .standard:
            return [standardName]
        case .high:
            return ["\(style.profileStem)_hq.yml", standardName]
        }
    }

    private func isReverbProfileName(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return normalized.contains("small_room")
            || normalized.contains("vocal_plate")
            || normalized.contains("large_hall")
    }

    private func handleVolumeEditing(_ editing: Bool) {
        if !editing {
            sendVolume()
        }
    }

    private func sendVolume() {
        let value = volumeDB
        Task {
            do {
                try await camilla.setVolume(value)
                statusMessage = "Volume set to \(value.formatted(.number.precision(.fractionLength(1)))) dB"
            } catch {
                statusMessage = "Volume update failed: \(error.localizedDescription)"
            }
        }
    }

    private func toggleMute() {
        Task {
            do {
                let muted = try await camilla.toggleMute()
                statusMessage = muted ? "Muted" : "Unmuted"
            } catch {
                statusMessage = "Mute toggle failed: \(error.localizedDescription)"
            }
        }
    }

    private func refreshDSPRunningState() {
        isDSPRunning = dspManager.isDSPRunning || dspManager.isWebSocketReachable(timeout: 0.05)
    }
}

#Preview {
    ContentView()
}
