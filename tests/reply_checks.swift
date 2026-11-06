import Foundation

extension AppChecks {
    @MainActor
    static func checkReplyTranscription(source: URL, support: URL, manifest: ModelManifest) async throws {
        defer { try? FileManager.default.removeItem(at: support) }
        let driver = ControlledReplyRecognition()
        let runner = ControlledRunner()
        let camera = ControlledCamera()
        let session = ConversationController(runner: runner, camera: camera, reply: driver,
            supportDirectory: support, manifest: manifest)
        session.startReplyTranscription()
        try await wait { session.replyState == .listening }
        let first = driver.requests.last!
        precondition(session.nativeWorkBlocked && !session.busy)
        session.load(); session.startSigning(); session.runClassifier()
        let captures = await camera.captureCount
        let loads = await runner.loadCount
        precondition(captures == 0 && loads == 0 && !session.cameraActive && !session.classifierActive)
        driver.emit(.text("PRIVATE_REPLY_SHORT"), id: first)
        driver.emit(.text("PRIVATE_REPLY_REVISED"), id: first)
        precondition(session.replyText == "PRIVATE_REPLY_REVISED", "Partial hypotheses were appended instead of replaced")
        session.clearReply()
        precondition(session.replyText == "PRIVATE_REPLY_REVISED", "Clear changed an active session")
        session.finishReplyTranscription()
        precondition(session.replyState == .finishing && session.nativeWorkBlocked && driver.finishCount == 1)
        driver.emit(.text("PRIVATE_REPLY_FINAL"), id: first)
        driver.emit(.finished, id: first)
        precondition(!session.replyActive && !session.nativeWorkBlocked && session.replyText == "PRIVATE_REPLY_FINAL")
        precondition(session.report.replyRuns?.last?.characterCount == "PRIVATE_REPLY_FINAL".count)
        let checkpoint = try String(contentsOf: support.appendingPathComponent("report.json"), encoding: .utf8)
        precondition(!session.reportText.contains("PRIVATE_REPLY") && !checkpoint.contains("PRIVATE_REPLY"))

        session.startReplyTranscription()
        try await wait { session.replyState == .listening }
        let second = driver.requests.last!
        driver.emit(.text("SECOND_REPLY"), id: second)
        session.interrupt(reason: "App backgrounded")
        precondition(!session.replyActive && driver.cancelled.contains(second))
        session.startReplyTranscription()
        try await wait { session.replyState == .listening }
        let third = driver.requests.last!
        driver.emit(.text("STALE_PRIVATE_TEXT"), id: second)
        driver.emit(.failed(.failed), id: second)
        precondition(session.replyState == .listening && session.replyText.isEmpty && session.replyError == nil)
        driver.emit(.text("CURRENT_PRIVATE_TEXT"), id: third)
        session.memoryWarningReceived()
        precondition(!session.replyActive && session.replyText == "CURRENT_PRIVATE_TEXT")
        driver.emit(.text("LATE_PRIVATE_TEXT"), id: third)
        precondition(session.replyText == "CURRENT_PRIVATE_TEXT")
        session.clearReply()
        precondition(session.replyText.isEmpty && session.replyError == nil)

        for failure in [ReplyRecognitionFailure.microphonePermissionDenied, .speechPermissionDenied, .onDeviceUnavailable] {
            driver.failure = failure
            session.startReplyTranscription()
            try await wait { !session.replyActive }
            precondition(session.replyError == failure && !session.nativeWorkBlocked)
        }
        driver.failure = nil
        driver.holdStart = true
        session.startReplyTranscription()
        try await wait { driver.pendingStart != nil }
        let pending = driver.requests.last!
        session.cancelReplyTranscription()
        precondition(!session.replyActive)
        driver.resumeStart()
        try await Task.sleep(nanoseconds: 5_000_000)
        driver.emit(.started, id: pending)
        precondition(!session.replyActive && session.replyText.isEmpty)

        let timedDriver = ControlledReplyRecognition()
        let timed = ConversationController(runner: ControlledRunner(), reply: timedDriver,
            supportDirectory: support.appendingPathComponent("timed"), manifest: manifest,
            replyDurationSeconds: 0.02, replyFinalizationSeconds: 0.02)
        timed.startReplyTranscription()
        try await wait { timed.replyState == .listening }
        timedDriver.emit(.text("TIMED_PRIVATE_REPLY"), id: timedDriver.requests.last!)
        try await wait { !timed.replyActive }
        precondition(timedDriver.finishCount == 1 && timedDriver.cancelled.count == 1
                     && timed.replyText == "TIMED_PRIVATE_REPLY")

        let boundedDriver = ControlledReplyRecognition()
        let bounded = ConversationController(runner: ControlledRunner(), reply: boundedDriver,
            supportDirectory: support.appendingPathComponent("bounded"), manifest: manifest)
        bounded.startReplyTranscription()
        try await wait { bounded.replyState == .listening }
        boundedDriver.emit(.text(String(repeating: "a", count: 8_192)), id: boundedDriver.requests.last!)
        precondition(bounded.replyText.count == 4_096 && bounded.replyState == .finishing)
        bounded.cancelReplyTranscription()

        // A diagnostic engine must finish unloading before ASR or another
        // native operation can start, including when preparation is cancelled.
        let unloadDriver = ControlledReplyRecognition()
        let unloadRunner = ControlledRunner()
        let unloading = ConversationController(runner: unloadRunner, reply: unloadDriver,
            supportDirectory: support.appendingPathComponent("unload"), manifest: manifest)
        unloading.importModel(source)
        try await wait { !unloading.busy }
        unloading.load()
        try await wait { unloading.engineLoaded && !unloading.busy }
        await unloadRunner.setHoldUnload(true)
        unloading.startReplyTranscription()
        try await wait { await unloadRunner.unloadPending }
        precondition(unloadDriver.requests.isEmpty)
        unloading.cancelReplyTranscription()
        precondition(unloading.replyActive && unloading.nativeWorkBlocked)
        unloading.startSigning(); unloading.load()
        await unloadRunner.finishUnload()
        try await wait { !unloading.replyActive }
        precondition(!unloading.engineLoaded && unloadDriver.requests.isEmpty)

        // Get a real generated sentence through the controlled pipeline so the
        // microphone start can be verified against a pending speech stop.
        let speaker = ControlledSpeech()
        speaker.holdStop = true
        let speechRunner = ControlledRunner()
        let speechCamera = ControlledCamera()
        let speechReply = ControlledReplyRecognition()
        let speaking = ConversationController(runner: speechRunner, camera: speechCamera,
            speech: speaker, reply: speechReply, supportDirectory: support.appendingPathComponent("speech"), manifest: manifest)
        speaking.importModel(source)
        try await wait { !speaking.busy }
        speaking.startSigning()
        try await wait { await speechCamera.captureCount == 1 }
        await speechCamera.setAutomaticGlosses([ClassifierCandidate(label: "WATER", score: 0.9, index: 1)])
        var capture = CameraConfiguration(mode: .continuousSigning, framesPerSecond: 20, handTestScene: .unspecified)
            .measurement(id: speaking.report.activeCameraID!)
        capture.completionKind = .handsAbsent
        await speechCamera.finish(reason: "owned hand absence", measurement: capture)
        try await wait { await speechRunner.started }
        await speechRunner.finish(outcome: "completed", response: "PRIVATE_SPOKEN_SENTENCE")
        try await wait { speaking.speaking }
        let spokenID = speaker.requests.last!.id
        speaking.startReplyTranscription()
        precondition(speaking.replyActive && speaking.speechStopping)
        try await Task.sleep(nanoseconds: 10_000_000)
        precondition(speechReply.requests.isEmpty, "Microphone started before playback stopped")
        speaker.emit(id: spokenID, event: .cancelled)
        try await wait { speaking.replyState == .listening }
        speaking.cancelReplyTranscription()
        precondition(!speaking.speaking && !speaking.replyActive)
        print("PASS: reply captions, permission/cancel/stale isolation, audio/native exclusion, limits, interruption and report privacy")
    }
}

@MainActor
final class ControlledReplyRecognition: ReplyRecognitionDriver {
    var requests: [UUID] = []
    var cancelled: [UUID] = []
    var finishCount = 0
    var failure: ReplyRecognitionFailure?
    var holdStart = false
    var pendingStart: CheckedContinuation<Void, Never>?
    private var callbacks: [UUID: @MainActor (ReplyRecognitionEvent) -> Void] = [:]

    func start(id: UUID, progress: @escaping @MainActor (ReplyRecognitionEvent) -> Void) async throws {
        requests.append(id)
        callbacks[id] = progress
        if holdStart { await withCheckedContinuation { pendingStart = $0 } }
        if let failure { throw failure }
        progress(.started)
    }
    func finish(id: UUID) { finishCount += 1 }
    func cancel(id: UUID) { cancelled.append(id) }
    func emit(_ event: ReplyRecognitionEvent, id: UUID) { callbacks[id]?(event) }
    func resumeStart() { pendingStart?.resume(); pendingStart = nil; holdStart = false }
}
