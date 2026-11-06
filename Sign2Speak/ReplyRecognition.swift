import Foundation

enum ReplyRecognitionState: Equatable {
    case idle, preparing, listening, finishing
}

enum ReplyRecognitionFailure: Error, Equatable, Sendable {
    case speechPermissionDenied, microphonePermissionDenied
    case onDeviceUnavailable, serviceUnavailable, microphoneUnavailable, failed

    var message: String {
        switch self {
        case .speechPermissionDenied: return "Allow Speech Recognition in Settings to show spoken replies."
        case .microphonePermissionDenied: return "Allow Microphone access in Settings to hear spoken replies."
        case .onDeviceUnavailable: return "On-device English recognition is unavailable on this iPhone. Check your English dictation settings and try again."
        case .serviceUnavailable: return "Speech recognition is unavailable right now. Please try again."
        case .microphoneUnavailable: return "The microphone could not start. Check your audio connection and try again."
        case .failed: return "Transcription stopped. You can read the words captured so far or try again."
        }
    }

    var opensSettings: Bool { self == .speechPermissionDenied || self == .microphonePermissionDenied }
}

enum ReplyRecognitionEvent: Sendable {
    case started
    // Partial hypotheses replace the previous text; they must not be appended.
    case text(String)
    case finished
    case failed(ReplyRecognitionFailure)
}

@MainActor
protocol ReplyRecognitionDriver: AnyObject {
    func start(id: UUID, progress: @escaping @MainActor (ReplyRecognitionEvent) -> Void) async throws
    func finish(id: UUID)
    // Returns after microphone/tap teardown; late recognizer callbacks are ignored.
    func cancel(id: UUID)
}

struct ReplyRecognitionMeasurement: Codable {
    let id: UUID
    let locale: String
    var requestedAt = Date()
    var endedAt: Date?
    var characterCount = 0
    var outcome = "preparing"
    // No audio, transcript or native error strings belong in this measurement.
}
