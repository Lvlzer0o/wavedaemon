import SwiftUI
import Combine

private enum WaveDaemonPalette {
    static let brandCyan = Color(red: 0.23, green: 0.73, blue: 0.94)
    static let brandAmber = Color(red: 0.98, green: 0.72, blue: 0.28)
    static let brandEmerald = Color(red: 0.27, green: 0.83, blue: 0.60)
    static let brandCrimson = Color(red: 0.92, green: 0.37, blue: 0.36)
    static let shellTop = Color(red: 0.05, green: 0.07, blue: 0.10)
    static let shellBottom = Color(red: 0.09, green: 0.11, blue: 0.16)
    static let panelFill = Color.white.opacity(0.055)
}

struct ContentView: View {
    enum ReverbStyle: String, CaseIterable, Identifiable {
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

    enum ReverbQuality: String, CaseIterable, Identifiable {
        case standard = "Standard"
        case high = "High"

        var id: String { rawValue }
    }

    @State private var camilla = CamillaWebSocket()

    private let profileStore = ProfileStore()
    private let dspManager = DSPManager.shared
    private let reverbMixRenderer = ReverbMixRenderer()

    @AppStorage(WaveDaemonPreferences.Keys.preferredWebSocketURL)
    private var websocketURL = WaveDaemonPreferences.defaultWebSocketURLString()
    @AppStorage(WaveDaemonPreferences.Keys.autoRouteSystemOutput)
    private var autoRouteSystemOutput = WaveDaemonPreferences.defaultAutoRouteSystemOutput()
    @AppStorage(WaveDaemonPreferences.Keys.processingOutputDevice)
    private var processingOutputDevice = WaveDaemonPreferences.defaultProcessingOutputDevice()
    @AppStorage(WaveDaemonPreferences.Keys.autoConnectOnLaunch)
    private var autoConnectOnLaunch = false

    @State private var profiles: [AudioProfile] = []
    @State private var selectedProfileName = ""
    @State private var lastDryProfileName = "flat.yml"
    @State private var websocketURLInput = WaveDaemonPreferences.currentWebSocketURL()
    @State private var statusMessage = "Disconnected"
    @State private var isStartingDSP = false
    @State private var isConnecting = false
    @State private var didAttemptAutoConnect = false
    @State private var expectedShutdownDeadline: Date?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                WaveDaemonBackground()

                ScrollView {
                    VStack(spacing: 22) {
                        HeroPanel(
                            websocketURL: $websocketURLInput,
                            camilla: camilla,
                            dspManager: dspManager,
                            isStartingDSP: isStartingDSP,
                            isConnecting: isConnecting,
                            onStartDSP: startDSP,
                            onStopDSP: stopDSP,
                            onConnect: connect,
                            onDisconnect: disconnect,
                            onUnexpectedExit: handleUnexpectedDSPExit
                        )
                        dashboardPanels(for: geometry.size.width)
                        StatusFeedPanel(statusMessage: statusMessage, camilla: camilla)
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
            reconcileStoredWebSocketPreference()
            syncRuntimePreferences()
            loadProfiles()
            attemptAutoConnectIfNeeded()
        }
        .onChange(of: websocketURL) {
            if websocketURLInput != websocketURL {
                websocketURLInput = websocketURL
            }
            syncRuntimePreferences()
        }
        .onChange(of: websocketURLInput) {
            persistWebSocketURLInputIfSafe()
        }
        .onChange(of: autoRouteSystemOutput) {
            syncRuntimePreferences()
        }
        .onChange(of: processingOutputDevice) {
            syncRuntimePreferences()
        }
    }

    @ViewBuilder
    private func dashboardPanels(for width: CGFloat) -> some View {
        if width >= 1120 {
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 20) {
                    ProfilePanel(
                        camilla: camilla,
                        profiles: profiles,
                        selectedProfileName: $selectedProfileName,
                        lastDryProfileName: lastDryProfileName,
                        onApply: applyProfile,
                        onRefresh: loadProfiles
                    )
                    MasterOutputPanel(
                        camilla: camilla,
                        onSetVolume: sendVolume,
                        onToggleMute: toggleMute
                    )
                }
                .frame(width: 360)

                VStack(spacing: 20) {
                    ReverbLabPanel(
                        camilla: camilla,
                        onApply: applyReverb,
                        onBypass: bypassReverb
                    )
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            VStack(spacing: 20) {
                ProfilePanel(
                    camilla: camilla,
                    profiles: profiles,
                    selectedProfileName: $selectedProfileName,
                    lastDryProfileName: lastDryProfileName,
                    onApply: applyProfile,
                    onRefresh: loadProfiles
                )
                ReverbLabPanel(
                    camilla: camilla,
                    onApply: applyReverb,
                    onBypass: bypassReverb
                )
                MasterOutputPanel(
                    camilla: camilla,
                    onSetVolume: sendVolume,
                    onToggleMute: toggleMute
                )
            }
        }
    }

    private func handleUnexpectedDSPExit(_ exitStatus: Int32) {
        if let deadline = expectedShutdownDeadline, deadline > Date() {
            expectedShutdownDeadline = nil
            return
        }

        expectedShutdownDeadline = nil

        if camilla.isConnected {
            camilla.disconnect()
        }

        statusMessage = "CamillaDSP exited unexpectedly (\(exitStatus))"
    }

    private func startDSP() {
        guard !isStartingDSP else { return }

        expectedShutdownDeadline = nil
        isStartingDSP = true

        Task {
            defer { isStartingDSP = false }

            do {
                let started = try dspManager.startDSP()

                if started {
                    if let routingMessage = dspManager.lastRoutingMessage, !routingMessage.isEmpty {
                        statusMessage = "CamillaDSP started. \(routingMessage)"
                    } else {
                        statusMessage = "CamillaDSP started"
                    }
                } else {
                    statusMessage = "CamillaDSP already running"
                }
            } catch {
                statusMessage = "Failed to start DSP: \(error.localizedDescription)"
            }
        }
    }

    private func stopDSP() {
        let didStop = dspManager.stopDSP()
        expectedShutdownDeadline = didStop ? Date().addingTimeInterval(2.0) : nil

        if camilla.isConnected {
            camilla.disconnect()
        }

        let baseMessage = didStop ? "CamillaDSP stopped" : "CamillaDSP was not running"
        if let routingMessage = dspManager.lastRoutingMessage, !routingMessage.isEmpty {
            statusMessage = "\(baseMessage). \(routingMessage)"
        } else {
            statusMessage = baseMessage
        }
    }

    private func connect() {
        guard !isConnecting else { return }

        expectedShutdownDeadline = nil
        isConnecting = true

        Task {
            defer { isConnecting = false }

            do {
                let connectionURL = WaveDaemonPreferences.normalizedWebSocketURL(from: websocketURLInput)
                    ?? websocketURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
                let storageBehavior = WaveDaemonPreferences.webSocketURLStorageBehavior(from: websocketURLInput)
                let managesLocalDSP = shouldManageLocalDSP(for: connectionURL)
                let routingMessage = managesLocalDSP ? dspManager.ensureProcessingRoute() : nil

                if managesLocalDSP && !dspManager.isDSPRunning && !dspManager.isWebSocketReachable(timeout: 0.2) {
                    do {
                        _ = try dspManager.startDSP()
                        try await Task.sleep(for: .milliseconds(350))
                    } catch {
                        if !dspManager.isWebSocketReachable(timeout: 0.2) {
                            throw error
                        }
                        statusMessage = "Using existing CamillaDSP instance"
                    }
                }

                try await camilla.connect(urlString: connectionURL)
                try await camilla.refreshState()

                let persistenceSuffix: String
                switch storageBehavior {
                case .sessionOnly(_):
                    persistenceSuffix = " Endpoint not saved."
                case .invalid, .persistent(_):
                    persistenceSuffix = ""
                }

                if let routingMessage, !routingMessage.isEmpty {
                    statusMessage = "Connected to CamillaDSP. \(routingMessage)\(persistenceSuffix)"
                } else {
                    statusMessage = "Connected to CamillaDSP.\(persistenceSuffix)"
                }
            } catch {
                statusMessage = "Connection failed: \(error.localizedDescription)"
            }
        }
    }

    private func disconnect() {
        camilla.disconnect()
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

    private func applyReverb(
        style: ReverbStyle,
        quality: ReverbQuality,
        wetPercent: Double,
        dryPercent: Double
    ) {
        guard camilla.isConnected else {
            statusMessage = "Connect to CamillaDSP first"
            return
        }

        guard let profile = resolvedReverbProfile(for: style, quality: quality) else {
            statusMessage = "No reverb profile found for \(style.rawValue) (\(quality.rawValue))"
            return
        }

        selectedProfileName = profile.name
        performReverbApply(profile, wetPercent: wetPercent, dryPercent: dryPercent)
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

    private func performReverbApply(_ profile: AudioProfile, wetPercent: Double, dryPercent: Double) {
        Task {
            do {
                let profileText = try String(contentsOf: profile.fileURL, encoding: .utf8)
                let mixedConfig = try reverbMixRenderer.renderMixedConfig(
                    profileURL: profile.fileURL,
                    profileText: profileText,
                    wetPercent: wetPercent,
                    dryPercent: dryPercent
                )
                try await camilla.applyProfile(configText: mixedConfig)
                statusMessage = """
                Applied reverb: \(profile.name) \
                (Wet \(Int(wetPercent.rounded()))%, Dry \(Int(dryPercent.rounded()))%)
                """
            } catch {
                statusMessage = "Reverb apply failed: \(error.localizedDescription)"
            }
        }
    }

    private func resolvedReverbProfile(for style: ReverbStyle, quality: ReverbQuality) -> AudioProfile? {
        let preferredNames = preferredReverbProfileNames(for: style, quality: quality)
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

    private func sendVolume(_ value: Double) {
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

    private func syncRuntimePreferences() {
        dspManager.applyPreferences()
    }

    private func reconcileStoredWebSocketPreference() {
        let persistedURL = WaveDaemonPreferences.currentWebSocketURL()

        if websocketURL != persistedURL {
            websocketURL = persistedURL
        }

        if websocketURLInput != persistedURL {
            websocketURLInput = persistedURL
        }
    }

    private func persistWebSocketURLInputIfSafe() {
        guard let persistedURL = WaveDaemonPreferences.persistableWebSocketURL(from: websocketURLInput) else {
            return
        }

        if websocketURL != persistedURL {
            websocketURL = persistedURL
        }

        if websocketURLInput != persistedURL {
            websocketURLInput = persistedURL
        }
    }

    private func shouldManageLocalDSP(for urlString: String) -> Bool {
        guard let endpoint = WaveDaemonPreferences.parseWebSocketEndpoint(from: urlString) else {
            return false
        }

        switch endpoint.host.lowercased() {
        case "127.0.0.1", "localhost", "::1":
            return true
        default:
            return false
        }
    }

    private func attemptAutoConnectIfNeeded() {
        guard autoConnectOnLaunch, !didAttemptAutoConnect else {
            return
        }

        didAttemptAutoConnect = true
        connect()
    }
}

private struct WaveDaemonBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [WaveDaemonPalette.shellTop, WaveDaemonPalette.shellBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(WaveDaemonPalette.brandCyan.opacity(0.15))
                .frame(width: 420, height: 420)
                .blur(radius: 110)
                .offset(x: -330, y: -250)

            Circle()
                .fill(WaveDaemonPalette.brandAmber.opacity(0.10))
                .frame(width: 360, height: 360)
                .blur(radius: 120)
                .offset(x: 360, y: 320)

            Circle()
                .fill(WaveDaemonPalette.brandEmerald.opacity(0.08))
                .frame(width: 300, height: 300)
                .blur(radius: 120)
                .offset(x: 220, y: -280)
        }
        .ignoresSafeArea()
    }
}

private struct HeroPanel: View {
    @Binding var websocketURL: String
    @ObservedObject var camilla: CamillaWebSocket

    let isStartingDSP: Bool
    let isConnecting: Bool
    let onStartDSP: () -> Void
    let onStopDSP: () -> Void
    let onConnect: () -> Void
    let onDisconnect: () -> Void

    @StateObject private var engineStatus: EngineStatusMonitor

    init(
        websocketURL: Binding<String>,
        camilla: CamillaWebSocket,
        dspManager: DSPManager,
        isStartingDSP: Bool,
        isConnecting: Bool,
        onStartDSP: @escaping () -> Void,
        onStopDSP: @escaping () -> Void,
        onConnect: @escaping () -> Void,
        onDisconnect: @escaping () -> Void,
        onUnexpectedExit: @escaping (Int32) -> Void
    ) {
        _websocketURL = websocketURL
        _camilla = ObservedObject(wrappedValue: camilla)
        self.isStartingDSP = isStartingDSP
        self.isConnecting = isConnecting
        self.onStartDSP = onStartDSP
        self.onStopDSP = onStopDSP
        self.onConnect = onConnect
        self.onDisconnect = onDisconnect
        _engineStatus = StateObject(
            wrappedValue: EngineStatusMonitor(
                dspManager: dspManager,
                onUnexpectedExit: onUnexpectedExit
            )
        )
    }

    private var engineStatusText: String {
        if isStartingDSP {
            return "Starting"
        }
        return engineStatus.isRunning ? "Running" : "Stopped"
    }

    private var engineStatusColor: Color {
        engineStatus.isRunning ? WaveDaemonPalette.brandEmerald : WaveDaemonPalette.brandCrimson
    }

    private var sessionStatusText: String {
        if isConnecting {
            return "Connecting"
        }
        return camilla.isConnected ? "Connected" : "Idle"
    }

    private var sessionStatusColor: Color {
        if isConnecting {
            return WaveDaemonPalette.brandAmber
        }
        return camilla.isConnected ? WaveDaemonPalette.brandCyan : Color.white.opacity(0.45)
    }

    private var endpointStorageBehavior: WaveDaemonPreferences.WebSocketURLStorageBehavior {
        WaveDaemonPreferences.webSocketURLStorageBehavior(from: websocketURL)
    }

    private var endpointHint: String? {
        switch endpointStorageBehavior {
        case .invalid:
            return "Enter a valid ws:// or wss:// endpoint."
        case .sessionOnly(_):
            return "URLs with credentials, query strings, or fragments connect for this session only and are not saved."
        case .persistent(_):
            return nil
        }
    }

    private var endpointHintColor: Color {
        switch endpointStorageBehavior {
        case .invalid:
            return WaveDaemonPalette.brandCrimson
        case .sessionOnly(_):
            return WaveDaemonPalette.brandAmber
        case .persistent(_):
            return Color.white.opacity(0.56)
        }
    }

    var body: some View {
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

                if let endpointHint {
                    Text(endpointHint)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(endpointHintColor)
                }
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
        .onAppear {
            engineStatus.start()
        }
        .onDisappear {
            engineStatus.stop()
        }
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
                Button("Start DSP", action: onStartDSP)
                    .buttonStyle(PrimaryActionButtonStyle(tint: WaveDaemonPalette.brandCyan))
                    .disabled(isStartingDSP || engineStatus.isRunning)
                    .accessibilityIdentifier("startDSPButton")

                Button("Stop DSP", action: onStopDSP)
                    .buttonStyle(SecondaryActionButtonStyle())
                    .disabled(!engineStatus.isRunning)
                    .accessibilityIdentifier("stopDSPButton")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var connectionCluster: some View {
        VStack(alignment: .leading, spacing: 12) {
            clusterLabel("CONNECTION", symbol: "bolt.horizontal.circle")

            HStack(spacing: 12) {
                Button("Connect", action: onConnect)
                    .buttonStyle(PrimaryActionButtonStyle(tint: WaveDaemonPalette.brandEmerald))
                    .disabled(camilla.isConnected || isConnecting)
                    .accessibilityIdentifier("connectButton")

                Button("Disconnect", action: onDisconnect)
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

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.black.opacity(0.22))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06))
            )
    }
}

private struct ProfilePanel: View {
    @ObservedObject var camilla: CamillaWebSocket
    let profiles: [AudioProfile]
    @Binding var selectedProfileName: String
    let lastDryProfileName: String
    let onApply: () -> Void
    let onRefresh: () -> Void

    private var selectedProfileSummary: String {
        selectedProfileName.isEmpty ? "No profile loaded" : selectedProfileName
    }

    private var dryBaselineSummary: String {
        lastDryProfileName.isEmpty ? "Unset" : lastDryProfileName
    }

    var body: some View {
        SectionCard(
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
                        tint: WaveDaemonPalette.brandCyan
                    )

                    MetricTile(
                        title: "Dry Baseline",
                        value: dryBaselineSummary,
                        detail: "\(profiles.count) available profiles",
                        tint: WaveDaemonPalette.brandAmber
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
                    Button("Apply Profile", action: onApply)
                        .buttonStyle(PrimaryActionButtonStyle(tint: WaveDaemonPalette.brandAmber))
                        .disabled(!camilla.isConnected || selectedProfileName.isEmpty)
                        .accessibilityIdentifier("applyProfileButton")

                    Button("Refresh", action: onRefresh)
                        .buttonStyle(SecondaryActionButtonStyle())
                        .accessibilityIdentifier("refreshProfilesButton")
                }
            }
        }
    }
}

private struct ReverbLabPanel: View {
    @ObservedObject var camilla: CamillaWebSocket
    let onApply: (ContentView.ReverbStyle, ContentView.ReverbQuality, Double, Double) -> Void
    let onBypass: () -> Void

    @State private var reverbStyle: ContentView.ReverbStyle = .vocalPlate
    @State private var reverbQuality: ContentView.ReverbQuality = .high
    @State private var reverbWetPercent: Double = 28.0
    @State private var reverbDryPercent: Double = 86.0

    private var reverbBlendSummary: String {
        "\(Int(reverbWetPercent.rounded()))% wet / \(Int(reverbDryPercent.rounded()))% dry"
    }

    var body: some View {
        SectionCard(
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
                        tint: WaveDaemonPalette.brandCyan
                    )

                    MetricTile(
                        title: "Blend",
                        value: reverbBlendSummary,
                        detail: "Wet / dry balance",
                        tint: WaveDaemonPalette.brandEmerald
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
                    Button("Apply Reverb") {
                        onApply(reverbStyle, reverbQuality, reverbWetPercent, reverbDryPercent)
                    }
                    .buttonStyle(PrimaryActionButtonStyle(tint: WaveDaemonPalette.brandCyan))
                    .disabled(!camilla.isConnected)
                    .accessibilityIdentifier("applyReverbButton")

                    Button("Bypass Reverb", action: onBypass)
                        .buttonStyle(SecondaryActionButtonStyle())
                        .disabled(!camilla.isConnected)
                        .accessibilityIdentifier("bypassReverbButton")
                }

                SliderCard(
                    title: "Wet Mix",
                    valueText: "\(Int(reverbWetPercent.rounded()))%",
                    tint: WaveDaemonPalette.brandCyan
                ) {
                    ConsoleSlider(
                        value: $reverbWetPercent,
                        range: 0...100,
                        step: 1,
                        tint: WaveDaemonPalette.brandCyan,
                        label: "Wet Mix"
                    )
                    .accessibilityIdentifier("reverbWetSlider")
                }

                SliderCard(
                    title: "Dry Anchor",
                    valueText: "\(Int(reverbDryPercent.rounded()))%",
                    tint: WaveDaemonPalette.brandEmerald
                ) {
                    ConsoleSlider(
                        value: $reverbDryPercent,
                        range: 0...100,
                        step: 1,
                        tint: WaveDaemonPalette.brandEmerald,
                        label: "Dry Anchor"
                    )
                    .accessibilityIdentifier("reverbDrySlider")
                }

                Text("High quality uses generated *_hq impulse responses when available.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.58))
            }
        }
    }

    private var reverbStylePicker: some View {
        LabeledPicker(title: "Style") {
            Picker("Style", selection: $reverbStyle) {
                ForEach(ContentView.ReverbStyle.allCases) { style in
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
                ForEach(ContentView.ReverbQuality.allCases) { quality in
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
}

private struct MasterOutputPanel: View {
    @ObservedObject var camilla: CamillaWebSocket
    let onSetVolume: (Double) -> Void
    let onToggleMute: () -> Void

    @State private var draftVolume: Double
    @State private var isEditing = false

    init(
        camilla: CamillaWebSocket,
        onSetVolume: @escaping (Double) -> Void,
        onToggleMute: @escaping () -> Void
    ) {
        _camilla = ObservedObject(wrappedValue: camilla)
        self.onSetVolume = onSetVolume
        self.onToggleMute = onToggleMute
        _draftVolume = State(initialValue: camilla.currentVolume)
    }

    private var volumeDisplayText: String {
        draftVolume.formatted(.number.precision(.fractionLength(1))) + " dB"
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
        return camilla.isMuted ? WaveDaemonPalette.brandAmber : WaveDaemonPalette.brandEmerald
    }

    var body: some View {
        SectionCard(
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

                SliderCard(
                    title: "Volume",
                    valueText: volumeDisplayText,
                    tint: WaveDaemonPalette.brandAmber
                ) {
                    ConsoleSlider(
                        value: $draftVolume,
                        range: -60...12,
                        step: 0.5,
                        tint: WaveDaemonPalette.brandAmber,
                        label: "Volume",
                        onEditingChanged: handleVolumeEditing
                    )
                    .disabled(!camilla.isConnected)
                    .accessibilityIdentifier("volumeSlider")
                }

                HStack(spacing: 12) {
                    Button("Set Volume") {
                        onSetVolume(draftVolume)
                    }
                    .buttonStyle(PrimaryActionButtonStyle(tint: WaveDaemonPalette.brandAmber))
                    .disabled(!camilla.isConnected)
                    .accessibilityIdentifier("setVolumeButton")

                    Button(camilla.isMuted ? "Unmute" : "Mute", action: onToggleMute)
                        .buttonStyle(SecondaryActionButtonStyle())
                        .disabled(!camilla.isConnected)
                        .accessibilityIdentifier("toggleMuteButton")
                }
            }
        }
        .onChange(of: camilla.currentVolume) { _, newValue in
            guard !isEditing else { return }
            draftVolume = newValue
        }
        .onChange(of: camilla.isConnected) { _, isConnected in
            guard isConnected, !isEditing else { return }
            draftVolume = camilla.currentVolume
        }
    }

    private func handleVolumeEditing(_ editing: Bool) {
        isEditing = editing
        if !editing {
            onSetVolume(draftVolume)
        }
    }
}

private struct StatusFeedPanel: View {
    let statusMessage: String
    @ObservedObject var camilla: CamillaWebSocket

    var body: some View {
        SectionCard(
            title: "Status Feed",
            subtitle: "Live route, connection, and control messages from the audio engine.",
            symbol: "text.bubble"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Circle()
                        .fill(
                            (statusMessage.lowercased().contains("failed") || statusMessage.lowercased().contains("error"))
                            ? WaveDaemonPalette.brandCrimson
                            : WaveDaemonPalette.brandCyan
                        )
                        .frame(width: 10, height: 10)
                        .shadow(color: WaveDaemonPalette.brandCyan.opacity(0.30), radius: 8)
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
}

@MainActor
private final class EngineStatusMonitor: ObservableObject {
    @Published private(set) var isRunning = false

    private let dspManager: DSPManager
    private let onUnexpectedExit: (Int32) -> Void
    private var timer: Timer?
    private var lastReportedExitStatus: Int32?

    init(dspManager: DSPManager, onUnexpectedExit: @escaping (Int32) -> Void) {
        self.dspManager = dspManager
        self.onUnexpectedExit = onUnexpectedExit
    }

    func start() {
        guard timer == nil else { return }

        refresh()

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let wasRunning = isRunning
        let currentRunning = dspManager.isDSPRunning || dspManager.isWebSocketReachable(timeout: 0.05)

        if currentRunning != isRunning {
            isRunning = currentRunning
        }

        if wasRunning && !currentRunning,
           let exitStatus = dspManager.lastExitStatus,
           exitStatus != lastReportedExitStatus {
            lastReportedExitStatus = exitStatus
            onUnexpectedExit(exitStatus)
        }

        if currentRunning {
            lastReportedExitStatus = nil
        }
    }

    deinit {
        timer?.invalidate()
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
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: value)
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

private struct SectionCard<Content: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(WaveDaemonPalette.brandAmber)
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

            content
        }
        .panelCard(fill: WaveDaemonPalette.panelFill)
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

private struct SliderCard<SliderContent: View>: View {
    let title: String
    let valueText: String
    let tint: Color
    @ViewBuilder let slider: SliderContent

    var body: some View {
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

            slider
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

                SliderTickMarks()
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

private struct SliderTickMarks: View {
    private let tickCount = 30
    private let horizontalInset: CGFloat = 12

    var body: some View {
        Canvas { context, size in
            let usableWidth = max(size.width - (horizontalInset * 2), 1)
            var minorTicks = Path()
            var majorTicks = Path()

            for index in 0..<tickCount {
                let progress = tickCount == 1 ? 0 : CGFloat(index) / CGFloat(tickCount - 1)
                let x = horizontalInset + (usableWidth * progress)
                let height: CGFloat = index.isMultiple(of: 3) ? 4 : 3
                let rect = CGRect(
                    x: x - 1,
                    y: (size.height - height) / 2,
                    width: 2,
                    height: height
                )
                let path = Path(roundedRect: rect, cornerSize: CGSize(width: 1, height: 1))

                if index.isMultiple(of: 3) {
                    majorTicks.addPath(path)
                } else {
                    minorTicks.addPath(path)
                }
            }

            context.fill(minorTicks, with: .color(Color.white.opacity(0.08)))
            context.fill(majorTicks, with: .color(Color.white.opacity(0.16)))
        }
        .allowsHitTesting(false)
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
