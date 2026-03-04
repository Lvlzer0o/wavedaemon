import SwiftUI

struct ContentView: View {
    @State private var statusMessage = "DSP stopped"

    var body: some View {
        VStack(spacing: 16) {
            Text("WaveDaemon")
                .font(.title2)
                .bold()

            Text(statusMessage)
                .accessibilityIdentifier("dspStatusText")

            HStack(spacing: 12) {
                Button("Start DSP", action: startDSP)
                    .accessibilityIdentifier("startDSPButton")

                Button("Stop DSP", action: stopDSP)
                    .accessibilityIdentifier("stopDSPButton")
            }
        }
        .padding()
    }

    private func startDSP() {
        do {
            let didStart = try DSPManager.shared.startDSP()
            statusMessage = didStart ? "DSP running" : "DSP already running"
        } catch {
            statusMessage = "Failed to start DSP"
        }
    }

    private func stopDSP() {
        _ = DSPManager.shared.stopDSP()
        statusMessage = "DSP stopped"
    }
}

#Preview {
    ContentView()
}
