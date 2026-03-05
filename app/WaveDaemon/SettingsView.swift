import AppKit
import SwiftUI

struct SettingsView: View {
    @AppStorage(WaveDaemonPreferences.Keys.preferredWebSocketURL)
    private var preferredWebSocketURL = WaveDaemonPreferences.defaultWebSocketURLString()
    @AppStorage(WaveDaemonPreferences.Keys.autoRouteSystemOutput)
    private var autoRouteSystemOutput = WaveDaemonPreferences.defaultAutoRouteSystemOutput()
    @AppStorage(WaveDaemonPreferences.Keys.processingOutputDevice)
    private var processingOutputDevice = WaveDaemonPreferences.defaultProcessingOutputDevice()
    @AppStorage(WaveDaemonPreferences.Keys.autoConnectOnLaunch)
    private var autoConnectOnLaunch = false

    private let brandCyan = Color(red: 0.23, green: 0.73, blue: 0.94)
    private let brandAmber = Color(red: 0.98, green: 0.72, blue: 0.28)
    private let brandEmerald = Color(red: 0.27, green: 0.83, blue: 0.60)
    private let shellTop = Color(red: 0.05, green: 0.07, blue: 0.10)
    private let shellBottom = Color(red: 0.09, green: 0.11, blue: 0.16)

    private var endpointIsValid: Bool {
        WaveDaemonPreferences.parseWebSocketEndpoint(from: preferredWebSocketURL) != nil
    }

    private var effectiveConfigPath: String {
        DSPManager.shared.configurationFilePath
    }

    private var effectiveRuntimePath: String {
        DSPManager.shared.runtimeDirectoryPath
    }

    private var effectiveLogPath: String {
        DSPManager.shared.logFilePath
    }

    private var effectiveProfilesPath: String {
        ProfileStore().currentProfilesDirectoryURL().path
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [shellTop, shellBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    headerPanel
                    startupPanel
                    routingPanel
                    pathsPanel
                }
                .padding(24)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .frame(minWidth: 760, minHeight: 700)
        .onAppear {
            DSPManager.shared.applyPreferences()
        }
        .onChange(of: preferredWebSocketURL) { _ in
            DSPManager.shared.applyPreferences()
        }
        .onChange(of: autoRouteSystemOutput) { _ in
            DSPManager.shared.applyPreferences()
        }
        .onChange(of: processingOutputDevice) { _ in
            DSPManager.shared.applyPreferences()
        }
    }

    private var headerPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Studio Settings")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.95))

                    Text("Tune startup behavior, routing defaults, and the engine endpoint without touching code or launch environment.")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.66))
                }

                Spacer()

                SettingsBadge(
                    title: "ENDPOINT",
                    value: endpointIsValid ? "Valid" : "Check URL",
                    tint: endpointIsValid ? brandEmerald : brandAmber
                )
            }

            HStack(spacing: 12) {
                Button("Use Recommended Defaults", action: resetToDefaults)
                    .buttonStyle(SettingsPrimaryButtonStyle(tint: brandAmber))

                Text("Settings apply to the next start or connect action. Live sessions are not force-restarted.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.56))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsCard(fill: LinearGradient(
            colors: [
                Color.white.opacity(0.08),
                Color.white.opacity(0.03),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        ))
    }

    private var startupPanel: some View {
        settingsSection(
            title: "Startup",
            subtitle: "Define how the app should rejoin your studio session when it opens.",
            symbol: "power"
        ) {
            VStack(alignment: .leading, spacing: 18) {
                settingsField(title: "Preferred WebSocket URL") {
                    TextField("ws://127.0.0.1:1234", text: $preferredWebSocketURL)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(fieldBackground)
                }

                Toggle(isOn: $autoConnectOnLaunch) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Automatically connect on launch")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92))

                        Text("When enabled, WaveDaemon immediately attempts to reconnect to the preferred endpoint after opening.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.56))
                    }
                }
                .toggleStyle(.switch)
            }
        }
    }

    private var routingPanel: some View {
        settingsSection(
            title: "Routing",
            subtitle: "Choose how the app should steer macOS audio before starting or attaching to CamillaDSP.",
            symbol: "arrow.triangle.branch"
        ) {
            VStack(alignment: .leading, spacing: 18) {
                Toggle(isOn: $autoRouteSystemOutput) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Auto-route system output")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92))

                        Text("If enabled, WaveDaemon switches macOS output to the preferred processing device before start/connect.")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.56))
                    }
                }
                .toggleStyle(.switch)

                settingsField(title: "Preferred Output Device") {
                    TextField("System DSP Output", text: $processingOutputDevice)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(fieldBackground)
                }

                Text("Recommended for this project: `System DSP Output` feeding `BlackHole 2ch`, then CamillaDSP back out through `DSP Aggregate`.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.56))
            }
        }
    }

    private var pathsPanel: some View {
        settingsSection(
            title: "Resolved Paths",
            subtitle: "Read-only references for the current studio environment this build is using.",
            symbol: "folder"
        ) {
            VStack(spacing: 14) {
                pathRow(
                    title: "DSP Config",
                    value: effectiveConfigPath,
                    buttonTitle: "Reveal",
                    action: { revealPath(effectiveConfigPath) }
                )

                pathRow(
                    title: "Profiles",
                    value: effectiveProfilesPath,
                    buttonTitle: "Open",
                    action: { openFolder(effectiveProfilesPath) }
                )

                pathRow(
                    title: "Runtime",
                    value: effectiveRuntimePath,
                    buttonTitle: "Open",
                    action: { openFolder(effectiveRuntimePath) }
                )

                pathRow(
                    title: "Log File",
                    value: effectiveLogPath,
                    buttonTitle: "Reveal",
                    action: { revealPath(effectiveLogPath) }
                )
            }
        }
    }

    private func settingsSection<Content: View>(
        title: String,
        subtitle: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(brandCyan)
                    .frame(width: 36, height: 36)
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
        .settingsCard(fill: Color.white.opacity(0.055))
    }

    private func settingsField<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .tracking(1.0)
                .foregroundStyle(.white.opacity(0.52))

            content()
        }
    }

    private func pathRow(
        title: String,
        value: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))

                Text(value)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.64))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(buttonTitle, action: action)
                .buttonStyle(SettingsSecondaryButtonStyle())
                .frame(width: 88)
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

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.black.opacity(0.22))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06))
            )
    }

    private func resetToDefaults() {
        WaveDaemonPreferences.resetToDefaults()
        DSPManager.shared.applyPreferences()
    }

    private func openFolder(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    private func revealPath(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

private struct SettingsBadge: View {
    let title: String
    let value: String
    let tint: Color

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
                    .shadow(color: tint.opacity(0.38), radius: 8)

                Text(value)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
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

private struct SettingsPrimaryButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.96))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                tint.opacity(configuration.isPressed ? 0.72 : 0.96),
                                tint.opacity(configuration.isPressed ? 0.48 : 0.72),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

private struct SettingsSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08))
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

private struct SettingsCardModifier<S: ShapeStyle>: ViewModifier {
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
    func settingsCard<S: ShapeStyle>(fill: S) -> some View {
        modifier(SettingsCardModifier(fill: fill))
    }
}

#Preview {
    SettingsView()
}
