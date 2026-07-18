import SwiftUI
import VoiceOpsCore

@main
struct VoiceOpsApp: App {
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            if coordinator.state == .idle {
                Button("Start Listening  ⌃⌥V") { coordinator.toggle() }
            } else {
                Button("Stop") { coordinator.stop() }
            }
            Divider()
            Button("Quit VoiceOps") { NSApplication.shared.terminate(nil) }
        } label: {
            Image(systemName: "waveform.circle.fill")
        }
    }
}
