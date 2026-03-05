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
    private let reverbMixRenderer = ReverbMixRenderer()

    @State private var websocketURL = DSPManager.defaultWebSocketURLString()
    @State private var profiles: [AudioProfile] = []
    @State private var selectedProfileName = ""
    @State private var reverbStyle: ReverbStyle = .vocalPlate
    @State private var reverbQuality: ReverbQuality = .high
    @State private var reverbWetPercent: Double = 28.0
    @State private var reverbDryPercent: Double = 86.0
    @State private var lastDryProfileName = "flat.yml"
    @State private var volumeDB: Double = 0
    @State private var statusMessage = "Disconnected"
    @State private var isDSPRunning = false
    @State private var isStartingDSP = false
    @State private var isConnecting = false
    @State private var lastReportedExitStatus: Int32?

    private let brandCyan = Color(red: 0.23, green: 0.73, blue: 0.94)
    private let brandAmber = Color(red: 0.98, green: 0.72, blue: 0.28)
    private let brandEmerald = Color(red: 0.27, green: 0.83, blue: 0.60)
    private let brandCrimson = Color(red: 0.92, green: 0.37, blue: 0.36)
    private let shellTop = Color(red: 0.05, green: 0.07, blue: 0.10)
    private let shellBottom = Color(red: 0.09, green: 0.11, blue: 0.16)
    private let panelFill = Color.white.opacity(0.055)

    private var engineStatusText: String {
        if isStartingDSP {
            return "Starting"
        }
        return isDSPRunning ? "Running" : "Stopped"
    }

    private var engineStatusColor: Color {
        isDSPRunning ? brandEmerald : brandCrimson
    }

    private var sessionStatusText: String {
        if isConnecting {
            return "Connecting"
        }
        return camilla.isConnected ? "Connected" : "Idle"
    }

    private var sessionStatusColor: Color {
        if isConnecting {
            return brandAmber
        }
        return camilla.isConnected ? brandCyan : Color.white.opacity(0.45)
    }

    private var selectedProfileSummary: String {
        selectedProfileName.isEmpty ? "No profile loaded" : selectedProfileName
    }

    private var dryBaselineSummary: String {
        lastDryProfileName.isEmpty ? "Unset" : lastDryProfileName
    }

    private var reverbBlendSummary: String {
        "\(Int(reverbWetPercent.rounded()))% wet / \(Int(reverbDryPercent.rounded()))% dry"
    }

    private var volumeDisplayText: String {
        volumeDB.formatted(.number.precision(.fractionLength(1))) + " dB"
    }

    private var busStatusText: String {
        if !camilla.isConnected {
            return "Offline"
        }
        return camilla.isMuted ? "Muted" : "Live"
    }

    private var busStatusColor: Color {
        if !camilla.isConnected {
            return Color.white.opacity(0.45)
        }
        return camilla.isMuted ? brandAmber : brandEmerald
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                backgroundView

                ScrollView {
                    VStack(spacing: 22) {
                        heroPanel
                        dashboardPanels(for: geometry.size.width)
                        statusPanel
                    }
                    .padding(28)
                    .frame(maxWidth: 1200)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(minWidth: 900, minHeight: 780)
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
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: isDSPRunning)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: camilla.isConnected)
    }

    private var backgroundView: some View {
        ZStack {
            LinearGradient(
                colors: [shellTop, shellBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(brandCyan.opacity(0.15))
                .frame(width: 420, height: 420)
                .blur(radius: 110)
                .offset(x: -330, y: -250)

            Circle()
                .fill(brandAmber.opacity(0.10))
                .frame(width: 360, height: 360)
                .blur(radius: 120)
                .offset(x: 360, y: 320)

            Circle()
                .fill(brandEmerald.opacity(0.08))
                .frame(width: 300, height: 300)
                .blur(radius: 120)
                .offset(x: 220, y: -280)
        }
        .ignoresSafeArea()
    }

    private var heroPanel: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("WaveDaemon")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.96))

                    Text("A studio-grade control surface for system-wide spatial DSP on macOS.")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.68))

                    signalPathView
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 12) {
                    StatusBadge(
                        title: "ENGINE",
                        value: engineStatusText,
                        tint: engineStatusColor,
                        valueIdentifier: "dspStateText"
                    )

                    StatusBadge(
                        title: "SESSION",
                        value: sessionStatusText,
                        tint: sessionStatusColor,
                        valueIdentifier: "connectionStateText"
                    )
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    dspControlCluster
                    connectionCluster
                }

                VStack(spacing: 16) {
                    dspControlCluster
                    connectionCluster
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("WebSocket Endpoint")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.56))
                    .tracking(1.0)

                TextField("WebSocket URL", text: $websocketURL)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .background(fieldBackground)
                    .accessibilityIdentifier("websocketURLField")
            }
        }
        .panelCard(fill: LinearGradient(
            colors: [
                Color.white.opacity(0.08),
                Color.white.opacity(0.03),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        ))
    }

    private var signalPathView: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                signalNode("System DSP Output")
                signalArrow
                signalNode("BlackHole 2ch")
                signalArrow
                signalNode("CamillaDSP")
                signalArrow
                signalNode("DSP Aggregate")
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    signalNode("System DSP Output")
                    signalArrow
                    signalNode("BlackHole 2ch")
                }
                HStack(spacing: 10) {
                    signalNode("CamillaDSP")
                    signalArrow
                    signalNode("DSP Aggregate")
                }
            }
        }
    }

    private func signalNode(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.84))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.18))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(0.06))
                    )
            )
    }

    private var signalArrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white.opacity(0.40))
    }

    private var dspControlCluster: some View {
        VStack(alignment: .leading, spacing: 12) {
            clusterLabel("DSP CONTROL", symbol: "waveform.path.ecg.rectangle")

            HStack(spacing: 12) {
                Button("Start DSP", action: startDSP)
                    .buttonStyle(PrimaryActionButtonStyle(tint: brandCyan))
                    .disabled(isStartingDSP || isDSPRunning)
                    .accessibilityIdentifier("startDSPButton")

                Button("Stop DSP", action: stopDSP)
                    .buttonStyle(SecondaryActionButtonStyle())
                    .disabled(!isDSPRunning)
                    .accessibilityIdentifier("stopDSPButton")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var connectionCluster: some View {
        VStack(alignment: .leading, spacing: 12) {
            clusterLabel("CONNECTION", symbol: "bolt.horizontal.circle")

            HStack(spacing: 12) {
                Button("Connect", action: connect)
                    .buttonStyle(PrimaryActionButtonStyle(tint: brandEmerald))
                    .disabled(camilla.isConnected || isConnecting)
                    .accessibilityIdentifier("connectButton")

                Button("Disconnect", action: disconnect)
                    .buttonStyle(SecondaryActionButtonStyle())
                    .disabled(!camilla.isConnected)
                    .accessibilityIdentifier("disconnectButton")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func clusterLabel(_ title: String, symbol: String) -> some View {
        Label {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .tracking(1.1)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(0.60))
    }

    @ViewBuilder
    private func dashboardPanels(for width: CGFloat) -> some View {
        if width >= 1120 {
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 20) {
                    profilePanel
                    outputPanel
                }
                .frame(width: 360)

                VStack(spacing: 20) {
                    reverbPanel
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            VStack(spacing: 20) {
                profilePanel
                reverbPanel
                outputPanel
            }
        }
    }

    private var profilePanel: some View {
        sectionCard(
            title: "Profiles",
            subtitle: "Swap processing signatures instantly and keep a reliable dry baseline ready.",
            symbol: "square.stack.3d.up"
        ) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    MetricTile(
                        title: "Selected",
                        value: selectedProfileSummary,
                        detail: "Current tone stack",
                        tint: brandCyan
                    )

                    MetricTile(
                        title: "Dry Baseline",
                        value: dryBaselineSummary,
                        detail: "\(profiles.count) available profiles",
                        tint: brandAmber
                    )
                }

                LabeledPicker(title: "Profile") {
                    Picker("Profile", selection: $selectedProfileName) {
                        ForEach(profiles) { profile in
                            Text(profile.name).tag(profile.name)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(profiles.isEmpty)
                    .accessibilityIdentifier("profilePicker")
                }

                HStack(spacing: 12) {
                    Button("Apply Profile", action: applyProfile)
                        .buttonStyle(PrimaryActionButtonStyle(tint: brandAmber))
                        .disabled(!camilla.isConnected || selectedProfileName.isEmpty)
                        .accessibilityIdentifier("applyProfileButton")

                    Button("Refresh", action: loadProfiles)
                        .buttonStyle(SecondaryActionButtonStyle())
                        .accessibilityIdentifier("refreshProfilesButton")
                }
            }
        }
    }

    private var reverbPanel: some View {
        sectionCard(
            title: "Reverb Lab",
            subtitle: "Shape the space, audition the blend, and commit the room live without touching the core DSP flow.",
            symbol: "sparkles.rectangle.stack"
        ) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    MetricTile(
                        title: "Style",
                        value: reverbStyle.rawValue,
                        detail: reverbQuality.rawValue + " quality",
                        tint: brandCyan
                    )

                    MetricTile(
                        title: "Blend",
                        value: reverbBlendSummary,
                        detail: "Wet / dry balance",
                        tint: brandEmerald
                    )
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        reverbStylePicker
                        reverbQualityPicker
                    }

                    VStack(spacing: 12) {
                        reverbStylePicker
                        reverbQualityPicker
                    }
                }

                HStack(spacing: 12) {
                    Button("Apply Reverb", action: applyReverb)
                        .buttonStyle(PrimaryActionButtonStyle(tint: brandCyan))
                        .disabled(!camilla.isConnected)
                        .accessibilityIdentifier("applyReverbButton")

                    Button("Bypass Reverb", action: bypassReverb)
                        .buttonStyle(SecondaryActionButtonStyle())
                        .disabled(!camilla.isConnected)
                        .accessibilityIdentifier("bypassReverbButton")
                }

                sliderCard(
                    title: "Wet Mix",
                    valueText: "\(Int(reverbWetPercent.rounded()))%",
                    tint: brandCyan,
                    slider: {
                        ConsoleSlider(
                            value: $reverbWetPercent,
                            range: 0...100,
                            step: 1,
                            tint: brandCyan,
                            label: "Wet Mix"
                        )
                            .accessibilityIdentifier("reverbWetSlider")
                    }
                )

                sliderCard(
                    title: "Dry Anchor",
                    valueText: "\(Int(reverbDryPercent.rounded()))%",
                    tint: brandEmerald,
                    slider: {
                        ConsoleSlider(
                            value: $reverbDryPercent,
                            range: 0...100,
                            step: 1,
                            tint: brandEmerald,
                            label: "Dry Anchor"
                        )
                            .accessibilityIdentifier("reverbDrySlider")
                    }
                )

                Text("High quality uses generated *_hq impulse responses when available.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.58))
            }
        }
    }

    private var reverbStylePicker: some View {
        LabeledPicker(title: "Style") {
            Picker("Style", selection: $reverbStyle) {
                ForEach(ReverbStyle.allCases) { style in
                    Text(style.rawValue).tag(style)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.large)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("reverbStylePicker")
        }
    }

    private var reverbQualityPicker: some View {
        LabeledPicker(title: "Quality") {
            Picker("Quality", selection: $reverbQuality) {
                ForEach(ReverbQuality.allCases) { quality in
                    Text(quality.rawValue).tag(quality)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.large)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("reverbQualityPicker")
        }
    }

    private var outputPanel: some View {
        sectionCard(
            title: "Master Output",
            subtitle: "Trim gain, commit level updates, and mute the bus without losing the current session state.",
            symbol: "dial.high"
        ) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Output Level")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .tracking(1.0)
                            .foregroundStyle(.white.opacity(0.55))

                        Text(volumeDisplayText)
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.95))
                            .contentTransition(.numericText())
                            .accessibilityIdentifier("volumeLabel")
                    }

                    Spacer()

                    StatusBadge(
                        title: "BUS",
                        value: busStatusText,
                        tint: busStatusColor
                    )
                }

                sliderCard(
                    title: "Volume",
                    valueText: volumeDisplayText,
                    tint: brandAmber,
                    slider: {
                        ConsoleSlider(
                            value: $volumeDB,
                            range: -60...12,
                            step: 0.5,
                            tint: brandAmber,
                            label: "Volume",
                            onEditingChanged: handleVolumeEditing
                        )
                        .disabled(!camilla.isConnected)
                        .accessibilityIdentifier("volumeSlider")
                    }
                )

                HStack(spacing: 12) {
                    Button("Set Volume", action: sendVolume)
                        .buttonStyle(PrimaryActionButtonStyle(tint: brandAmber))
                        .disabled(!camilla.isConnected)
                        .accessibilityIdentifier("setVolumeButton")

                    Button(camilla.isMuted ? "Unmute" : "Mute", action: toggleMute)
                        .buttonStyle(SecondaryActionButtonStyle())
                        .disabled(!camilla.isConnected)
                        .accessibilityIdentifier("toggleMuteButton")
                }
            }
        }
    }

    private var statusPanel: some View {
        sectionCard(
            title: "Status Feed",
            subtitle: "Live route, connection, and control messages from the audio engine.",
            symbol: "text.bubble"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Circle()
                        .fill((statusMessage.lowercased().contains("failed") || statusMessage.lowercased().contains("error"))
                              ? brandCrimson
                              : brandCyan)
                        .frame(width: 10, height: 10)
                        .shadow(color: brandCyan.opacity(0.30), radius: 8)
                        .padding(.top, 4)

                    Text(statusMessage)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.88))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("statusMessageText")
                }

                if let error = camilla.lastErrorMessage,
                   !error.isEmpty,
                   error != statusMessage {
                    Divider()
                        .overlay(Color.white.opacity(0.06))

                    Text(error)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.black.opacity(0.22))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06))
            )
    }

    private func sectionCard<Content: View>(
        title: String,
        subtitle: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(brandAmber)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(0.18))
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.95))

                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.58))
                }
            }

            content()
        }
        .panelCard(fill: panelFill)
    }

    private func sliderCard<SliderContent: View>(
        title: String,
        valueText: String,
        tint: Color,
        @ViewBuilder slider: () -> SliderContent
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))

                Spacer()

                Text(valueText)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(tint.opacity(0.18))
                    )
            }

            slider()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.05))
                )
        )
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
        performReverbApply(profile)
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

    private func performReverbApply(_ profile: AudioProfile) {
        Task {
            do {
                let profileText = try String(contentsOf: profile.fileURL, encoding: .utf8)
                let mixedConfig = try reverbMixRenderer.renderMixedConfig(
                    profileURL: profile.fileURL,
                    profileText: profileText,
                    wetPercent: reverbWetPercent,
                    dryPercent: reverbDryPercent
                )
                try await camilla.applyProfile(configText: mixedConfig)
                statusMessage = """
                Applied reverb: \(profile.name) \
                (Wet \(Int(reverbWetPercent.rounded()))%, Dry \(Int(reverbDryPercent.rounded()))%)
                """
            } catch {
                statusMessage = "Reverb apply failed: \(error.localizedDescription)"
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

private struct StatusBadge: View {
    let title: String
    let value: String
    let tint: Color
    var valueIdentifier = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(1.0)
                .foregroundStyle(.white.opacity(0.52))

            HStack(spacing: 8) {
                Circle()
                    .fill(tint)
                    .frame(width: 9, height: 9)
                    .shadow(color: tint.opacity(0.45), radius: 8)

                Text(value)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .modifier(OptionalAccessibilityIdentifier(identifier: valueIdentifier))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06))
                )
        )
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let detail: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .tracking(1.0)
                .foregroundStyle(.white.opacity(0.52))

            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.94))
                .lineLimit(2)

            Text(detail)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.56))

            Capsule(style: .continuous)
                .fill(tint.opacity(0.75))
                .frame(width: 44, height: 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.05))
                )
        )
    }
}

private struct LabeledPicker<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .tracking(1.0)
                .foregroundStyle(.white.opacity(0.52))

            content
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.black.opacity(0.18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.05))
                        )
                )
        }
    }
}

private struct ConsoleSlider: View {
    @Binding var value: Double

    let range: ClosedRange<Double>
    let step: Double
    let tint: Color
    let label: String
    var onEditingChanged: ((Bool) -> Void)? = nil

    @Environment(\.isEnabled) private var isEnabled
    @State private var isEditing = false

    private let thumbSize: CGFloat = 26
    private let trackHeight: CGFloat = 10

    private var normalizedValue: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        return CGFloat((clamped - range.lowerBound) / span)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let progressWidth = max(thumbSize / 2, width * normalizedValue)
            let thumbOffset = max(0, min(width - thumbSize, (width * normalizedValue) - (thumbSize / 2)))

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(isEnabled ? 0.12 : 0.06))
                    .frame(height: trackHeight)

                HStack(spacing: 0) {
                    ForEach(0..<30, id: \.self) { index in
                        Capsule(style: .continuous)
                            .fill(index.isMultiple(of: 3) ? Color.white.opacity(0.16) : Color.white.opacity(0.08))
                            .frame(width: 2, height: index.isMultiple(of: 3) ? 4 : 3)
                        if index < 29 {
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 24)

                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                tint.opacity(isEnabled ? 0.55 : 0.18),
                                tint.opacity(isEnabled ? 0.95 : 0.28),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: progressWidth, height: trackHeight)

                Circle()
                    .fill(tint.opacity(isEnabled ? 0.24 : 0.10))
                    .frame(width: thumbSize + 14, height: thumbSize + 14)
                    .blur(radius: isEditing ? 4 : 7)
                    .offset(x: thumbOffset - 7)

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isEnabled ? 0.98 : 0.50),
                                Color.white.opacity(isEnabled ? 0.72 : 0.34),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(Color.black.opacity(0.16), lineWidth: 1)
                    )
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: Color.black.opacity(0.22), radius: 8, y: 4)
                    .offset(x: thumbOffset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(dragGesture(for: width))
        }
        .frame(height: 34)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }

            switch direction {
            case .increment:
                value = quantizedValue(value + step)
            case .decrement:
                value = quantizedValue(value - step)
            @unknown default:
                break
            }
        }
    }

    private var accessibilityValue: String {
        if step < 1 {
            return value.formatted(.number.precision(.fractionLength(1)))
        }
        return "\(Int(value.rounded()))"
    }

    private func dragGesture(for width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                guard isEnabled else { return }

                if !isEditing {
                    isEditing = true
                    onEditingChanged?(true)
                }

                updateValue(at: gesture.location.x, width: width)
            }
            .onEnded { gesture in
                guard isEnabled else { return }

                updateValue(at: gesture.location.x, width: width)
                if isEditing {
                    isEditing = false
                    onEditingChanged?(false)
                }
            }
    }

    private func updateValue(at x: CGFloat, width: CGFloat) {
        let progress = min(max(0, x / max(width, 1)), 1)
        let rawValue = range.lowerBound + (range.upperBound - range.lowerBound) * Double(progress)
        value = quantizedValue(rawValue)
    }

    private func quantizedValue(_ rawValue: Double) -> Double {
        let clamped = min(max(rawValue, range.lowerBound), range.upperBound)
        guard step > 0 else { return clamped }
        let steps = ((clamped - range.lowerBound) / step).rounded()
        let quantized = range.lowerBound + (steps * step)
        return min(max(quantized, range.lowerBound), range.upperBound)
    }
}

private struct OptionalAccessibilityIdentifier: ViewModifier {
    let identifier: String

    func body(content: Content) -> some View {
        if identifier.isEmpty {
            content
        } else {
            content.accessibilityIdentifier(identifier)
        }
    }
}

private struct PrimaryActionButtonStyle: ButtonStyle {
    let tint: Color

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(isEnabled ? 0.96 : 0.55))
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: isEnabled
                                ? [
                                    tint.opacity(configuration.isPressed ? 0.65 : 0.95),
                                    tint.opacity(configuration.isPressed ? 0.45 : 0.72),
                                ]
                                : [
                                    Color.white.opacity(0.08),
                                    Color.white.opacity(0.06),
                                ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(isEnabled ? 0.08 : 0.04))
                    )
            )
            .shadow(color: tint.opacity(isEnabled ? 0.22 : 0.0), radius: 14, y: 8)
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }
}

private struct SecondaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(isEnabled ? 0.92 : 0.42))
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(isEnabled ? 0.08 : 0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(isEnabled ? 0.08 : 0.04))
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }
}

private struct PanelCardModifier<S: ShapeStyle>: ViewModifier {
    let fill: S

    func body(content: Content) -> some View {
        content
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10))
                    )
            )
            .shadow(color: Color.black.opacity(0.22), radius: 28, y: 18)
    }
}

private extension View {
    func panelCard<S: ShapeStyle>(fill: S) -> some View {
        modifier(PanelCardModifier(fill: fill))
    }
}

#Preview {
    ContentView()
}
