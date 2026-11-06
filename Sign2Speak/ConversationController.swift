import Foundation
import SwiftUI

struct ConfirmedSignToken: Identifiable, Sendable {
    let id: UUID
    var text: String
    let captureID: UUID
    let originalCandidate: ClassifierCandidate
}

@MainActor
final class ConversationController: ObservableObject {
    static let tokenLimit = 32
    @Published private(set) var confirmedTokens: [ConfirmedSignToken] = []
    @Published private(set) var liveRecognition: ContinuousRecognitionFeedback?
    @Published private(set) var sentenceDraft = ""
    @Published private(set) var sentenceAvailable = false
    @Published private(set) var sentenceError: String?
    @Published private(set) var speaking = false
    @Published private(set) var speechStopping = false
    @Published private(set) var speechError: String?
    @Published private(set) var replyState: ReplyRecognitionState = .idle
    @Published private(set) var replyText = ""
    @Published private(set) var replyError: ReplyRecognitionFailure?
    private let replyDriver: (any ReplyRecognitionDriver)?
    private var replyID: UUID?
    private var replyTask: Task<Void, Never>?
    private var replyWatchdog: Task<Void, Never>?
    private var replyUnloading = false
    private var replyCancelled = false
    private let replyDurationSeconds: Double
    private let replyFinalizationSeconds: Double
    private var activeSpeechID: UUID?
    private var speechRequestedUptime: Double?
    private var speechStopWatchdog: Task<Void, Never>?
    private let speechDriver: (any SpeechDriver)?
    private var reviewedCaptureID: UUID?
    @Published var backend = "CPU"
    @Published var promptIndex = 0
    @Published var diagnosticContextTokens = SentenceGenerationPolicy.contextTokens
    @Published var diagnosticNativeProfiling = false
    @Published var diagnosticPromptStyle: SentencePromptStyle = .reference
    private var loadedDiagnosticPrompt: SentencePromptStyle = .reference
    @Published var captureMode: CaptureMode = .cameraOnly
    @Published var cameraFramesPerSecond = 20
    @Published var handTestScene: HandTestScene = .unspecified
    @Published private(set) var phase = "Idle"
    @Published private(set) var busy = false
    @Published private(set) var generating = false
    @Published private(set) var stopping = false
    @Published private(set) var restartRequired = false
    @Published private(set) var engineLoaded = false
    @Published private(set) var hasModel = false
    @Published private(set) var modelDownloadState: ModelDownloadState = .idle
    private let modelDownloader: (any ModelDownloading)?
    private var downloadTaskID: Int?
    private var ignoredDownloadTasks: Set<Int> = []
    @Published private(set) var cameraActive = false
    @Published private(set) var cameraStopping = false
    @Published private(set) var finishingSignCapture = false
    @Published private(set) var cameraMeasurement: CameraMeasurement?
    @Published private(set) var classifierActive = false
    @Published private(set) var classifierStopping = false
    @Published private(set) var classifierMeasurement: ClassifierMeasurement?
    @Published private(set) var response = ""
    @Published private(set) var report = DiagnosticsReport()
    @Published private(set) var checkpointError: String?
    let previousReport: String?
    let previousUnfinished: Bool

    static let prompts = ["HELLO", "WATER PLEASE", "NO LIKE MILK", "TOMORROW GO", "WATER WATER PLEASE", "drink", "drink drink", "drink milk tomorrow", "THIRSTY WATER PLEASE", "NO LIKE WATER", "YESTERDAY DRINK MILK", "HATE WAKE THIRSTY", "HATE WAKE HUNGRY", "HUNGRY WATER PLEASE"]
    private let runner: any SentenceGenerator
    let cameraDriver: (any CameraDriver)?
    private let classifierDriver: (any ClassifierDriver)?
    private let trainedClassifierDriver: (any ClassifierDriver)?
    private var activeClassifierDriver: (any ClassifierDriver)?
    private let cameraClassifierFactory: (@Sendable (UUID, FeatureEncoder.Encoded) -> any ClassifierDriver)?
    private let models: ModelStore
    private let reportURL: URL
    private let cacheDirectory: URL
    private var requestID: UUID?
    private var requestedStopReason: String?
    private var releaseWhenFinished = false
    private var sessionStarted = false
    private var lastCheckpoint = 0.0
    private var generationWatchdog: Task<Void, Never>?
    private var cancellationWatchdog: Task<Void, Never>?
    private var cameraStopReason: String?
    private var generateAfterContinuousCapture = false
    private var continuousCaptureWatchdog: Task<Void, Never>?
    private var classifierStopReason: String?
    private var classifierWatchdog: Task<Void, Never>?
    private let cancellationGraceSeconds: Int

    init(runner: any SentenceGenerator, camera: (any CameraDriver)? = nil, classifier: (any ClassifierDriver)? = nil,
         speech: (any SpeechDriver)? = nil, reply: (any ReplyRecognitionDriver)? = nil,
         modelDownloader: (any ModelDownloading)? = nil,
         trainedClassifier: (any ClassifierDriver)? = nil,
         cameraClassifierFactory: (@Sendable (UUID, FeatureEncoder.Encoded) -> any ClassifierDriver)? = nil,
         supportDirectory: URL? = nil, manifest: ModelManifest = .gemma,
         generationTimeoutSeconds: Int = 30, cancellationGraceSeconds: Int = 10,
         classifierTimeoutSeconds: Int = 30, replyDurationSeconds: Double = 60,
         replyFinalizationSeconds: Double = 3) {
        precondition(generationTimeoutSeconds > 0 && cancellationGraceSeconds > 0 && classifierTimeoutSeconds > 0)
        self.runner = runner
        precondition(replyDurationSeconds > 0 && replyFinalizationSeconds > 0)
        replyDriver = reply
        self.replyDurationSeconds = replyDurationSeconds
        self.replyFinalizationSeconds = replyFinalizationSeconds
        speechDriver = speech
        cameraDriver = camera
        classifierDriver = classifier
        trainedClassifierDriver = trainedClassifier
        self.cameraClassifierFactory = cameraClassifierFactory
        self.cancellationGraceSeconds = cancellationGraceSeconds
        let support = supportDirectory ?? AppStorage.supportDirectory(in:
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
        let modelDirectory = support.appendingPathComponent("Models", isDirectory: true)
        models = ModelStore(directory: modelDirectory, manifest: manifest)
        self.modelDownloader = modelDownloader ?? (supportDirectory == nil
            ? BackgroundModelDownloader(directory: support.appendingPathComponent("Downloads"), manifest: manifest) : nil)
        reportURL = support.appendingPathComponent("report.json")
        cacheDirectory = supportDirectory?.appendingPathComponent("Cache") ?? AppStorage.cacheDirectory(in:
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0])
        let previous = try? Data(contentsOf: reportURL)
        previousReport = previous.flatMap { String(data: $0, encoding: .utf8) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        previousUnfinished = previous.flatMap { try? decoder.decode(DiagnosticsReport.self, from: $0) }?.running == true
        report.model = manifest
        report.generationTimeoutSeconds = generationTimeoutSeconds
        report.cancellationGraceSeconds = cancellationGraceSeconds
        report.classifierTimeoutSeconds = classifierTimeoutSeconds
        hasModel = (try? modelDirectory.appendingPathComponent(manifest.filename)
            .resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(manifest.bytes)
        self.modelDownloader?.onEvent = { [weak self] event in self?.modelDownloadEvent(event) }
        if self.modelDownloader != nil {
            modelDownloadState = .checking
            Task { await self.restoreModelDownload() }
        }
    }

    var reportText: String {
        do { return String(decoding: try report.json(), as: UTF8.self) }
        catch { return "Report encoding failed: \(error)" }
    }

    var replyActive: Bool { replyState != .idle }
    var nativeWorkBlocked: Bool { busy || speaking || replyActive || modelDownloadState.isActive }

    func startReplyTranscription() {
        guard !busy, !replyActive, !modelDownloadState.isActive, !restartRequired,
              let replyDriver else { return }
        let id = UUID()
        replyID = id
        replyCancelled = false
        replyError = nil
        replyState = .preparing
        beginSession()
        if report.replyRuns == nil { report.replyRuns = [] }
        report.replyRuns?.append(ReplyRecognitionMeasurement(id: id, locale: "en-US"))
        if (report.replyRuns?.count ?? 0) > 20 { report.replyRuns?.removeFirst() }
        setPhase("preparing reply captions")
        if speaking { stopSpeech(reason: "starting reply captions") }
        replyTask = Task { [weak self] in
            guard let self else { return }
            do {
                while self.speaking {
                    try Task.checkCancellation()
                    guard self.replyID == id, !self.restartRequired else { throw CancellationError() }
                    try await Task.sleep(nanoseconds: 25_000_000)
                }
                try Task.checkCancellation()
                guard self.replyID == id, !self.replyCancelled else { return }
                if self.engineLoaded {
                    self.replyUnloading = true
                    do { try await self.releaseEngine(waitForSettlingSample: false) }
                    catch {
                        self.replyUnloading = false
                        self.restartRequired = true
                        throw error
                    }
                    self.replyUnloading = false
                }
                guard self.replyID == id else { return }
                if self.replyCancelled { self.finishReply(id: id, outcome: "cancelled"); return }
                try Task.checkCancellation()
                self.setPhase("preparing reply captions")
                try await replyDriver.start(id: id) { [weak self] event in
                    self?.replyProgress(id: id, event: event)
                }
            } catch {
                guard self.replyID == id else { return }
                replyDriver.cancel(id: id)
                if !self.replyCancelled && !(error is CancellationError) {
                    self.replyError = (error as? ReplyRecognitionFailure) ?? .failed
                }
                self.finishReply(id: id, outcome: self.replyCancelled ? "cancelled" : "failed to start")
            }
        }
    }

    func finishReplyTranscription() {
        guard let id = replyID, replyState == .listening else {
            cancelReplyTranscription()
            return
        }
        replyState = .finishing
        setPhase("finishing reply captions")
        replyWatchdog?.cancel()
        replyDriver?.finish(id: id)
        guard replyID == id else { return }
        replyWatchdog = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: UInt64(self.replyFinalizationSeconds * 1_000_000_000)) }
            catch { return }
            guard self.replyID == id else { return }
            self.replyDriver?.cancel(id: id)
            self.finishReply(id: id, outcome: "stopped; partial captions retained")
        }
    }

    func cancelReplyTranscription() {
        guard let id = replyID, !replyCancelled else { return }
        replyCancelled = true
        replyState = .finishing
        replyWatchdog?.cancel()
        // Engine release must finish before any new native work is admitted.
        if replyUnloading {
            replyWatchdog = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                guard let self, self.replyID == id, self.replyUnloading else { return }
                self.restartRequired = true
                self.replyError = .failed
                self.record("Reply preparation could not finish engine release; restart required.")
            }
            return
        }
        replyTask?.cancel()
        replyDriver?.cancel(id: id)
        finishReply(id: id, outcome: "cancelled")
    }

    func clearReply() {
        guard !replyActive else { return }
        replyText = ""
        replyError = nil
    }

    private func replyProgress(id: UUID, event: ReplyRecognitionEvent) {
        guard replyID == id, !replyCancelled else { return }
        switch event {
        case .started:
            guard replyState == .preparing else { return }
            replyText = ""
            replyState = .listening
            setPhase("listening for spoken reply")
            replyWatchdog = Task { [weak self] in
                guard let self else { return }
                do { try await Task.sleep(nanoseconds: UInt64(self.replyDurationSeconds * 1_000_000_000)) }
                catch { return }
                guard self.replyID == id, self.replyState == .listening else { return }
                self.finishReplyTranscription()
            }
        case .text(let text):
            guard replyState == .listening || replyState == .finishing else { return }
            replyText = String(text.prefix(4_096))
            if text.count >= 4_096, replyState == .listening { finishReplyTranscription() }
        case .finished:
            finishReply(id: id, outcome: "completed")
        case .failed(let error):
            replyError = error
            finishReply(id: id, outcome: "failed; partial captions retained")
        }
    }

    private func finishReply(id: UUID, outcome: String) {
        guard replyID == id else { return }
        replyWatchdog?.cancel()
        replyWatchdog = nil
        replyID = nil
        replyTask = nil
        replyState = .idle
        if let index = report.replyRuns?.firstIndex(where: { $0.id == id }) {
            report.replyRuns?[index].outcome = outcome
            report.replyRuns?[index].endedAt = Date()
            report.replyRuns?[index].characterCount = replyText.count
        }
        report.running = busy || speaking
        record("Reply captions: \(outcome); audio and text omitted.")
        if !busy && !speaking { setPhase(engineLoaded ? "ready" : "idle") }
    }

    func downloadModel() {
        guard !hasModel, !nativeWorkBlocked, let modelDownloader else { return }
        modelDownloadState = .checking
        Task {
            do {
                // Retry an already completed durable file before using the network.
                let recovery = await modelDownloader.restore()
                guard modelDownloadState == .checking else { return }
                switch recovery {
                case .completed(let file): installModelDownload(file); return
                case .transferring(let id, let bytes):
                    downloadTaskID = id
                    modelDownloadState = .downloading(receivedBytes: bytes)
                    return
                case .none: break
                }
                try await models.prepareDownload()
                let id = try modelDownloader.start()
                downloadTaskID = id
                modelDownloadState = .downloading(receivedBytes: 0)
            } catch {
                modelDownloadState = .failed((error as? LocalizedError)?.errorDescription ?? "Download could not start. Please retry.")
            }
        }
    }

    func cancelModelDownload() {
        guard case .downloading = modelDownloadState, let id = downloadTaskID else { return }
        downloadTaskID = nil
        ignoredDownloadTasks.insert(id)
        modelDownloadState = .idle
        modelDownloader?.cancel(taskID: id)
    }

    private func restoreModelDownload() async {
        guard let modelDownloader else { return }
        let recovery = await modelDownloader.restore()
        // A completion delegate may have started verification during reconnect.
        guard modelDownloadState == .checking else { return }
        switch recovery {
        case .none: modelDownloadState = .idle
        case .transferring(let id, let bytes):
            if hasModel {
                modelDownloader.cancel(taskID: id)
                modelDownloadState = .idle
            } else {
                downloadTaskID = id
                modelDownloadState = .downloading(receivedBytes: bytes)
            }
        case .completed(let file): installModelDownload(file)
        }
    }

    private func modelDownloadEvent(_ event: ModelDownloadEvent) {
        switch event {
        case .progress(let id, let bytes):
            guard !ignoredDownloadTasks.contains(id), downloadTaskID == id || modelDownloadState == .checking else { return }
            downloadTaskID = id
            modelDownloadState = .downloading(receivedBytes: max(0, min(bytes, report.model.bytes)))
        case .completed(let id, let file):
            // A background completion can arrive just after getAllTasks returned
            // an empty list. Accept that handoff, but never a cancelled attempt.
            guard !ignoredDownloadTasks.contains(id),
                  downloadTaskID == id || modelDownloadState == .checking
                    || (downloadTaskID == nil && modelDownloadState == .idle && !hasModel) else {
                try? FileManager.default.removeItem(at: file)
                return
            }
            ignoredDownloadTasks.insert(id)
            installModelDownload(file)
        case .failed(let id, let message):
            guard !ignoredDownloadTasks.contains(id), downloadTaskID == id || modelDownloadState == .checking else { return }
            downloadTaskID = nil
            ignoredDownloadTasks.insert(id)
            modelDownloadState = .failed(message)
        }
    }

    private func installModelDownload(_ file: URL) {
        downloadTaskID = nil
        modelDownloadState = .verifying
        Task {
            do {
                try await models.installDownloadedFile(file)
                hasModel = true
                modelDownloadState = .idle
                record("Sentence model downloaded, verified and installed.")
            } catch {
                // Discard corrupt/incomplete content, but retain a durable file
                // after a filesystem failure so Retry need not download it again.
                if error is AppError { try? FileManager.default.removeItem(at: file) }
                modelDownloadState = .failed("The downloaded model could not be verified or installed. Check storage and retry.")
            }
        }
    }

    func speakSentence(automatic: Bool = false) {
        guard !nativeWorkBlocked, !restartRequired, !engineLoaded, sentenceAvailable,
              !sentenceDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let speechDriver else { return }
        let id = UUID()
        speechError = nil
        speaking = true
        activeSpeechID = id
        speechRequestedUptime = ProcessInfo.processInfo.systemUptime
        report.running = true
        if report.speechRuns == nil { report.speechRuns = [] }
        report.speechRuns?.append(SpeechMeasurement(id: id, source: automatic ? "automatic" : "replay",
            characterCount: sentenceDraft.count))
        if (report.speechRuns?.count ?? 0) > 20 { report.speechRuns?.removeFirst() }
        setPhase("speaking")
        do {
            let voice = try speechDriver.speak(id: id, text: sentenceDraft, progress: { [weak self] event in
                self?.speechProgress(id: id, event: event)
            })
            if let index = report.speechRuns?.firstIndex(where: { $0.id == id }) {
                report.speechRuns?[index].voiceIdentifier = voice.identifier
                report.speechRuns?[index].language = voice.language
            }
            persist()
        } catch {
            speechError = "Speech could not start. Check the installed English voice and audio output, then replay."
            finishSpeech(id: id, outcome: "failed to start")
        }
    }

    func stopSpeech(reason: String = "stopped by user") {
        guard speaking, !speechStopping, let id = activeSpeechID else { return }
        speechStopping = true
        setPhase("stopping speech")
        speechStopWatchdog = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            guard let self, self.activeSpeechID == id else { return }
            self.restartRequired = true
            self.speechError = "Speech did not stop. Restart the app before continuing."
            self.record("Speech cancellation did not complete; restart required.")
        }
        record("Speech stop requested: \(reason)")
        speechDriver?.stop()
    }

    private func speechProgress(id: UUID, event: SpeechEvent) {
        guard activeSpeechID == id else { return }
        switch event {
        case .started:
            if let index = report.speechRuns?.firstIndex(where: { $0.id == id }) {
                report.speechRuns?[index].outcome = speechStopping ? "stopping" : "speaking"
                if report.speechRuns?[index].startupSeconds == nil, let start = speechRequestedUptime {
                    report.speechRuns?[index].startupSeconds = ProcessInfo.processInfo.systemUptime - start
                }
            }
            persist()
        case .finished: finishSpeech(id: id, outcome: speechStopping ? "stopped" : "completed")
        case .cancelled: finishSpeech(id: id, outcome: "stopped")
        }
    }

    private func finishSpeech(id: UUID, outcome: String) {
        guard activeSpeechID == id else { return }
        speechStopWatchdog?.cancel()
        speechStopWatchdog = nil
        activeSpeechID = nil
        speechRequestedUptime = nil
        speaking = false
        speechStopping = false
        if let index = report.speechRuns?.firstIndex(where: { $0.id == id }) {
            report.speechRuns?[index].outcome = outcome
            report.speechRuns?[index].endedAt = Date()
        }
        report.running = busy || replyActive
        record("Speech: \(outcome); text omitted.")
        if !busy && !replyActive { setPhase(engineLoaded ? "ready" : "idle") }
    }

    // Session text stays in memory and is deliberately absent from diagnostic reports.
    var pendingPrediction: CameraPredictionMeasurement? {
        guard !nativeWorkBlocked, !restartRequired,
              classifierMeasurement?.outcome == "candidate inference completed",
              let prediction = classifierMeasurement?.cameraPrediction,
              prediction.captureID == cameraMeasurement?.id,
              prediction.captureID != reviewedCaptureID,
              !prediction.candidates.isEmpty else { return nil }
        return prediction
    }

    @discardableResult
    func confirmCandidate(captureID: UUID, index: Int) -> Bool {
        guard confirmedTokens.count < Self.tokenLimit,
              let prediction = pendingPrediction, prediction.captureID == captureID,
              let candidate = prediction.candidates.first(where: { $0.index == index }) else { return false }
        confirmedTokens.append(ConfirmedSignToken(id: UUID(), text: candidate.label,
            captureID: captureID, originalCandidate: candidate))
        invalidateSentence()
        reviewedCaptureID = captureID
        return true
    }

    func dismissCandidates(captureID: UUID) {
        guard pendingPrediction?.captureID == captureID else { return }
        reviewedCaptureID = captureID
    }

    static func normalizedToken(_ text: String) -> String? {
        let normalized = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !normalized.isEmpty, normalized.count <= 64,
              !normalized.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return normalized
    }

    @discardableResult
    func editToken(id: UUID, text: String) -> Bool {
        guard !busy, !replyActive, let normalized = Self.normalizedToken(text),
              let position = confirmedTokens.firstIndex(where: { $0.id == id }) else { return false }
        confirmedTokens[position].text = normalized
        invalidateSentence()
        return true
    }

    func removeToken(id: UUID) {
        guard !busy, !replyActive else { return }
        confirmedTokens.removeAll { $0.id == id }
        invalidateSentence()
    }

    func repeatToken(id: UUID) {
        guard !busy, !replyActive, confirmedTokens.count < Self.tokenLimit,
              let token = confirmedTokens.first(where: { $0.id == id }) else { return }
        confirmedTokens.append(ConfirmedSignToken(id: UUID(), text: token.text,
            captureID: token.captureID, originalCandidate: token.originalCandidate))
        invalidateSentence()
    }

    func clearSignSession() {
        guard !busy, !replyActive else { return }
        clearReply()
        confirmedTokens.removeAll()
        invalidateSentence()
        reviewedCaptureID = classifierMeasurement?.cameraPrediction?.captureID
    }

    private func invalidateSentence() {
        stopSpeech(reason: "sentence invalidated")
        speechError = nil
        sentenceDraft = ""
        sentenceAvailable = false
        sentenceError = nil
    }

    func editSentence(_ text: String) {
        guard !busy, !replyActive, sentenceAvailable, text.utf8.count <= 2_048 else { return }
        stopSpeech(reason: "sentence edited")
        speechError = nil
        sentenceDraft = text
    }

    var conversationStatus: String {
        if restartRequired { return "Restart needed — open Diagnostics to save the report." }
        if replyActive { return replyState == .listening ? "Listening to a reply…" : "Preparing reply captions…" }
        if speaking { return speechStopping ? "Stopping speech…" : "Speaking…" }
        if cameraActive {
            if cameraStopping { return "Stopping camera…" }
            return captureMode == .continuousSigning ? "Signing — lower your hands for \(Int(ContinuousSigningPolicy.noHandsTimeoutSeconds)) seconds to finish" : "Recording sign…"
        }
        if classifierActive { return "Recognizing sign…" }
        if generating { return stopping ? "Stopping sentence generation…" : "Preparing sentence…" }
        if busy { return "Preparing…" }
        if let sentenceError { return sentenceError }
        if sentenceAvailable { return "Sentence ready to edit" }
        return confirmedTokens.isEmpty ? "Ready to sign" : "Ready to finish utterance"
    }

    func recordConversationSign() {
        guard !nativeWorkBlocked, !restartRequired else { return }
        captureMode = .signCandidates
        invalidateSentence()
        startCamera(releaseLoadedEngine: true)
    }

    func startSigning() {
        guard !nativeWorkBlocked, !restartRequired else { return }
        confirmedTokens.removeAll()
        liveRecognition = nil
        reviewedCaptureID = nil
        classifierMeasurement = nil
        generateAfterContinuousCapture = false
        captureMode = .continuousSigning
        invalidateSentence()
        startCamera(releaseLoadedEngine: true)
    }

    func finishUtterance() {
        if cameraActive, captureMode == .continuousSigning {
            guard !cameraStopping, !finishingSignCapture,
                  let id = report.activeCameraID, let cameraDriver else { return }
            finishingSignCapture = true
            setPhase("finishing utterance; waiting for camera release")
            startCameraDrainWatchdog(id: id)
            Task { await cameraDriver.stop(id: id, reason: "Utterance finished by user") }
        } else { generateSentence() }
    }

    func stopConversation() {
        if replyActive { cancelReplyTranscription() }
        else if speaking { stopSpeech() }
        else if generating { cancel() }
        else if cameraActive { stopCamera() }
        else if classifierActive { stopClassifier() }
    }

    func generateSentence() {
        guard !nativeWorkBlocked, !restartRequired else { return }
        guard !confirmedTokens.isEmpty else {
            sentenceError = "Add a sign before finishing the utterance."
            return
        }
        let glosses = confirmedTokens.map(\.text).joined(separator: " ")
        let tokenCount = confirmedTokens.count
        // Keep the short utterance bound while evaluating the full reference prompt.
        guard confirmedTokens.count <= 8, glosses.utf8.count <= 128 else {
            sentenceError = "Use at most eight signs and shorten long corrections."
            return
        }
        guard hasModel else {
            sentenceError = "Import the sentence model before finishing the utterance."
            return
        }
        invalidateSentence()
        let id = UUID()
        requestID = id
        report.activePromptID = "conversation"
        generating = true
        releaseWhenFinished = true
        response = ""
        backend = "GPU"
        report.backend = "GPU"
        perform("preparing sentence") {
            do {
                if self.engineLoaded { try await self.releaseEngine() }
                guard self.requestedStopReason == nil else { return }
                try await self.initializeEngine(backend: "GPU", contextTokens: SentenceGenerationPolicy.contextTokens(for: glosses))
                guard self.requestedStopReason == nil else { return }
                var result = try await self.runner.generate(id: id, promptID: "conversation", glosses: glosses, promptStyle: .reference,
                    progress: { [weak self = self] stage in await self?.generationProgress(id: id, stage: stage) })
                if let reason = self.requestedStopReason { result.outcome = reason }
                var textDiagnostics = result.textDiagnostics ?? .inspect(glosses: glosses, response: result.response)
                textDiagnostics.confirmedTokenCount = tokenCount
                // User glosses, generated sentences and SDK error text are never checkpointed.
                self.report.generations.append(GenerationMeasurement(backend: result.backend,
                    promptID: "conversation", elapsedSeconds: result.elapsedSeconds,
                    firstTextSeconds: result.firstTextSeconds, streamChunks: result.streamChunks,
                    conversationTokens: result.conversationTokens, outcome: result.outcome,
                    response: "[conversation text omitted]", nativeError: nil, textDiagnostics: textDiagnostics,
                    failureStage: result.failureStage, failureKind: result.failureKind, nativeStatusCode: result.nativeStatusCode,
                    conversationSetupSeconds: result.conversationSetupSeconds, responseSeconds: result.responseSeconds,
                    nativeMetrics: result.nativeMetrics))
                if self.report.generations.count > 100 { self.report.generations.removeFirst() }
                if self.requestedStopReason == nil, result.outcome == "completed",
                   textDiagnostics.unexpectedSingleGlossRepetition {
                    self.sentenceError = "The generated text repeated a sign supplied once. Please retry; no sentence was accepted."
                    self.report.generations[self.report.generations.count - 1].outcome = "rejected unexpected single-gloss repetition"
                } else if self.requestedStopReason == nil, result.outcome == "completed",
                   !result.response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   result.response.utf8.count <= 2_048 {
                    self.sentenceDraft = result.response
                    self.sentenceAvailable = true
                } else if self.requestedStopReason == nil {
                    self.sentenceError = "No sentence was produced. Retry or correct the signs."
                }
                self.record("Conversation generation returned; text omitted from diagnostics.")
            } catch {
                self.sentenceError = "Sentence generation failed. Retry after resources are released."
                throw AppError.invalidModel("Conversation generation failed; text omitted from diagnostics.")
            }
        }
        startGenerationWatchdog(id: id)
    }

    func monitor() async {
        while !Task.isCancelled {
            report.sample()
            let active = busy || engineLoaded || speaking || replyActive || modelDownloadState.isActive
            if active, sessionStarted, ProcessInfo.processInfo.systemUptime - lastCheckpoint >= 1 {
                persist()
            }
            do { try await Task.sleep(nanoseconds: 200_000_000) }
            catch { return }
        }
    }

    func importModel(_ url: URL) {
        guard !nativeWorkBlocked, !engineLoaded else { return }
        perform("importing") {
            try await self.models.install(from: url)
            self.hasModel = true
            self.record("Pinned model verified and installed; original file remains in Files.")
        }
    }

    func load() {
        guard !nativeWorkBlocked, !engineLoaded, hasModel else { return }
        let selectedBackend = backend
        let contextTokens = diagnosticContextTokens
        let profiling = diagnosticNativeProfiling
        let promptStyle = diagnosticPromptStyle
        guard promptStyle == .compact || contextTokens >= SentenceGenerationPolicy.contextTokens else { return }
        report.backend = selectedBackend
        perform("verifying model") {
            try await self.initializeEngine(backend: selectedBackend, contextTokens: contextTokens, profiling: profiling)
            self.loadedDiagnosticPrompt = promptStyle
        }
    }

    private func initializeEngine(backend: String, contextTokens: Int, profiling: Bool = false) async throws {
        guard [SentenceGenerationPolicy.compactTrialContextTokens, SentenceGenerationPolicy.contextTokens,
               SentenceGenerationPolicy.extendedContextTokens].contains(contextTokens) else {
            throw AppError.invalidState
        }
        report.contextTokens = contextTokens
        let verificationStart = ProcessInfo.processInfo.systemUptime
        let url: URL
        do { url = try await models.validatedModelURL() }
        catch {
            hasModel = false
            throw error
        }
        let cached = await models.lastValidationUsedCache
        record(String(format: "Model verification: %.3f s (%@)",
                      ProcessInfo.processInfo.systemUptime - verificationStart, cached ? "session cache" : "full SHA-256"))
        setPhase("loading")
        report.observeMemory(reason: "before engine load")
        let seconds = try await runner.load(model: url, gpu: backend == "GPU",
            cache: cacheDirectory.appendingPathComponent(backend), contextTokens: contextTokens, profiling: profiling)
        engineLoaded = true
        report.observeMemory(reason: "after engine load")
        report.loads.append(LoadMeasurement(backend: backend, seconds: seconds, contextTokens: contextTokens,
                                           nativeProfilingEnabled: profiling))
        if report.loads.count > 100 { report.loads.removeFirst() }
        record(String(format: "%@ engine load: %.3f s", backend, seconds))
    }

    func generate() {
        guard !nativeWorkBlocked, engineLoaded else { return }
        let id = UUID()
        let index = promptIndex
        let promptStyle = loadedDiagnosticPrompt
        requestID = id
        report.activePromptID = "gloss-\(index + 1)"
        generating = true
        response = ""
        perform("generating") {
            self.record("Generation started: gloss-\(index + 1), \(Self.prompts[index]); full-response API")
            var measurement = try await self.runner.generate(
                id: id, promptID: "gloss-\(index + 1)", glosses: Self.prompts[index], promptStyle: promptStyle,
                progress: { [weak self] stage in await self?.generationProgress(id: id, stage: stage) }
            )
            // The native actor may not have processed cancellation before returning.
            // A response arriving after our deadline must not count as a successful trial.
            if let reason = self.requestedStopReason { measurement.outcome = reason }
            self.report.generations.append(measurement)
            if self.report.generations.count > 100 { self.report.generations.removeFirst() }
            self.response = measurement.response
            self.record(String(format: "Generation: %@ in %.3f s.", measurement.outcome, measurement.elapsedSeconds))
        }
        startGenerationWatchdog(id: id)
    }

    private func startGenerationWatchdog(id: UUID) {
        // Covers model loading/conversation setup independently of native work.
        let seconds = report.generationTimeoutSeconds
        generationWatchdog = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000) }
            catch { return }
            guard let self, self.requestID == id else { return }
            self.record("Generation deadline reached after \(seconds) s; native work has not returned.")
            self.releaseWhenFinished = true
            self.cancel(reason: "timeout requested")
        }
    }

    func cancel(reason: String = "user cancellation requested") {
        guard generating, !stopping, let id = requestID else { return }
        stopping = true
        requestedStopReason = reason
        if report.activePromptID == "conversation", reason == "Memory warning received" {
            sentenceError = "Your iPhone reported low memory. Stopping sentence generation…"
        }
        generationWatchdog?.cancel()
        generationWatchdog = nil
        setPhase("cancelling; waiting for native completion")
        record("Cancellation requested: \(reason)")
        let seconds = cancellationGraceSeconds
        cancellationWatchdog = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000) }
            catch { return }
            guard let self, self.requestID == id else { return }
            self.restartRequired = true
            self.releaseWhenFinished = true
            self.setPhase("Runtime unresponsive; stop and relaunch the app")
            self.record("No native completion \(seconds) s after cancellation was requested. Engine reuse remains blocked.")
        }
        Task {
            do { try await runner.cancel(id: id, reason: reason) }
            catch { record("Native cancellation failed: \(error)") }
        }
    }

    func unload() {
        guard !nativeWorkBlocked, engineLoaded else { return }
        perform("unloading") { try await self.releaseEngine() }
    }

    func startCamera(releaseLoadedEngine: Bool = false) {
        guard !nativeWorkBlocked, (!engineLoaded || releaseLoadedEngine), let cameraDriver else { return }
        let id = UUID()
        let automaticMode = captureMode == .signCandidates || captureMode == .continuousSigning
        let configuration = CameraConfiguration(mode: captureMode,
            framesPerSecond: automaticMode ? 20 : cameraFramesPerSecond,
            handTestScene: automaticMode ? .unspecified : handTestScene)
        cameraActive = true
        cameraMeasurement = nil
        if captureMode == .signCandidates { classifierMeasurement = nil }
        report.activeCameraMeasurement = nil
        report.activeCameraID = id
        perform("requesting camera permission") {
            if self.engineLoaded { try await self.releaseEngine() }
            self.report.observeMemory(reason: "before camera capture")
            let captured: CapturedCameraClip
            if let reason = self.cameraStopReason {
                var preempted = configuration.measurement(id: id)
                preempted.outcome = reason
                preempted.endedAt = Date()
                captured = CapturedCameraClip(measurement: preempted)
            } else {
                if configuration.mode == .continuousSigning {
                    // Independent of the camera queue: a stuck detector/invoke
                    // cannot prevent this deadline and its stop grace from firing.
                    self.continuousCaptureWatchdog = Task { [weak self = self] in
                        do { try await Task.sleep(nanoseconds: 75_000_000_000) }
                        catch { return }
                        guard let self, self.report.activeCameraID == id else { return }
                        self.stopCamera(reason: "Continuous capture deadline reached")
                    }
                }
                captured = try await cameraDriver.captureClip(id: id, configuration: configuration, progress: { [weak self] event in
                    await self?.cameraProgress(id: id, event: event)
                })
            }
            var measurement = captured.measurement
            if configuration.mode == .signCandidates, self.cameraStopReason == nil {
                measurement.candidateRejection = captured.classificationRejection
                if self.cameraClassifierFactory == nil { measurement.candidateRejection = "Camera classifier is unavailable." }
            }
            self.cameraMeasurement = measurement
            if self.report.cameraCaptures == nil { self.report.cameraCaptures = [] }
            self.report.cameraCaptures?.append(measurement)
            if (self.report.cameraCaptures?.count ?? 0) > 20 { self.report.cameraCaptures?.removeFirst() }
            self.report.observeMemory(reason: "after camera release")
            self.record("Camera: \(measurement.outcome); \(measurement.frames) frames, \(measurement.droppedFrames) dropped.")
            if let landmarks = measurement.landmarks {
                self.record("Landmarks: \(landmarks.processedFrames) processed; \(landmarks.skippedTimestampFrames) timestamp skips; \(landmarks.errorCount) errors.")
            }
            if configuration.mode == .continuousSigning {
                self.liveRecognition = nil
                // The final handoff is authoritative; queued progress may arrive late.
                guard self.cameraStopReason == nil else { return }
                self.updateAutomaticGlosses(captured.automaticGlosses, captureID: id)
                if measurement.completionKind == .handsAbsent || measurement.completionKind == .userFinished {
                    if self.confirmedTokens.isEmpty {
                        self.sentenceError = "No stable signs recognized. Please try again with your hands and face visible."
                    } else { self.generateAfterContinuousCapture = true }
                } else {
                    self.sentenceError = "Signing ended before automatic completion. Check the signs, then finish or start again."
                }
                return
            }
            guard configuration.mode == .signCandidates, self.cameraStopReason == nil else { return }
            if let reason = measurement.candidateRejection {
                self.record("Sign not classified: \(reason)")
                return
            }
            guard let features = captured.features, let factory = self.cameraClassifierFactory else { return }
            // Capture returned only after releasing camera and MediaPipe resources.
            // Keep busy across the handoff; no independent operation can interleave.
            self.cameraActive = false
            self.report.activeCameraID = nil
            self.report.activeCameraMeasurement = nil
            let classificationID = UUID()
            let driver = factory(id, features)
            self.prepareClassifier(driver: driver, id: classificationID)
            try await self.executeClassifier(driver: driver, id: classificationID)
        }
    }

    func finishSignCapture() {
        guard cameraActive, captureMode == .signCandidates, !cameraStopping, !finishingSignCapture,
              let id = report.activeCameraID, let cameraDriver else { return }
        finishingSignCapture = true
        setPhase("finishing sign capture; waiting for camera release")
        Task { await cameraDriver.stop(id: id, reason: "Sign capture completed by user") }
    }

    func stopCamera(reason: String = "Camera stopped by user") {
        guard cameraActive, !cameraStopping, let id = report.activeCameraID, let cameraDriver else { return }
        cameraStopping = true
        liveRecognition = nil
        cameraStopReason = reason
        setPhase("stopping camera; waiting for capture teardown")
        record(reason)
        startCameraDrainWatchdog(id: id)
        Task { await cameraDriver.stop(id: id, reason: reason) }
    }

    private func startCameraDrainWatchdog(id: UUID) {
        cancellationWatchdog?.cancel()
        let seconds = cancellationGraceSeconds
        cancellationWatchdog = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000) }
            catch { return }
            guard let self, self.report.activeCameraID == id else { return }
            self.cameraStopReason = self.cameraStopReason ?? "Camera release grace period exceeded"
            self.generateAfterContinuousCapture = false
            self.restartRequired = true
            self.setPhase("Camera unresponsive; stop and relaunch the app")
            self.record("Camera/native inference has not returned after the stop grace period. Other operations remain blocked.")
        }
    }

    private func cameraProgress(id: UUID, event: CameraProgress) {
        guard report.activeCameraID == id, !cameraStopping else { return }
        switch event {
        case .stage(let stage):
            record("Camera stage: \(stage)", checkpoint: false)
            setPhase(stage)
        case .frames(let measurement):
            cameraMeasurement = measurement
            report.activeCameraMeasurement = measurement
        case .continuous(let glosses):
            guard captureMode == .continuousSigning, !finishingSignCapture else { return }
            updateAutomaticGlosses(glosses, captureID: id)
        case .recognition(let feedback):
            guard captureMode == .continuousSigning, !finishingSignCapture else { return }
            liveRecognition = feedback
        }
    }

    private func updateAutomaticGlosses(_ glosses: [ClassifierCandidate], captureID: UUID) {
        confirmedTokens = glosses.prefix(8).enumerated().map { index, candidate in
            let existing = confirmedTokens.indices.contains(index) ? confirmedTokens[index] : nil
            let id = existing?.captureID == captureID && existing?.originalCandidate.index == candidate.index
                ? existing!.id : UUID()
            return ConfirmedSignToken(id: id, text: candidate.label, captureID: captureID, originalCandidate: candidate)
        }
    }

    func runClassifier(trained: Bool = false) {
        guard !nativeWorkBlocked, !engineLoaded,
              let classifierDriver = trained ? trainedClassifierDriver : classifierDriver else { return }
        let id = UUID()
        prepareClassifier(driver: classifierDriver, id: id)
        perform("starting classifier runtime test") {
            try await self.executeClassifier(driver: classifierDriver, id: id)
        }
    }

    private func prepareClassifier(driver classifierDriver: any ClassifierDriver, id: UUID) {
        activeClassifierDriver = classifierDriver
        classifierActive = true
        classifierMeasurement = nil
        report.activeClassifierID = id
        report.activeClassifierMeasurement = ClassifierMeasurement(id: id)
        let seconds = report.classifierTimeoutSeconds ?? 30
        classifierWatchdog = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000) }
            catch { return }
            guard let self, self.report.activeClassifierID == id else { return }
            self.stopClassifier(reason: "Classifier deadline reached after \(seconds) s")
        }
    }

    private func executeClassifier(driver classifierDriver: any ClassifierDriver, id: UUID) async throws {
        self.report.observeMemory(reason: "before classifier runtime test")
        var measurement: ClassifierMeasurement
        if let reason = self.classifierStopReason {
            measurement = ClassifierMeasurement(id: id)
            measurement.outcome = reason
            measurement.endedAt = Date()
        } else {
            measurement = await classifierDriver.run(id: id, progress: { [weak self] event in
                await self?.classifierProgress(id: id, event: event)
            })
        }
        // A native call may complete before the runner receives our stop.
        // Retain its numerical results but do not classify the run as passed.
        if let reason = self.classifierStopReason {
            measurement.outcome = reason
            measurement.cameraPrediction?.candidates = []
            measurement.cameraPrediction?.status = reason
        }
        self.classifierMeasurement = measurement
        self.report.activeClassifierMeasurement = measurement
        if self.report.classifierRuns == nil { self.report.classifierRuns = [] }
        self.report.classifierRuns?.append(measurement)
        if (self.report.classifierRuns?.count ?? 0) > 20 { self.report.classifierRuns?.removeFirst() }
        self.report.observeMemory(reason: "after classifier runtime test and release")
        if measurement.cameraPrediction != nil {
            self.record("Camera classifier: \(measurement.outcome); \(measurement.completedReleases) release; candidates require confirmation.")
        } else if let validation = measurement.trainedValidation {
            self.record("Trained classifier: \(measurement.outcome); \(validation.cases.count)/\(validation.plannedInvocations) synthetic invocations; \(measurement.completedReleases) releases; recognition/parity unverified.")
        } else {
            self.record("Classifier: \(measurement.outcome); \(measurement.cases.filter(\.passed).count)/\(measurement.plannedCases) cases passed; \(measurement.completedReleases) releases.")
        }
        if measurement.outcome.hasPrefix("failed") {
            throw AppError.invalidModel(measurement.error ?? measurement.outcome)
        }
    }

    func stopClassifier(reason: String = "Classifier stopped by user") {
        guard classifierActive, !classifierStopping,
              let id = report.activeClassifierID, let classifierDriver = activeClassifierDriver else { return }
        classifierStopping = true
        classifierStopReason = reason
        classifierWatchdog?.cancel()
        classifierWatchdog = nil
        setPhase("stopping classifier; waiting for native completion and release")
        record(reason)
        let seconds = cancellationGraceSeconds
        cancellationWatchdog = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000) }
            catch { return }
            guard let self, self.report.activeClassifierID == id else { return }
            self.restartRequired = true
            self.setPhase("Classifier unresponsive; stop and relaunch the app")
            self.record("Classifier has not returned after the stop grace period. Other operations remain blocked.")
        }
        Task { await classifierDriver.stop(id: id, reason: reason) }
    }

    private func classifierProgress(id: UUID, event: ClassifierProgress) {
        guard report.activeClassifierID == id else { return }
        switch event {
        case .stage(let stage):
            record("Classifier stage: \(stage)", checkpoint: false)
            if !classifierStopping {
                phase = stage
                report.phase = stage
            }
            report.observeMemory(reason: stage)
            persist()
        case .measurement(var measurement):
            guard measurement.id == id else { return }
            if let reason = classifierStopReason {
                measurement.cameraPrediction?.candidates = []
                measurement.cameraPrediction?.status = reason
            }
            classifierMeasurement = measurement
            report.activeClassifierMeasurement = measurement
            persist()
        }
    }

    func interrupt(reason: String) {
        cancelReplyTranscription()
        stopSpeech(reason: reason)
        guard busy || engineLoaded else { return }
        record(reason)
        releaseForInterruption(reason: reason)
    }

    func memoryWarningReceived() {
        cancelReplyTranscription()
        stopSpeech(reason: "memory warning")
        let number = (report.memoryWarningCount ?? 0) + 1
        report.memoryWarningCount = number
        report.observeMemory(reason: "memory warning", warningNumber: number)
        record("Memory warning notification #\(number)")
        releaseForInterruption(reason: "Memory warning received")
    }

    private func releaseForInterruption(reason: String) {
        guard busy || engineLoaded else { return }
        if classifierActive {
            stopClassifier(reason: reason)
            return
        }
        if cameraActive {
            stopCamera(reason: reason)
            return
        }
        if busy {
            releaseWhenFinished = true
            cancel(reason: reason)
        } else {
            unload()
        }
    }

    func record(_ message: String, checkpoint: Bool = true) {
        report.events.append("\(Date().ISO8601Format()) \(message)")
        if report.events.count > 256 { report.events.removeFirst() }
        if checkpoint, sessionStarted { persist() }
    }

    private func setPhase(_ value: String) {
        phase = value
        report.phase = value
        report.sample()
        persist()
    }

    private func generationProgress(id: UUID, stage: String) {
        guard requestID == id else { return }
        record("Generation stage: \(stage)", checkpoint: false)
        if !stopping { setPhase(stage) }
        else { persist() }
    }

    private func beginSession() {
        if !sessionStarted, let previousReport {
            do {
                try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(previousReport.utf8).write(to: reportURL.deletingLastPathComponent().appendingPathComponent("previous-report.json"), options: .atomic)
            } catch { checkpointError = "Previous report archive failed: \(error)" }
        }
        sessionStarted = true
        report.running = true
    }

    private func perform(_ label: String, operation: @escaping @MainActor () async throws -> Void) {
        busy = true
        beginSession()
        record("Thermal state: \(ProcessInfo.processInfo.thermalState.rawValue); low power mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled)")
        setPhase(label)
        Task {
            var failure: String?
            do { try await operation() }
            catch {
                failure = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                record("ERROR: \(error)")
            }
            generationWatchdog?.cancel()
            generationWatchdog = nil
            cancellationWatchdog?.cancel()
            cancellationWatchdog = nil
            classifierWatchdog?.cancel()
            classifierWatchdog = nil
            continuousCaptureWatchdog?.cancel()
            continuousCaptureWatchdog = nil
            if releaseWhenFinished, engineLoaded {
                // The diagnostic settling sample must not delay conversational speech.
                // Still await native unload before releasing controls or speaking.
                do { try await releaseEngine(waitForSettlingSample: report.activePromptID != "conversation") }
                catch { failure = String(describing: error); record("Unload failed: \(error)") }
            }
            releaseWhenFinished = false
            if report.activePromptID == "conversation", requestedStopReason != nil || failure != nil {
                invalidateSentence()
                if requestedStopReason == "Memory warning received" {
                    sentenceError = "Stopped because your iPhone reported low memory. Please try again."
                } else {
                    sentenceError = requestedStopReason != nil ? "Sentence generation stopped." : "Sentence generation failed. Please retry."
                }
            }
            let shouldSpeak = report.activePromptID == "conversation" && requestedStopReason == nil
                && failure == nil && sentenceAvailable
            let shouldGenerate = generateAfterContinuousCapture && cameraStopReason == nil && failure == nil
            generateAfterContinuousCapture = false
            generating = false
            stopping = false
            restartRequired = false
            requestID = nil
            requestedStopReason = nil
            report.activePromptID = nil
            cameraActive = false
            liveRecognition = nil
            cameraStopping = false
            finishingSignCapture = false
            cameraStopReason = nil
            report.activeCameraID = nil
            report.activeCameraMeasurement = nil
            classifierActive = false
            activeClassifierDriver = nil
            classifierStopping = false
            classifierStopReason = nil
            report.activeClassifierID = nil
            report.activeClassifierMeasurement = nil
            busy = false
            report.running = false
            setPhase(failure.map { "Failed: \($0)" } ?? (engineLoaded ? "ready" : "idle"))
            if shouldSpeak { speakSentence(automatic: true) }
            else if shouldGenerate { generateSentence() }
        }
    }

    private func releaseEngine(waitForSettlingSample: Bool = true) async throws {
        setPhase("unloading")
        report.observeMemory(reason: "before engine release")
        let releaseStart = ProcessInfo.processInfo.systemUptime
        try await runner.unload()
        engineLoaded = false
        report.observeMemory(reason: "after engine release")
        record(String(format: "Engine references released: %.3f s", ProcessInfo.processInfo.systemUptime - releaseStart))
        guard waitForSettlingSample else { return }
        // Observe delayed release without claiming allocator/driver memory must drop immediately.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        report.observeMemory(reason: "two seconds after engine release")
        record("Engine references released; two-second post-release sample recorded.")
    }

    private func persist() {
        report.updatedAt = Date()
        do {
            try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try autoreleasepool {
                try report.json(prettyPrinted: false).write(to: reportURL, options: .atomic)
            }
            lastCheckpoint = ProcessInfo.processInfo.systemUptime
        } catch { checkpointError = "Checkpoint write failed: \(error)" }
    }
}
