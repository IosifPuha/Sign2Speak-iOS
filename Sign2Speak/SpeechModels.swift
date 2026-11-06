import Foundation

enum SpeechEvent: Sendable { case started, finished, cancelled }

struct SpeechVoice: Sendable {
    let identifier: String
    let language: String
}

@MainActor
protocol SpeechDriver: AnyObject {
    func speak(id: UUID, text: String, progress: @escaping @MainActor (SpeechEvent) -> Void) throws -> SpeechVoice
    func stop()
}

struct SpeechMeasurement: Codable {
    let id: UUID
    let source: String
    let characterCount: Int
    var requestedAt = Date()
    var endedAt: Date?
    var startupSeconds: Double? // Request to synthesizer didStart; not acoustic onset.
    var voiceIdentifier: String?
    var language: String?
    var outcome = "requested"
}
