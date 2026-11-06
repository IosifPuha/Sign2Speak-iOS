import AVFoundation
import Foundation
import Speech

// Apple's system recognizer owns the ASR model. There is no cloud fallback.
@MainActor
final class LocalReplyRecognitionDriver: ReplyRecognitionDriver {
    private var activeID: UUID?
    private var progress: (@MainActor (ReplyRecognitionEvent) -> Void)?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var hasTap = false
    private var audioSessionActive = false
    private var finishing = false

    func start(id: UUID, progress: @escaping @MainActor (ReplyRecognitionEvent) -> Void) async throws {
        guard activeID == nil else { throw ReplyRecognitionFailure.serviceUnavailable }
        activeID = id
        self.progress = progress
        do {
            let authorization = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            try checkCurrent(id)
            guard authorization == .authorized else { throw ReplyRecognitionFailure.speechPermissionDenied }
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
                  recognizer.supportsOnDeviceRecognition else { throw ReplyRecognitionFailure.onDeviceUnavailable }
            guard recognizer.isAvailable else { throw ReplyRecognitionFailure.serviceUnavailable }
            let microphoneAllowed = await AVAudioApplication.requestRecordPermission()
            try checkCurrent(id)
            guard microphoneAllowed else { throw ReplyRecognitionFailure.microphonePermissionDenied }

            let audio = AVAudioSession.sharedInstance()
            do {
                try audio.setCategory(.record, mode: .measurement)
                try audio.setActive(true)
                audioSessionActive = true
            } catch { throw ReplyRecognitionFailure.microphoneUnavailable }
            let engine = AVAudioEngine()
            audioEngine = engine
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw ReplyRecognitionFailure.microphoneUnavailable
            }
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            request.addsPunctuation = true
            self.request = request
            self.recognizer = recognizer
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                // Append synchronously; never send AVAudioPCMBuffer across actors.
                request.append(buffer)
            }
            hasTap = true
            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                // Copy only Sendable values out of the recognition callback.
                let text = result.map { String($0.bestTranscription.formattedString.prefix(4_096)) }
                let final = result?.isFinal == true
                let failed = error != nil
                Task { @MainActor [weak self] in
                    self?.receive(id: id, text: text, final: final, failed: failed)
                }
            }
            engine.prepare()
            do { try engine.start() }
            catch { throw ReplyRecognitionFailure.microphoneUnavailable }
            progress(.started)
        } catch {
            if activeID == id { tearDown() }
            throw error
        }
    }

    func finish(id: UUID) {
        guard activeID == id, !finishing else { return }
        finishing = true
        stopMicrophone()
        request?.endAudio()
    }

    func cancel(id: UUID) {
        guard activeID == id else { return }
        tearDown()
    }

    private func checkCurrent(_ id: UUID) throws {
        try Task.checkCancellation()
        guard activeID == id else { throw CancellationError() }
    }

    private func receive(id: UUID, text: String?, final: Bool, failed: Bool) {
        guard activeID == id else { return }
        let callback = progress
        if let text { callback?(.text(text)) }
        // A text callback can finish/cancel the session (for example its limit).
        guard activeID == id else { return }
        if final || failed {
            let endedByUser = finishing
            tearDown()
            callback?(failed && !final && !endedByUser ? .failed(.failed) : .finished)
        }
    }

    private func stopMicrophone() {
        audioEngine?.stop()
        if hasTap { audioEngine?.inputNode.removeTap(onBus: 0); hasTap = false }
        if audioSessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioSessionActive = false
        }
    }

    private func tearDown() {
        activeID = nil
        progress = nil
        stopMicrophone()
        request?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        request = nil
        recognizer = nil
        audioEngine = nil
        finishing = false
    }
}
