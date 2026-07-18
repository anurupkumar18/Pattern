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
            Button {
                coordinator.replayOrderRescueDemo()
            } label: {
                Label("Replay Tested Order Rescue", systemImage: "play.rectangle")
            }
            .disabled(coordinator.state != .idle)
            Divider()
            SettingsLink {
                Label("Voice & Intelligence Settings…", systemImage: "waveform.and.magnifyingglass")
            }
            Divider()
            Button("Quit VoiceOps") { NSApplication.shared.terminate(nil) }
        } label: {
            Image(systemName: "waveform.circle.fill")
        }

        Settings {
            VLMSettingsView()
        }
    }
}
