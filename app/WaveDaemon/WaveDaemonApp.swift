import AppKit
import SwiftUI

@main
struct WaveDaemonApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .background(WindowChromeConfigurator())
        }
        .defaultSize(width: 1180, height: 860)
        .windowStyle(.hiddenTitleBar)
    }
}

private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window)
        }
    }

    private func configure(window: NSWindow?) {
        guard let window else { return }

        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.toolbarStyle = .unifiedCompact
        window.backgroundColor = .clear
    }
}
