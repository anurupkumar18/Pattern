import AVFoundation

/// Brief spoken progress via the system voice (zero-setup TTS per the plan).
/// Progress messages, not chain-of-thought: one short phrase per state change.
@MainActor
final class Narrator {
    private let synthesizer = AVSpeechSynthesizer()
    var isEnabled = true

    func say(_ text: String) {
        guard isEnabled else { return }
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(AVSpeechUtterance(string: text))
    }
}
