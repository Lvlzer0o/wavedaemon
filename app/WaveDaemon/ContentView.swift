import SwiftUI
import Combine

struct ContentView: View {
    @StateObject private var camilla = CamillaWebSocket()

    private let profileStore = ProfileStore()
    private let dspManager = DSPManager.shared

    @State private var websocketURL = DSPManager.defaultWebSocketURLString()
    @State private var profiles: [AudioProfile] = []
    @State private var selectedProfileName = ""
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

        Task {
            do {
                let configText = try String(contentsOf: selectedProfile.fileURL, encoding: .utf8)
                try await camilla.applyProfile(configText: configText)
                statusMessage = "Applied profile: \(selectedProfileName)"
            } catch {
                statusMessage = "Profile apply failed: \(error.localizedDescription)"
            }
        }
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
