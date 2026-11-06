import AVFoundation
import Foundation

// The controller serializes this service with capture and native inference.
@MainActor
final class LocalSpeechDriver: NSObject, SpeechDriver, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var active: (key: ObjectIdentifier, progress: @MainActor (SpeechEvent) -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(id: UUID, text: String, progress: @escaping @MainActor (SpeechEvent) -> Void) throws -> SpeechVoice {
        guard active == nil, !synthesizer.isSpeaking else { throw SpeechFailure.busy }
        // Choose from voices exposed by the device, preferring the basic English voice.
        let voices = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.identifier.hasPrefix("com.apple.") && $0.language.hasPrefix("en-")
                && !$0.voiceTraits.contains(.isPersonalVoice) && !$0.voiceTraits.contains(.isNoveltyVoice)
        }
        let voice = voices.first { $0.language == "en-US" && $0.quality == .default }
            ?? voices.first { $0.quality == .default } ?? voices.first
        guard let voice else { throw SpeechFailure.noVoice }
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try audio.setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        active = (ObjectIdentifier(utterance), progress)
        synthesizer.speak(utterance)
        return SpeechVoice(identifier: voice.identifier, language: voice.language)
    }

    func stop() {
        guard let active else { return }
        if !synthesizer.stopSpeaking(at: .immediate) {
            complete(key: active.key, event: .cancelled)
        }
    }

    private func complete(key: ObjectIdentifier, event: SpeechEvent) {
        guard let active, active.key == key else { return }
        self.active = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        active.progress(event)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, self.active?.key == key else { return }
            self.active?.progress(.started)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.complete(key: key, event: .finished) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.complete(key: key, event: .cancelled) }
    }

    private enum SpeechFailure: LocalizedError {
        case busy, noVoice
        var errorDescription: String? {
            switch self {
            case .busy: return "Wait for speech to stop before replaying."
            case .noVoice: return "No English speech voice is available. Install one in Settings → Accessibility → Spoken Content → Voices."
            }
        }
    }
}
