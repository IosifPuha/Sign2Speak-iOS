import CryptoKit
import Foundation

private final class RenameDeniedFileManager: FileManager, @unchecked Sendable {
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

private func checkStorageMigration(in root: URL) throws {
    let files = FileManager.default
    let base = root.appendingPathComponent("migration-" + UUID().uuidString, isDirectory: true)
    try files.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: base) }
    let legacy = base.appendingPathComponent("Gate0Probe")
    for relative in ["Models/model.litertlm", "Downloads/completed.modeldownload", "report.json"] {
        let file = legacy.appendingPathComponent(relative)
        try files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(relative.utf8).write(to: file)
    }
    let oldModel = legacy.appendingPathComponent("Models/model.litertlm")
    let inode = try files.attributesOfItem(atPath: oldModel.path)[.systemFileNumber] as! NSNumber
    let migrated = AppStorage.supportDirectory(in: base)
    precondition(migrated.lastPathComponent == "Sign2Speak")
    precondition(!files.fileExists(atPath: legacy.path))
    for relative in ["Models/model.litertlm", "Downloads/completed.modeldownload", "report.json"] {
        let data = try Data(contentsOf: migrated.appendingPathComponent(relative))
        precondition(data == Data(relative.utf8), "Migration lost stored data")
    }
    let movedInode = try files.attributesOfItem(atPath: migrated.appendingPathComponent("Models/model.litertlm").path)[.systemFileNumber] as! NSNumber
    precondition(inode == movedInode, "Migration copied the model instead of renaming")
    precondition(AppStorage.supportDirectory(in: base) == migrated, "Migration was not idempotent")

    // A pre-existing new directory wins without deleting or merging old data.
    try files.createDirectory(at: legacy, withIntermediateDirectories: true)
    let retained = legacy.appendingPathComponent("retained")
    try Data([1]).write(to: retained)
    precondition(AppStorage.supportDirectory(in: base) == migrated)
    precondition(files.fileExists(atPath: retained.path))

    let oldCache = base.appendingPathComponent("Gate0Runtime")
    try files.createDirectory(at: oldCache, withIntermediateDirectories: true)
    try Data([2]).write(to: oldCache.appendingPathComponent("compiled"))
    let cache = AppStorage.cacheDirectory(in: base)
    let cached = try Data(contentsOf: cache.appendingPathComponent("compiled"))
    precondition(cache.lastPathComponent == "Sign2SpeakRuntime" && cached == Data([2]))

    // Simulate a denied rename without depending on the host user's permissions.
    let failure = base.appendingPathComponent("failure")
    let fallback = failure.appendingPathComponent("Gate0Probe")
    try files.createDirectory(at: fallback, withIntermediateDirectories: true)
    let blocked = failure.appendingPathComponent("Sign2Speak")
    let failedMigration = AppStorage.supportDirectory(in: failure, files: RenameDeniedFileManager())
    precondition(failedMigration.path == fallback.path)
    precondition(files.fileExists(atPath: fallback.path))
    precondition(AppStorage.supportDirectory(in: failure).path == blocked.path)

    let fresh = base.appendingPathComponent("fresh")
    precondition(AppStorage.supportDirectory(in: fresh).lastPathComponent == "Sign2Speak")
    precondition(AppStorage.cacheDirectory(in: fresh).lastPathComponent == "Sign2SpeakRuntime")
    print("Storage migration checks passed")
}

@main
struct AppChecks {
    @MainActor
    static func main() async throws {
        if CommandLine.arguments.contains("--recognition-policy-only") {
            checkContinuousPolicy()
            checkRecognitionFeedback()
            return
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/app-checks-data", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try checkStorageMigration(in: root)
        if CommandLine.arguments.contains("--storage-only") { return }
        let source = root.appendingPathComponent(UUID().uuidString)
        let installed = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: installed)
        }
        let contents = Data("nonprivate model integrity fixture".utf8)
        let hash = SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
        let manifest = ModelManifest(filename: "fixture.litertlm", revision: "test", bytes: Int64(contents.count), sha256: hash)
        let models = ModelStore(directory: installed, manifest: manifest)
        try contents.write(to: source)
        if CommandLine.arguments.contains("--reply-only") {
            try await checkReplyTranscription(source: source, support: root.appendingPathComponent("reply-" + UUID().uuidString), manifest: manifest)
            return
        }
        if CommandLine.arguments.contains("--download-only") {
            try await checkModelDownload(source: source, support: installed.appendingPathComponent("download"), manifest: manifest)
            return
        }
        if CommandLine.arguments.contains("--generation-feedback-only") {
            try await checkGenerationFailureDiagnostics(source: source, support: installed.appendingPathComponent("feedback"), manifest: manifest)
            return
        }
        try await checkReplyTranscription(source: source, support: root.appendingPathComponent("reply-" + UUID().uuidString), manifest: manifest)
        try await models.install(from: source)
        let valid = try await models.validatedModelURL()
        let firstWasCached = await models.lastValidationUsedCache
        precondition(!firstWasCached, "First validation must hash the installed model")
        _ = try await models.validatedModelURL()
        let secondWasCached = await models.lastValidationUsedCache
        precondition(secondWasCached, "Unchanged model was hashed again")
        let relaunchedStore = ModelStore(directory: installed, manifest: manifest)
        _ = try await relaunchedStore.validatedModelURL()
        let relaunchWasCached = await relaunchedStore.lastValidationUsedCache
        precondition(!relaunchWasCached, "Verification cache survived a new store/session")
        let originalDate = try valid.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        let writer = try FileHandle(forWritingTo: valid)
        try writer.write(contentsOf: Data([contents[0] ^ 1]))
        try writer.close()
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: valid.path)
        do {
            _ = try await models.validatedModelURL()
            fatalError("Cached verification accepted same-size mutation with restored mtime")
        } catch AppError.invalidModel { }
        try await models.install(from: source)
        _ = try await models.validatedModelURL()
        let replacementWasCached = await models.lastValidationUsedCache
        precondition(!replacementWasCached, "Import failed to invalidate cached verification")
        let installedContents = try Data(contentsOf: valid)
        precondition(installedContents == contents)
        let interrupted = installed.appendingPathComponent(UUID().uuidString + ".partial")
        let unrelated = installed.appendingPathComponent("notes.partial")
        try Data("interrupted copy".utf8).write(to: interrupted)
        try Data("preserve this".utf8).write(to: unrelated)
        try await models.install(from: source)
        precondition(!FileManager.default.fileExists(atPath: interrupted.path), "Interrupted import was not cleaned up")
        precondition(FileManager.default.fileExists(atPath: unrelated.path), "Cleanup removed an unrelated file")

        var corrupt = contents
        corrupt[0] ^= 1
        try corrupt.write(to: source)
        do {
            try await models.install(from: source)
            fatalError("Same-size corrupted model was accepted")
        } catch AppError.invalidModel { }
        let preservedContents = try Data(contentsOf: valid)
        let directoryContents = try FileManager.default.contentsOfDirectory(atPath: installed.path)
        precondition(preservedContents == contents, "Corrupt replacement damaged the installed model")
        precondition(Set(directoryContents) == Set([manifest.filename, "notes.partial"]), "Staging files leaked")

        try Data("short".utf8).write(to: source)
        do {
            try await models.install(from: source)
            fatalError("Truncated model was accepted")
        } catch AppError.invalidModel { }

        var report = DiagnosticsReport()
        report.running = true
        report.phase = "loading"
        report.sample()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(DiagnosticsReport.self, from: report.json())
        precondition(restored.running && restored.phase == "loading", "Unfinished checkpoint was lost")
        precondition(restored.sampleCount == 1)
        precondition(restored.peakPhysicalFootprintBytes > 0 || restored.failedMemorySamples == 1)
        let legacyURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tests/fixtures/legacy-report-v1.json")
        let legacy = try decoder.decode(DiagnosticsReport.self, from: Data(contentsOf: legacyURL))
        precondition(legacy.version == 1 && legacy.generationAPI == nil && legacy.generations.count == 2,
                     "Version-1 reports must remain readable without inventing an API mode")
        var version2 = try JSONSerialization.jsonObject(with: Data(contentsOf: legacyURL)) as! [String: Any]
        version2["version"] = 2
        version2["generationAPI"] = "sendMessage (full response)"
        version2["cancellationGraceSeconds"] = 10
        let restoredVersion2 = try decoder.decode(DiagnosticsReport.self, from: JSONSerialization.data(withJSONObject: version2))
        precondition(restoredVersion2.version == 2 && restoredVersion2.memoryWarningCount == nil
                     && restoredVersion2.memoryObservations == nil && restoredVersion2.buildConfiguration == nil,
                     "Missing historical diagnostics must remain unknown, not become zero readings")
        precondition(restoredVersion2.cameraCaptures == nil && restoredVersion2.activeCameraID == nil,
                     "Historical reports must not invent camera evidence")
        var version3 = try JSONSerialization.jsonObject(with: report.json()) as! [String: Any]
        version3["version"] = 3
        version3.removeValue(forKey: "cameraCaptures")
        let restoredVersion3 = try decoder.decode(DiagnosticsReport.self, from: JSONSerialization.data(withJSONObject: version3))
        precondition(restoredVersion3.version == 3 && restoredVersion3.memoryWarningCount == 0 && restoredVersion3.cameraCaptures == nil)
        var version4 = try JSONSerialization.jsonObject(with: report.json()) as! [String: Any]
        version4["version"] = 4
        var oldCapture = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CameraMeasurement(id: UUID()))) as! [String: Any]
        oldCapture.removeValue(forKey: "captureMode")
        oldCapture.removeValue(forKey: "landmarks")
        oldCapture["requestedAt"] = "2026-10-08T15:02:15Z"
        version4["cameraCaptures"] = [oldCapture]
        let restoredVersion4 = try decoder.decode(DiagnosticsReport.self, from: JSONSerialization.data(withJSONObject: version4))
        precondition(restoredVersion4.cameraCaptures?.first?.landmarks == nil
                     && restoredVersion4.cameraCaptures?.first?.captureMode == nil,
                     "Historical captures must not invent landmark evidence")
        var version5 = version4
        version5["version"] = 5
        var oldLandmarks = try JSONSerialization.jsonObject(with: JSONEncoder().encode(LandmarkMeasurement())) as! [String: Any]
        for key in ["latestRawHandednessScores", "singleHandRawLabelCounts", "duplicateRawLabelFrames"] {
            oldLandmarks.removeValue(forKey: key)
        }
        oldCapture["captureMode"] = "handAndFace"
        oldCapture["landmarks"] = oldLandmarks
        version5["cameraCaptures"] = [oldCapture]
        let restoredVersion5 = try decoder.decode(DiagnosticsReport.self, from: JSONSerialization.data(withJSONObject: version5))
        precondition(restoredVersion5.cameraCaptures?.first?.captureElapsedSeconds == nil
                     && restoredVersion5.cameraCaptures?.first?.landmarks?.singleHandRawLabelCounts == nil,
                     "Version-5 reports must not invent new timing/handedness evidence")
        var version6 = version5
        version6["version"] = 6
        oldLandmarks.removeValue(forKey: "handIdentity")
        oldCapture["landmarks"] = oldLandmarks
        version6["cameraCaptures"] = [oldCapture]
        let restoredVersion6 = try decoder.decode(DiagnosticsReport.self, from: JSONSerialization.data(withJSONObject: version6))
        precondition(restoredVersion6.cameraCaptures?.first?.landmarks?.handIdentity == nil,
                     "Version-6 reports must not invent hand-slot calibration")
        var version7 = version6
        version7["version"] = 7
        let restoredVersion7 = try decoder.decode(DiagnosticsReport.self, from: JSONSerialization.data(withJSONObject: version7))
        precondition(restoredVersion7.cameraCaptures?.first?.latestPreviewGeometry == nil
                     && restoredVersion7.cameraCaptures?.first?.previewGeometryObservations == nil,
                     "Version-7 reports must not invent preview angle evidence")
        checkVideoTimestamps()
        try checkCaptureBoundaries()
        try checkHandIdentity()
        try checkLandmarkClip()
        try checkFrameBrightness()
        let mock = ControlledRunner()
        let controller = ConversationController(runner: mock, supportDirectory: installed, manifest: manifest)
        try contents.write(to: source)
        controller.importModel(source)
        try await wait { !controller.busy }
        controller.load()
        try await wait { !controller.busy }
        precondition(controller.engineLoaded)
        controller.generate()
        try await wait { await mock.started }
        controller.cancel()
        try await wait { await mock.cancellationObserved }
        precondition(controller.busy && controller.stopping, "UI released resources before native completion")
        controller.unload()
        let prematureUnloads = await mock.unloadCount
        precondition(prematureUnloads == 0, "Unload overlapped generation")
        await mock.finish()
        try await wait { !controller.busy }
        precondition(controller.report.generations.count == 1)
        controller.unload()
        try await wait { !controller.busy }
        precondition(!controller.engineLoaded)
        try await checkWatchdog(source: source, support: installed.appendingPathComponent("watchdog"), manifest: manifest)
        try await checkMemoryInterruption(source: source, support: installed.appendingPathComponent("memory-warning"), manifest: manifest)
        try await checkCameraLifecycle(source: source, support: installed.appendingPathComponent("camera"), manifest: manifest)
        try checkClassifierFixture()
        try await checkClassifierLifecycle(source: source, support: installed.appendingPathComponent("classifier"), manifest: manifest)
        try await checkCameraCandidates(source: source, support: installed.appendingPathComponent("camera-candidates"), manifest: manifest)
        try await checkModelDownload(source: source, support: installed.appendingPathComponent("download"), manifest: manifest)
        try await checkGenerationFailureDiagnostics(source: source, support: installed.appendingPathComponent("generation-failure"), manifest: manifest)
        checkContinuousPolicy()
        checkRecognitionFeedback()
        try await checkContinuousHandoff(source: source, support: installed.appendingPathComponent("continuous"), manifest: manifest)
        try await checkLargeImportMemory(root: root)
        print("PASS: integrity, replacement, interrupted-import cleanup, bounded verification memory, legacy reports, memory accounting, cancellation drain, independent watchdog, no overlapping native work")
    }

    private static func checkContinuousPolicy() {
        for score: Float in [0.5999, 0.60, 0.65] {
            var boundary = ContinuousSigningState()
            let candidates = [ClassifierCandidate(label: "like", score: score, index: 18),
                              ClassifierCandidate(label: "other", score: 0.20, index: 1)]
            boundary.accept(candidates, seconds: 0, invokeSeconds: 0)
            precondition(boundary.glosses.isEmpty, "Lower score floor must not bypass stability")
            boundary.accept(candidates, seconds: 0.35, invokeSeconds: 0)
            precondition(boundary.glosses.count == (score >= 0.60 ? 1 : 0),
                         "Stable 60/65 percent predictions should add; below 60 should not")
            precondition(boundary.measurement.minimumScore == 0.60
                         && boundary.measurement.minimumMargin == 0.20)
        }
        let first = ClassifierCandidate(label: "PRIVATE_FIRST_SIGN", score: 0.9, index: 1)
        let second = ClassifierCandidate(label: "PRIVATE_SECOND_SIGN", score: 0.85, index: 2)
        let other = ClassifierCandidate(label: "PRIVATE_OTHER_SIGN", score: 0.05, index: 3)
        var state = ContinuousSigningState()
        // An empty camera never generates, even beyond the configured timeout.
        var empty = ContinuousSigningState()
        for tick in 0...120 { precondition(!empty.observe(seconds: Double(tick) / 20, handsVisible: false)) }
        for tick in 0...60 { precondition(!state.observe(seconds: Double(tick) / 20, handsVisible: false)) }
        for tick in 61...100 { precondition(!state.observe(seconds: Double(tick) / 20, handsVisible: true)) }
        state.accept([first, other], seconds: 5, invokeSeconds: 0.01)
        precondition(state.glosses.isEmpty, "A single prediction must not commit")
        state.accept([first, other], seconds: 5.4, invokeSeconds: 0.01)
        precondition(state.glosses.count == 1)
        for tick in 101...120 { _ = state.observe(seconds: Double(tick) / 20, handsVisible: true) }
        state.accept([first, other], seconds: 6, invokeSeconds: 0.01)
        state.accept([first, other], seconds: 6.4, invokeSeconds: 0.01)
        precondition(state.glosses.count == 1, "Held sign was duplicated")
        state.accept([second, other], seconds: 6.8, invokeSeconds: 0.01)
        state.accept([second, other], seconds: 7.2, invokeSeconds: 0.01)
        precondition(state.glosses.map(\.index) == [1, 2], "Different signs must not require hands to disappear")
        // Brief dropout cancels on reacquisition; enough release rearms repetition.
        for tick in 121...128 { _ = state.observe(seconds: Double(tick) / 20, handsVisible: false) }
        _ = state.observe(seconds: 6.45, handsVisible: true)
        state.accept([second, other], seconds: 6.5, invokeSeconds: 0.01)
        state.accept([second, other], seconds: 6.9, invokeSeconds: 0.01)
        precondition(state.glosses.map(\.index) == [1, 2, 2])
        let timeout = ContinuousSigningPolicy.noHandsTimeoutSeconds
        for tick in 130..<Int((6.5 + timeout) * 20) {
            precondition(!state.observe(seconds: Double(tick) / 20, handsVisible: false))
        }
        precondition(state.observe(seconds: 6.5 + timeout, handsVisible: false), "Configured absence did not finish")

        var timer = ContinuousSigningState()
        _ = timer.observe(seconds: 0, handsVisible: true)
        precondition(timer.measurement.noHandsTimeoutSeconds == timeout)
        for tick in 1...Int(timeout * 20) { precondition(!timer.observe(seconds: Double(tick) / 20, handsVisible: false)) }
        precondition(timer.observe(seconds: timeout + 0.05, handsVisible: false))
        _ = timer.observe(seconds: timeout + 0.1, handsVisible: true)
        precondition(!timer.observe(seconds: timeout + 0.15, handsVisible: false))
        precondition(!timer.observe(seconds: 10, handsVisible: false), "Missing callbacks must not count as observed hand absence")
        precondition(timer.measurement.discontinuities == 1)

        var weak = ContinuousSigningState()
        _ = weak.observe(seconds: 0, handsVisible: true)
        weak.accept([ClassifierCandidate(label: "weak", score: 0.4, index: 5), other], seconds: 0, invokeSeconds: 0)
        weak.accept([first, ClassifierCandidate(label: "close", score: 0.8, index: 4)], seconds: 0.4, invokeSeconds: 0)
        precondition(weak.glosses.isEmpty)
        weak.accept([first, other], seconds: 0.8, invokeSeconds: 0)
        weak.rejectWindow()
        weak.accept([first, other], seconds: 1.2, invokeSeconds: 0)
        precondition(weak.glosses.isEmpty, "Rejected input must break stability")
        var bounded = ContinuousSigningState()
        for index in 0..<12 {
            let item = ClassifierCandidate(label: "item", score: 0.9, index: index)
            bounded.accept([item, other], seconds: Double(index), invokeSeconds: 0)
            bounded.accept([item, other], seconds: Double(index) + 0.4, invokeSeconds: 0)
        }
        precondition(bounded.glosses.count == 8)
        print("PASS: configured observed absence boundary, empty view, dropout reset, stable commits, held/repeated/distinct signs, weak-input rejection and bounds")
    }

    private static func checkRecognitionFeedback() {
        var state = ContinuousSigningState()
        _ = state.observe(seconds: 0, handsVisible: false)
        precondition(state.feedback.status == .noHands && !state.feedback.hasSeenHands)
        _ = state.observe(seconds: 0.1, handsVisible: true)
        precondition(state.feedback.status == .collecting && state.feedback.handsVisible)
        let uncertain = [ClassifierCandidate(label: "PRIVATE_GUESS", score: 0.4, index: 1),
                         ClassifierCandidate(label: "PRIVATE_ALTERNATIVE", score: 0.3, index: 2)]
        state.accept(uncertain, seconds: 0.1, invokeSeconds: 0.01)
        precondition(state.feedback.status == .lowScore && state.feedback.candidates.count == 2 && state.glosses.isEmpty)
        state.accept([ClassifierCandidate(label: "PRIVATE_GUESS", score: 0.71, index: 1),
                      ClassifierCandidate(label: "PRIVATE_ALTERNATIVE", score: 0.60, index: 2)], seconds: 0.2, invokeSeconds: 0.01)
        precondition(state.feedback.status == .ambiguous && state.glosses.isEmpty)
        let strong = [ClassifierCandidate(label: "PRIVATE_GUESS", score: 0.9, index: 1),
                      ClassifierCandidate(label: "PRIVATE_ALTERNATIVE", score: 0.05, index: 2)]
        state.accept(strong, seconds: 0.3, invokeSeconds: 0.01)
        precondition(state.feedback.status == .stabilizing && state.glosses.isEmpty)
        state.accept(strong, seconds: 0.7, invokeSeconds: 0.01)
        precondition(state.feedback.status == .added && state.glosses.count == 1)
        state.accept(strong, seconds: 1.1, invokeSeconds: 0.01)
        precondition(state.feedback.status == .alreadyAdded && state.glosses.count == 1)
        _ = state.observe(seconds: 0.2, handsVisible: false)
        _ = state.observe(seconds: 0.4, handsVisible: false)
        precondition(state.feedback.status == .noHands && state.feedback.hasSeenHands
                     && abs(state.feedback.noHandsSeconds - 0.2) < 1e-9 && state.feedback.candidates.isEmpty)
        state.rejectWindow()
        precondition(state.feedback.candidates.isEmpty)
        let aggregate = String(decoding: try! JSONEncoder().encode(state.measurement), as: UTF8.self)
        precondition(!aggregate.contains("PRIVATE_"), "Live recognition text leaked into Codable measurement")
        print("PASS: tentative scores/alternatives, weak/ambiguous/stabilizing/added distinction, no-hands clearing/countdown, aggregate privacy")
    }

    @MainActor
    private static func checkContinuousHandoff(source: URL, support: URL, manifest: ModelManifest) async throws {
        let camera = ControlledCamera()
        let runner = ControlledRunner()
        let speaker = ControlledSpeech()
        let controller = ConversationController(runner: runner, camera: camera, speech: speaker,
            supportDirectory: support, manifest: manifest)
        controller.importModel(source)
        try await wait { !controller.busy }
        let glosses = [ClassifierCandidate(label: "PRIVATE_CONTINUOUS_SIGN", score: 0.9, index: 1)]
        controller.startSigning()
        try await wait { await camera.captureCount == 1 }
        let mode = await camera.mode
        precondition(mode == .continuousSigning)
        let configuration = await camera.configuration
        precondition(configuration?.framesPerSecond == 20)
        let tentative = ContinuousRecognitionFeedback(candidates: glosses, status: .stabilizing,
            handsVisible: true, hasSeenHands: true)
        await camera.emit(.recognition(tentative))
        precondition(controller.liveRecognition?.candidates.first?.label == "PRIVATE_CONTINUOUS_SIGN"
                     && controller.confirmedTokens.isEmpty, "Showing a prediction must not add it to the sentence")
        await camera.emit(.continuous(glosses))
        precondition(controller.confirmedTokens.count == 1)
        let firstTokenID = controller.confirmedTokens[0].id
        await camera.emit(.continuous(glosses))
        precondition(controller.confirmedTokens[0].id == firstTokenID, "Live feedback must preserve token identity")
        let initialGenerations = await runner.generationCount
        precondition(initialGenerations == 0, "Generation overlapped camera")
        controller.load()
        let initialLoads = await runner.loadCount
        precondition(initialLoads == 0)
        var value = CameraConfiguration(mode: .continuousSigning, framesPerSecond: 20,
            handTestScene: .unspecified).measurement(id: controller.report.activeCameraID!)
        value.completionKind = .handsAbsent
        await camera.setAutomaticGlosses(glosses)
        await camera.finish(reason: "hands absent", measurement: value)
        try await wait { await runner.started }
        precondition(!controller.cameraActive && controller.generating)
        precondition(controller.liveRecognition == nil)
        let submitted = await runner.lastGlosses
        precondition(submitted == "PRIVATE_CONTINUOUS_SIGN")
        await camera.emit(.continuous([]))
        await camera.emit(.recognition(tentative))
        precondition(controller.liveRecognition == nil, "Late prediction reappeared after camera release")
        precondition(controller.confirmedTokens.count == 1, "Late camera progress changed completed utterance")
        await runner.finish(outcome: "completed", response: "PRIVATE_CONTINUOUS_OUTPUT")
        try await wait { controller.speaking }
        let releases = await runner.unloadCount
        precondition(releases == 1)
        speaker.emit(id: speaker.requests.last!.id, event: .finished)
        precondition(!controller.reportText.contains("PRIVATE_CONTINUOUS"), "Continuous text leaked into diagnostics")

        // Native late success after Stop must never trigger generation/speech.
        controller.startSigning()
        try await wait { await camera.captureCount == 2 }
        precondition(controller.confirmedTokens.isEmpty)
        controller.stopConversation()
        precondition(controller.liveRecognition == nil)
        await camera.emit(.recognition(tentative))
        precondition(controller.liveRecognition == nil, "Stopped capture published a live prediction")
        await camera.setAutomaticGlosses(glosses)
        await camera.finish(reason: "late success", measurement: value)
        try await wait { !controller.busy }
        let afterStop = await runner.generationCount
        precondition(afterStop == 1)
        precondition(speaker.requests.count == 1)

        // Empty and safety-limited captures require explicit recovery, not speech.
        for kind in [CameraCompletionKind.handsAbsent, .durationLimit, .interrupted] {
            let nextCapture = await camera.captureCount + 1
            controller.startSigning()
            try await wait { await camera.captureCount == nextCapture }
            value.completionKind = kind
            await camera.setAutomaticGlosses(kind == .handsAbsent ? [] : glosses)
            await camera.finish(reason: "owned outcome", measurement: value)
            try await wait { !controller.busy }
            let afterAbnormal = await runner.generationCount
            precondition(afterAbnormal == 1)
        }
        // Manual Finish drains camera first and uses the same generation path.
        let manualCapture = await camera.captureCount + 1
        controller.startSigning()
        try await wait { await camera.captureCount == manualCapture }
        await camera.emit(.continuous(glosses))
        let manualStops = await camera.stopCount
        controller.finishUtterance()
        try await wait { await camera.stopCount == manualStops + 1 }
        let beforeRelease = await runner.generationCount
        precondition(controller.busy && controller.finishingSignCapture && beforeRelease == 1)
        value.completionKind = .userFinished
        await camera.setAutomaticGlosses(glosses)
        await camera.finish(reason: "manual finish", measurement: value)
        try await wait { await runner.generationCount == 2 }
        controller.stopConversation()
        await runner.finish(outcome: "completed", response: "PRIVATE_LATE_MANUAL_OUTPUT")
        try await wait { !controller.busy }
        precondition(!controller.sentenceAvailable && speaker.requests.count == 1)

        let backgroundCapture = await camera.captureCount + 1
        controller.startSigning()
        try await wait { await camera.captureCount == backgroundCapture }
        controller.interrupt(reason: "owned background interruption")
        value.completionKind = .handsAbsent
        await camera.setAutomaticGlosses(glosses)
        await camera.finish(reason: "late background success", measurement: value)
        try await wait { !controller.busy }
        let afterBackground = await runner.generationCount
        precondition(afterBackground == 2 && speaker.requests.count == 1)
        let stalledCamera = ControlledCamera()
        let stalled = ConversationController(runner: ControlledRunner(), camera: stalledCamera,
            supportDirectory: support.appendingPathComponent("stalled"), manifest: manifest,
            cancellationGraceSeconds: 1)
        stalled.startSigning()
        try await wait { await stalledCamera.captureCount == 1 }
        stalled.finishUtterance()
        try await wait { stalled.restartRequired }
        precondition(stalled.busy && stalled.cameraActive, "Unresponsive camera unlocked native work")
        stalled.startSigning()
        let stalledStarts = await stalledCamera.captureCount
        precondition(stalledStarts == 1)
        value.completionKind = .userFinished
        await stalledCamera.setAutomaticGlosses(glosses)
        await stalledCamera.finish(reason: "late success after drain timeout", measurement: value)
        try await wait { !stalled.busy }
        precondition(stalled.confirmedTokens.isEmpty && !stalled.sentenceAvailable)
        print("PASS: continuous camera release → generation → release → automatic speech, no late/empty/abnormal generation, text privacy")
    }

    @MainActor
    private static func checkModelDownload(source: URL, support: URL, manifest: ModelManifest) async throws {
        var backgroundCompletions = 0
        ModelDownloadBackgroundEvents.finish() // Foreground delivery must not complete a future wakeup.
        ModelDownloadBackgroundEvents.register { backgroundCompletions += 1 }
        precondition(backgroundCompletions == 0)
        ModelDownloadBackgroundEvents.finish()
        ModelDownloadBackgroundEvents.finish()
        precondition(backgroundCompletions == 1, "Background event completion was called more than once")
        let downloader = ControlledModelDownloader()
        let runner = ControlledRunner()
        let controller = ConversationController(runner: runner, modelDownloader: downloader,
            supportDirectory: support, manifest: manifest)
        try await wait { controller.modelDownloadState == .idle }
        precondition(!controller.hasModel)
        controller.downloadModel()
        try await wait { downloader.starts == 1 }
        precondition(controller.nativeWorkBlocked && !controller.hasModel)
        controller.downloadModel()
        controller.load()
        precondition(downloader.starts == 1)
        let loads = await runner.loadCount
        precondition(loads == 0, "Runtime started during model transfer")
        downloader.emit(.progress(taskID: 1, receivedBytes: 12))
        precondition(controller.modelDownloadState == .downloading(receivedBytes: 12))
        controller.cancelModelDownload()
        precondition(controller.modelDownloadState == .idle && downloader.cancelled == [1])
        let cancelled = support.appendingPathComponent("cancelled.modeldownload")
        try Data(contentsOf: source).write(to: cancelled)
        downloader.emit(.completed(taskID: 1, file: cancelled))
        precondition(!controller.hasModel && !FileManager.default.fileExists(atPath: cancelled.path))
        controller.downloadModel()
        try await wait { downloader.starts == 2 }
        // Old queued progress/error must not corrupt a new attempt.
        downloader.emit(.progress(taskID: 1, receivedBytes: 1))
        downloader.emit(.failed(taskID: 1, message: "cancelled old attempt"))
        precondition(controller.modelDownloadState == .downloading(receivedBytes: 0))
        downloader.emit(.failed(taskID: 2, message: "controlled connection failure"))
        precondition(controller.modelDownloadState == .failed("controlled connection failure"))
        controller.downloadModel()
        try await wait { downloader.starts == 3 }
        let corrupt = support.appendingPathComponent("corrupt.modeldownload")
        var bytes = try Data(contentsOf: source)
        bytes[0] ^= 1
        try bytes.write(to: corrupt)
        downloader.emit(.completed(taskID: 3, file: corrupt))
        precondition(controller.modelDownloadState == .verifying && controller.nativeWorkBlocked)
        try await wait { !controller.modelDownloadState.isActive }
        precondition(!controller.hasModel && !FileManager.default.fileExists(atPath: corrupt.path))
        controller.downloadModel()
        try await wait { downloader.starts == 4 }
        let complete = support.appendingPathComponent("complete.modeldownload")
        try Data(contentsOf: source).write(to: complete)
        downloader.emit(.completed(taskID: 4, file: complete))
        try await wait { controller.hasModel }
        precondition(controller.modelDownloadState == .idle && !controller.nativeWorkBlocked)
        precondition(!FileManager.default.fileExists(atPath: complete.path), "Verified download was copied rather than moved")
        let installed = support.appendingPathComponent("Models").appendingPathComponent(manifest.filename)
        let installedBytes = try Data(contentsOf: installed)
        let originalBytes = try Data(contentsOf: source)
        precondition(installedBytes == originalBytes)
        let relaunched = ConversationController(runner: ControlledRunner(), supportDirectory: support, manifest: manifest)
        precondition(relaunched.hasModel, "Installed model was not recognized after relaunch")

        let recoveredDownloader = ControlledModelDownloader()
        recoveredDownloader.recovery = .transferring(taskID: 50, receivedBytes: 8)
        let recoveredSupport = support.appendingPathComponent("recovered")
        let recovered = ConversationController(runner: ControlledRunner(), modelDownloader: recoveredDownloader,
            supportDirectory: recoveredSupport, manifest: manifest)
        try await wait { recovered.modelDownloadState == .downloading(receivedBytes: 8) }
        let recoveredFile = support.appendingPathComponent("recovered.modeldownload")
        try Data(contentsOf: source).write(to: recoveredFile)
        recoveredDownloader.emit(.completed(taskID: 50, file: recoveredFile))
        try await wait { recovered.hasModel }

        let durable = support.appendingPathComponent("durable.modeldownload")
        try Data(contentsOf: source).write(to: durable)
        let finishedDownloader = ControlledModelDownloader()
        finishedDownloader.recovery = .completed(durable)
        let finished = ConversationController(runner: ControlledRunner(), modelDownloader: finishedDownloader,
            supportDirectory: support.appendingPathComponent("finished"), manifest: manifest)
        try await wait { finished.hasModel }
        precondition(finishedDownloader.starts == 0, "Recovery redownloaded a durable completed file")

        // Completion may be delivered just after background task enumeration ends.
        let lateDownloader = ControlledModelDownloader()
        let late = ConversationController(runner: ControlledRunner(), modelDownloader: lateDownloader,
            supportDirectory: support.appendingPathComponent("late"), manifest: manifest)
        try await wait { late.modelDownloadState == .idle }
        let lateFile = support.appendingPathComponent("late.modeldownload")
        try Data(contentsOf: source).write(to: lateFile)
        lateDownloader.emit(.completed(taskID: 90, file: lateFile))
        try await wait { late.hasModel }
        let storageSupport = support.appendingPathComponent("storage-failure")
        try FileManager.default.createDirectory(at: storageSupport, withIntermediateDirectories: true)
        let blocker = storageSupport.appendingPathComponent("Models")
        try Data([0]).write(to: blocker)
        let storageDownloader = ControlledModelDownloader()
        let storageController = ConversationController(runner: ControlledRunner(), modelDownloader: storageDownloader,
            supportDirectory: storageSupport, manifest: manifest)
        try await wait { storageController.modelDownloadState == .idle }
        let retained = support.appendingPathComponent("retained.modeldownload")
        try Data(contentsOf: source).write(to: retained)
        storageDownloader.emit(.completed(taskID: 100, file: retained))
        try await wait { !storageController.modelDownloadState.isActive }
        precondition(!storageController.hasModel && FileManager.default.fileExists(atPath: retained.path),
                     "Filesystem failure discarded a completed model")
        try FileManager.default.removeItem(at: blocker)
        storageDownloader.recovery = .completed(retained)
        storageController.downloadModel()
        try await wait { storageController.hasModel }
        precondition(storageDownloader.starts == 0, "Installation retry unnecessarily started another transfer")
        print("PASS: download progress, runtime exclusion, cancel/retry/stale callbacks, corrupt rejection, verified move, installed launch, transfer/durable/late recovery, retained-file installation retry")
    }

    @MainActor
    private static func checkGenerationFailureDiagnostics(source: URL, support: URL, manifest: ModelManifest) async throws {
        let camera = ControlledCamera()
        let runner = ControlledRunner()
        let speaker = ControlledSpeech()
        let controller = ConversationController(runner: runner, camera: camera, speech: speaker,
            supportDirectory: support, manifest: manifest)
        precondition(controller.report.contextTokens == 768 && controller.report.maxOutputTokens == 64)
        precondition(SentenceGenerationPolicy.contextTokens(for: String(repeating: "x", count: 64)) == 768)
        precondition(SentenceGenerationPolicy.contextTokens(for: String(repeating: "x", count: 65)) == 1_024)
        precondition(SentenceGenerationPolicy.contextTokens(for: String(repeating: "é", count: 33)) == 1_024,
                     "Budget selection must use UTF-8 bytes, not character count")
        precondition(GlossSentencePrompt.systemInstruction.components(separatedBy: "→").count == 27)
        precondition(!GlossSentencePrompt.systemInstruction.contains("HATE WAKE THIRSTY"), "Diagnostic relation must remain outside prompt examples")
        controller.diagnosticPromptStyle = .compact
        let compactInstruction = SentencePromptStyle.compact.systemInstruction
        precondition(compactInstruction.utf8.count < GlossSentencePrompt.systemInstruction.utf8.count / 2)
        precondition(!compactInstruction.contains("HATE WAKE") && !compactInstruction.contains("HUNGRY WATER"),
                     "Held-out semantic combinations became prompt examples")
        controller.importModel(source)
        try await wait { !controller.busy }
        controller.startSigning()
        try await wait { await camera.captureCount == 1 }
        await camera.setAutomaticGlosses([ClassifierCandidate(label: "PRIVATE_FAILED_INPUT", score: 0.9, index: 1)])
        var captured = CameraConfiguration(mode: .continuousSigning, framesPerSecond: 20, handTestScene: .unspecified)
            .measurement(id: controller.report.activeCameraID!)
        captured.completionKind = .handsAbsent
        await camera.finish(reason: "owned hand absence", measurement: captured)
        try await wait { await runner.started }
        let shortContext = await runner.lastContextTokens
        precondition(shortContext == 768 && controller.report.loads.last?.contextTokens == 768)
        let conversationProfiling = await runner.lastProfiling
        let conversationPrompt = await runner.lastPromptStyle
        precondition(conversationPrompt == .reference, "Diagnostic compact selection leaked into signing")
        precondition(!conversationProfiling && controller.report.loads.last?.nativeProfilingEnabled == false,
                     "Diagnostic profiling leaked into normal Conversation")
        let nativeMetrics = GenerationRuntimeMetrics(initializationSeconds: 0.1, timeToFirstTokenSeconds: 2,
            lastPrefillTokenCount: 550, lastDecodeTokenCount: 12,
            lastPrefillTokensPerSecond: 300, lastDecodeTokensPerSecond: 20)
        let unavailableMetrics = GenerationRuntimeMetrics(initializationSeconds: .nan, timeToFirstTokenSeconds: .infinity,
            lastPrefillTokenCount: -1, lastDecodeTokenCount: 0,
            lastPrefillTokensPerSecond: -.infinity, lastDecodeTokensPerSecond: -1)
        _ = try JSONEncoder().encode(unavailableMetrics)
        precondition(unavailableMetrics.timeToFirstTokenSeconds == nil
                     && unavailableMetrics.initializationSeconds == nil
                     && unavailableMetrics.lastPrefillTokensPerSecond == nil
                     && unavailableMetrics.lastDecodeTokensPerSecond == nil)
        var diagnostics = GenerationTextDiagnostics.inspect(glosses: "PRIVATE_FAILED_INPUT", response: "")
        diagnostics.promptRevision = GlossSentencePrompt.revision
        diagnostics.configuredContextTokens = SentenceGenerationPolicy.contextTokens
        diagnostics.systemPromptUTF8Bytes = GlossSentencePrompt.systemInstruction.utf8.count
        diagnostics.systemPromptWordCount = GlossSentencePrompt.systemInstruction.split(whereSeparator: \.isWhitespace).count
        await runner.finish(measurement: GenerationMeasurement(backend: "GPU", promptID: "conversation",
            elapsedSeconds: 0.01, firstTextSeconds: nil, streamChunks: 0, conversationTokens: nil,
            outcome: "failed", response: "PRIVATE_FAILED_RESPONSE", nativeError: "PRIVATE_SDK_ERROR",
            textDiagnostics: diagnostics, failureStage: "generating full response", failureKind: "conversation", nativeStatusCode: 3,
            nativeMetrics: nativeMetrics))
        try await wait { !controller.busy }
        let result = controller.report.generations.last!
        precondition(result.nativeMetrics?.lastPrefillTokenCount == 550
                     && result.nativeMetrics?.timeToFirstTokenSeconds == 2,
                     "Numeric counters were lost while redacting conversation text")
        precondition(result.outcome == "failed" && result.failureStage == "generating full response"
                     && result.failureKind == "conversation" && result.nativeStatusCode == 3)
        precondition(result.textDiagnostics?.configuredContextTokens == 768 && result.textDiagnostics?.promptRevision == GlossSentencePrompt.revision)
        precondition(!controller.sentenceAvailable && !controller.engineLoaded && speaker.requests.isEmpty)
        precondition(!controller.reportText.contains("PRIVATE_"), "Failure diagnostics leaked private input/output/error")
        controller.generateSentence()
        try await wait { await runner.generationCount == 2 }
        controller.memoryWarningReceived()
        controller.memoryWarningReceived()
        precondition(controller.sentenceError == "Your iPhone reported low memory. Stopping sentence generation…")
        precondition(controller.busy && controller.stopping && controller.engineLoaded,
                     "Memory feedback bypassed the native completion barrier")
        await runner.finish(outcome: "completed", response: "PRIVATE_LATE_RESPONSE")
        try await wait { !controller.busy }
        precondition(controller.sentenceError == "Stopped because your iPhone reported low memory. Please try again.")
        precondition(!controller.sentenceAvailable && !controller.engineLoaded && speaker.requests.isEmpty)
        precondition(controller.confirmedTokens.count == 1, "Pressure cancellation discarded signs needed for retry")
        controller.generateSentence()
        precondition(controller.sentenceError == nil, "Retry retained an old memory warning")
        try await wait { await runner.generationCount == 3 }
        controller.stopConversation()
        await runner.finish(outcome: "completed", response: "PRIVATE_USER_STOP_RESPONSE")
        try await wait { !controller.busy }
        precondition(controller.sentenceError == "Sentence generation stopped.", "User Stop was mislabeled as low memory")
        precondition(speaker.requests.isEmpty && !controller.reportText.contains("PRIVATE_"))
        let tokenID = controller.confirmedTokens[0].id
        precondition(controller.editToken(id: tokenID, text: String(repeating: "x", count: 63)))
        controller.repeatToken(id: tokenID)
        controller.generateSentence()
        try await wait { await runner.generationCount == 4 }
        let longContext = await runner.lastContextTokens
        precondition(longContext == 1_024 && controller.report.contextTokens == 1_024)
        precondition(controller.report.loads.last?.contextTokens == 1_024)
        let longInput = await runner.lastGlosses
        precondition(longInput.utf8.count == 127, "Long corrections were truncated")
        controller.stopConversation()
        await runner.finish(outcome: "completed", response: "PRIVATE_LONG_RESPONSE")
        try await wait { !controller.busy }
        controller.diagnosticContextTokens = 1_024
        controller.diagnosticPromptStyle = .reference
        controller.diagnosticNativeProfiling = true
        controller.load()
        try await wait { !controller.busy }
        let baselineContext = await runner.lastContextTokens
        precondition(baselineContext == 1_024 && controller.engineLoaded)
        let diagnosticProfiling = await runner.lastProfiling
        precondition(diagnosticProfiling && controller.report.loads.last?.nativeProfilingEnabled == true)
        controller.unload()
        try await wait { !controller.busy }
        controller.diagnosticContextTokens = 512
        controller.load()
        precondition(!controller.busy && !controller.engineLoaded, "Full reference was allowed at trial-only512 capacity")
        controller.diagnosticPromptStyle = .compact
        controller.load()
        try await wait { !controller.busy }
        let compactContext = await runner.lastContextTokens
        precondition(compactContext == 512 && controller.engineLoaded)
        // Even an external setting mutation must not change the loaded trial.
        controller.diagnosticPromptStyle = .reference
        controller.generate()
        try await wait { await runner.generationCount == 5 }
        let compactPrompt = await runner.lastPromptStyle
        precondition(compactPrompt == .compact)
        await runner.finish(outcome: "completed", response: "Owned diagnostic response.")
        try await wait { !controller.busy }
        controller.unload()
        try await wait { !controller.busy }
        let compact = try controller.report.json(prettyPrinted: false)
        let pretty = try controller.report.json()
        let compactObject = try JSONSerialization.jsonObject(with: compact) as! NSDictionary
        let prettyObject = try JSONSerialization.jsonObject(with: pretty) as! NSDictionary
        precondition(compactObject == prettyObject && compact.count < pretty.count,
                     "Compact checkpoints must preserve all report fields")
        print("PASS: short/long context routing, untruncated corrections, baseline override, compact report equivalence")
        print("PASS: diagnostic-only profiling routing, numeric metrics preservation and nonfinite metric JSON safety")
        print("PASS: compact diagnostic trial, loaded configuration capture,512 baseline exclusion and full-reference signing isolation")
        print("PASS: immediate/final low-memory feedback, retained signs, retry clearing, user-stop distinction and late-speech suppression")
        print("PASS: full-reference prompt/config, structured failure diagnostics, engine release, no failed-result speech and private-error redaction")
    }

    private static func checkClassifierFixture() throws {
        var validation = ClassifierMeasurement(id: UUID())
        validation.trainedValidation = ClassifierValidationMeasurement()
        let historicalData = try JSONEncoder().encode(validation)
        let historicalObject = try JSONSerialization.jsonObject(with: historicalData) as! [String: Any]
        precondition(historicalObject["trainedProbe"] != nil && historicalObject["trainedValidation"] == nil)
        let restoredValidation = try JSONDecoder().decode(ClassifierMeasurement.self, from: historicalData)
        precondition(restoredValidation.trainedValidation != nil, "Legacy trained validation metadata was lost")
        struct Golden: Decodable {
            struct Case: Decodable { let recipe: String; let expectedOutput: [Double] }
            let cases: [Case]
        }
        let metadata = try JSONDecoder().decode(Golden.self, from: Data(contentsOf: URL(fileURLWithPath: "tests/fixtures/classifier-fixture.json")))
        let binary = try Data(contentsOf: URL(fileURLWithPath: "Sign2Speak/Models/" + ClassifierFixture.filename))
        try ClassifierFixture.verify(binary)
        var corrupt = binary
        corrupt[corrupt.count - 1] ^= 1
        do { try ClassifierFixture.verify(corrupt); fatalError("Corrupt classifier fixture was accepted") }
        catch AppError.invalidModel { }
        for item in metadata.cases {
            let expected = try ClassifierFixture.expected(recipe: item.recipe)
            precondition(expected == item.expectedOutput,
                         "Swift expected outputs differ from the reviewed Python goldens")
            let input = try ClassifierFixture.input(recipe: item.recipe)
            precondition(input.count == ClassifierFixture.inputBytes)
            // Execute the owned arithmetic independently using serialized input
            // values. This verifies recipes/axis layout, not a native interpreter.
            let output: [Float] = input.withUnsafeBytes { raw in
                func mean(_ channel: Int) -> Float {
                    (0..<64).reduce(Float(0)) { sum, frame in
                        sum + Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(
                            fromByteOffset: (frame * 708 + channel) * 4, as: UInt32.self))) / 64
                    }
                }
                return (0..<50).map { k in
                    (k.isMultiple(of: 2) ? 1 : -1) * mean(k) + 0.5 * mean(658 + k) + Float(k) / 8
                }
            }
            let words = output.map { $0.bitPattern.littleEndian }
            let data = words.withUnsafeBytes { Data($0) }
            let value = try ClassifierFixture.compare(data, recipe: item.recipe, pass: 1, repetition: 1, seconds: 0)
            precondition(value.passed && value.maximumAbsoluteError == 0)
        }
        var words = [UInt32](repeating: 0, count: 50)
        words[0] = Float.infinity.bitPattern.littleEndian
        let nonfinite = try ClassifierFixture.compare(words.withUnsafeBytes { Data($0) }, recipe: "zeros", pass: 1, repetition: 1, seconds: 0)
        precondition(!nonfinite.passed && nonfinite.nonfiniteIndices == [0] && nonfinite.outputs == nil)
        _ = try JSONEncoder().encode(nonfinite)
        var expected = try ClassifierFixture.expected(recipe: "zeros").map { Float($0) }
        expected[0] = 0.00002
        words = expected.map { $0.bitPattern.littleEndian }
        let wrong = try ClassifierFixture.compare(words.withUnsafeBytes { Data($0) }, recipe: "zeros", pass: 1, repetition: 1, seconds: 0)
        precondition(!wrong.passed && wrong.mismatchIndices == [0], "Output outside tolerance passed")
        do {
            _ = try ClassifierFixture.compare(Data(), recipe: "zeros", pass: 1, repetition: 1, seconds: 0)
            fatalError("Malformed output byte count was accepted")
        } catch AppError.invalidModel { }
        var legacy = try JSONSerialization.jsonObject(with: DiagnosticsReport().json()) as! [String: Any]
        legacy["version"] = 9
        for key in ["classifierRuns", "classifierTimeoutSeconds", "activeClassifierID", "activeClassifierMeasurement"] {
            legacy.removeValue(forKey: key)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(DiagnosticsReport.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(restored.classifierRuns == nil && restored.classifierTimeoutSeconds == nil,
                     "Historical reports invented classifier evidence")
        print("PASS: owned classifier integrity, Swift/Python goldens, float32 recipes, numerical rejection, JSON-safe nonfinite results, legacy absence")
    }

    @MainActor
    private static func checkClassifierLifecycle(source: URL, support: URL, manifest: ModelManifest) async throws {
        let runner = ControlledRunner()
        let driver = ControlledClassifier()
        let camera = ControlledCamera()
        let controller = ConversationController(runner: runner, camera: camera, classifier: driver,
            supportDirectory: support, manifest: manifest, cancellationGraceSeconds: 1, classifierTimeoutSeconds: 1)
        controller.importModel(source)
        try await wait { !controller.busy }
        controller.load()
        try await wait { !controller.busy }
        controller.runClassifier()
        let blockedStarts = await driver.runCount
        precondition(blockedStarts == 0, "Classifier overlapped a loaded Gemma engine")
        controller.unload()
        try await wait { !controller.busy }
        controller.runClassifier()
        try await wait { await driver.runCount == 1 }
        let id = controller.report.activeClassifierID!
        var partial = ClassifierMeasurement(id: id)
        partial.integrityVerified = true
        await driver.emit(.measurement(partial))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let saved = try decoder.decode(DiagnosticsReport.self, from: Data(contentsOf: support.appendingPathComponent("report.json")))
        precondition(saved.running && saved.activeClassifierMeasurement?.integrityVerified == true)
        controller.memoryWarningReceived()
        controller.memoryWarningReceived()
        try await wait { await driver.stopCount == 1 }
        controller.startCamera()
        controller.load()
        controller.runClassifier()
        let cameraStarts = await camera.captureCount
        let loadCount = await runner.loadCount
        precondition(cameraStarts == 0 && loadCount == 1 && controller.busy && controller.classifierStopping)
        try await wait { controller.restartRequired }
        precondition(controller.busy, "Stop watchdog released controls while native work was pending")
        await driver.finish()
        try await wait { !controller.busy }
        precondition(controller.classifierMeasurement?.outcome == "Memory warning received" && !controller.restartRequired)
        precondition(controller.report.classifierRuns?.count == 1 && controller.report.memoryWarningCount == 2)
        precondition(controller.report.activeClassifierID == nil && controller.report.activeClassifierMeasurement == nil)
        controller.runClassifier()
        try await wait { await driver.runCount == 2 }
        await driver.emitPrevious(.stage("stale classifier progress"))
        precondition(!controller.phase.contains("stale"))
        try await wait { controller.classifierStopping } // Independent one-second deadline.
        try await wait { await driver.stopCount == 2 }
        precondition(controller.phase.contains("waiting for native"))
        await driver.finish()
        try await wait { !controller.busy }
        precondition(controller.classifierMeasurement?.outcome == "Classifier deadline reached after 1 s")
        controller.runClassifier()
        controller.stopClassifier()
        try await wait { !controller.busy }
        let starts = await driver.runCount
        precondition(starts == 2, "Immediate stop still started native classifier work")
        print("PASS: classifier exclusion, live checkpoints, deduplicated stop, completion barrier, restart/deadline watchdogs, stale progress, preempted start")
        let trained = ControlledClassifier()
        let selected = ConversationController(runner: ControlledRunner(), classifier: driver, trainedClassifier: trained,
            supportDirectory: support.appendingPathComponent("trained"), manifest: manifest)
        selected.runClassifier(trained: true)
        try await wait { await trained.runCount == 1 }
        selected.runClassifier()
        selected.stopClassifier()
        try await wait { await trained.stopCount == 1 }
        let fixtureStarts = await driver.runCount
        let fixtureStops = await driver.stopCount
        precondition(fixtureStarts == 2 && fixtureStops == 2 && selected.busy)
        await trained.finish()
        try await wait { !selected.busy }
        precondition(selected.classifierMeasurement?.outcome == "Classifier stopped by user")
        selected.runClassifier()
        try await wait { await driver.runCount == 3 }
        selected.stopClassifier()
        try await wait { await driver.stopCount == 3 }
        await driver.finish()
        try await wait { !selected.busy }
        print("PASS: trained/fixture driver selection, Stop routing, exclusion, release barrier, subsequent fixture restart")
    }

    @MainActor
    private static func checkCameraCandidates(source: URL, support: URL, manifest: ModelManifest) async throws {
        let singlePrompt = GlossSentencePrompt.make(glosses: "OWNED_SINGLE_INPUT")
        precondition(singlePrompt == "ASL glosses: OWNED_SINGLE_INPUT")
        precondition(singlePrompt.components(separatedBy: "OWNED_SINGLE_INPUT").count == 2,
                     "Prompt duplicated the actual submitted input")
        precondition(GlossSentencePrompt.make(glosses: "drink drink") == "ASL glosses: drink drink",
                     "Prompt removed intentional repetition")
        precondition(GlossSentencePrompt.make(glosses: "NO LIKE MILK") == "ASL glosses: NO LIKE MILK",
                     "Prompt altered input meaning or negation")
        let singleRepeated = GenerationTextDiagnostics.inspect(glosses: "drink", response: "Drink drink.", textPartCount: 1)
        precondition(singleRepeated.unexpectedSingleGlossRepetition && singleRepeated.inputWordCount == 1
                     && singleRepeated.outputWordCount == 2 && singleRepeated.outputTextPartCount == 1)
        precondition(!GenerationTextDiagnostics.inspect(glosses: "DRINK DRINK", response: "Drink drink").unexpectedSingleGlossRepetition)
        precondition(!GenerationTextDiagnostics.inspect(glosses: "drink", response: "Drink a drink.").unexpectedSingleGlossRepetition)
        precondition(!GenerationTextDiagnostics.inspect(glosses: "", response: "").unexpectedSingleGlossRepetition)
        let diagnosticMeasurement = GenerationMeasurement(backend: "GPU", promptID: "owned-test",
            elapsedSeconds: 0, firstTextSeconds: nil, streamChunks: 0, conversationTokens: nil,
            outcome: "completed", response: "[omitted]", nativeError: nil, textDiagnostics: singleRepeated)
        var legacyGeneration = try JSONSerialization.jsonObject(with: JSONEncoder().encode(diagnosticMeasurement)) as! [String: Any]
        legacyGeneration.removeValue(forKey: "textDiagnostics")
        let restoredGeneration = try JSONDecoder().decode(GenerationMeasurement.self,
            from: JSONSerialization.data(withJSONObject: legacyGeneration))
        precondition(restoredGeneration.textDiagnostics == nil)
        let camera = ControlledCamera()
        let classifier = ControlledClassifier()
        let sentenceRunner = ControlledRunner()
        let speaker = ControlledSpeech()
        let hand = Array(repeating: LandmarkPoint(x: 0.75, y: 0.25, z: 0), count: 21)
        let face = Array(repeating: LandmarkPoint(x: 0.5, y: 0.5, z: 0), count: 478)
        let features = try FeatureEncoder.encode((0..<3).map {
            LandmarkClipFrame(seconds: Double($0) / 20, left: hand, right: nil, face: face)
        })
        let controller = ConversationController(runner: sentenceRunner, camera: camera, speech: speaker,
            cameraClassifierFactory: { _, value in
                precondition(value.validFrames == 3 && value.handFrames == 3)
                return classifier
            }, supportDirectory: support, manifest: manifest)
        controller.captureMode = .signCandidates
        controller.cameraFramesPerSecond = 30
        func measurement(_ id: UUID) -> CameraMeasurement {
            var value = CameraConfiguration(mode: .signCandidates, framesPerSecond: 20,
                                            handTestScene: .unspecified).measurement(id: id)
            var landmarks = LandmarkMeasurement()
            var clip = LandmarkClipMeasurement()
            clip.bufferedFrames = 3
            clip.admittedFrames = 3
            clip.framesWithFace = 3
            landmarks.clip = clip
            value.landmarks = landmarks
            value.outcome = "3-second capture limit reached"
            value.completionKind = .durationLimit
            return value
        }
        var invalid = CapturedCameraClip(measurement: measurement(UUID()), features: features)
        precondition(invalid.classificationRejection == nil)
        precondition(invalid.measurement.durationLimitOutcome == "3-second capture limit reached")
        precondition(invalid.measurement.frameLimitOutcome == "64-frame capture limit reached")
        // Completion is typed: neither stale display text nor a future wording
        // change can reject a successful duration-limited capture.
        invalid.measurement.outcome = "Ten-second capture limit reached"
        precondition(invalid.classificationRejection == nil)
        invalid.measurement.completionKind = .failed
        invalid.measurement.outcome = "3-second capture limit reached"
        precondition(invalid.classificationRejection != nil)
        invalid.measurement.completionKind = nil
        precondition(invalid.classificationRejection != nil)
        invalid.measurement.completionKind = .durationLimit
        let roundTrip = try JSONDecoder().decode(CameraMeasurement.self,
            from: JSONEncoder().encode(invalid.measurement))
        precondition(roundTrip.completionKind == .durationLimit)
        let oldLimits = CameraConfiguration(mode: .handAndFace, framesPerSecond: 20,
                                           handTestScene: .unspecified).measurement(id: UUID())
        precondition(oldLimits.durationLimitOutcome == "Ten-second capture limit reached"
                     && oldLimits.frameLimitOutcome == "300-frame capture limit reached")
        invalid.measurement.invalidTimestampCount = 1
        precondition(invalid.classificationRejection != nil)
        invalid.measurement.invalidTimestampCount = 0
        invalid.measurement.landmarks?.clip?.resetCount = 1
        precondition(invalid.classificationRejection != nil)
        invalid.measurement.landmarks?.clip?.resetCount = 0
        invalid.measurement.landmarks?.clip?.evictedFrames = 1
        precondition(invalid.classificationRejection != nil)
        invalid.measurement.landmarks?.clip?.evictedFrames = 0
        invalid.measurement.landmarks?.clip?.framesWithFace = 0
        precondition(invalid.classificationRejection != nil)

        await camera.setFeatures(features)
        controller.startCamera()
        try await wait { await camera.captureCount == 1 }
        let config = await camera.configuration!
        precondition(config.framesPerSecond == 20 && config.measurement(id: UUID()).frameLimit == 64
                     && config.measurement(id: UUID()).durationLimitSeconds == 3)
        let firstID = controller.report.activeCameraID!
        let earlyStarts = await classifier.runCount
        precondition(earlyStarts == 0)
        controller.finishSignCapture()
        try await wait { await camera.stopCount == 1 }
        precondition(controller.busy && controller.finishingSignCapture)
        await camera.finish(reason: "Sign capture completed by user", measurement: measurement(firstID))
        try await wait { await classifier.runCount == 1 }
        precondition(controller.busy && !controller.cameraActive && controller.classifierActive
                     && controller.report.activeCameraID == nil)
        controller.memoryWarningReceived()
        try await wait { await classifier.stopCount == 1 }
        var late = ClassifierMeasurement(id: controller.report.activeClassifierID!)
        late.cameraPrediction = CameraPredictionMeasurement(captureID: firstID)
        late.cameraPrediction?.candidates = [ClassifierCandidate(label: "hello", score: 0.9, index: 15)]
        await classifier.finish(measurement: late)
        try await wait { !controller.busy }
        precondition(controller.classifierMeasurement?.cameraPrediction?.candidates.isEmpty == true)
        precondition(!controller.confirmCandidate(captureID: firstID, index: 15), "Cancelled result was confirmable")

        await camera.setFeatures(features)
        controller.startCamera()
        try await wait { await camera.captureCount == 2 }
        let secondID = controller.report.activeCameraID!
        await camera.emitPrevious(.stage("stale camera stage"))
        precondition(!controller.phase.contains("stale"))
        await camera.finish(reason: "3-second capture limit reached", measurement: measurement(secondID))
        try await wait { await classifier.runCount == 2 }
        var completed = ClassifierMeasurement(id: controller.report.activeClassifierID!)
        completed.outcome = "candidate inference completed"
        completed.cameraPrediction = CameraPredictionMeasurement(captureID: secondID)
        completed.cameraPrediction?.candidates = [ClassifierCandidate(label: "hello", score: 0.9, index: 15),
            ClassifierCandidate(label: "drink", score: 0.1, index: 5)]
        precondition(!controller.confirmCandidate(captureID: secondID, index: 15), "Active inference was confirmable")
        await classifier.finish(measurement: completed)
        try await wait { !controller.busy }
        precondition(controller.classifierMeasurement?.cameraPrediction?.candidates.first?.label == "hello")
        precondition(controller.confirmedTokens.isEmpty, "A prediction was automatically confirmed")
        precondition(!controller.confirmCandidate(captureID: firstID, index: 15), "Stale result was confirmable")
        precondition(!controller.confirmCandidate(captureID: secondID, index: 49), "Unknown candidate was confirmable")
        precondition(controller.confirmCandidate(captureID: secondID, index: 5))
        precondition(!controller.confirmCandidate(captureID: secondID, index: 15), "Double tap added two tokens")
        let token = controller.confirmedTokens[0]
        precondition(token.text == "drink" && token.originalCandidate.index == 5
                     && token.originalCandidate.score == 0.1 && token.captureID == secondID)
        precondition(!controller.editToken(id: token.id, text: " \n "))
        precondition(!controller.editToken(id: token.id, text: String(repeating: "x", count: 65)))
        precondition(controller.editToken(id: token.id, text: "  private correction  "))
        precondition(controller.confirmedTokens[0].text == "private correction"
                     && controller.confirmedTokens[0].originalCandidate.label == "drink")
        controller.repeatToken(id: token.id)
        precondition(controller.confirmedTokens.count == 2 && controller.confirmedTokens[1].id != token.id)
        controller.removeToken(id: token.id)
        precondition(controller.confirmedTokens.count == 1)
        precondition(!controller.editToken(id: token.id, text: "removed"))
        let repeatedID = controller.confirmedTokens[0].id
        for _ in 0..<40 { controller.repeatToken(id: repeatedID) }
        precondition(controller.confirmedTokens.count == ConversationController.tokenLimit)
        let report = controller.reportText
        precondition(!report.contains("\"values\"") && !report.contains("\"features\""))
        precondition(!report.contains("private correction"), "Confirmed text leaked into diagnostics")
        controller.clearSignSession()
        precondition(controller.confirmedTokens.isEmpty && controller.pendingPrediction == nil)
        precondition(!controller.confirmCandidate(captureID: secondID, index: 5), "Clear resurrected an old prediction")

        let noHands = FeatureEncoder.Encoded(values: features.values, validFrames: 3, discardedEmptyFrames: 0, handFrames: 0)
        await camera.setFeatures(noHands)
        controller.startCamera()
        try await wait { await camera.captureCount == 3 }
        let thirdID = controller.report.activeCameraID!
        await camera.finish(reason: "3-second capture limit reached", measurement: measurement(thirdID))
        try await wait { !controller.busy }
        precondition(controller.cameraMeasurement?.candidateRejection?.contains("No accepted hand") == true)

        await camera.setFeatures(features)
        controller.startCamera()
        try await wait { await camera.captureCount == 4 }
        let fourthID = controller.report.activeCameraID!
        controller.stopCamera()
        try await wait { await camera.stopCount == 2 }
        await camera.finish(reason: "3-second capture limit reached", measurement: measurement(fourthID))
        try await wait { !controller.busy }
        let finalStarts = await classifier.runCount
        precondition(finalStarts == 2, "Cancelled/rejected clip reached the classifier")
        // A separate unreviewed capture can be dismissed without changing tokens.
        await camera.setFeatures(features)
        controller.startCamera()
        try await wait { await camera.captureCount == 5 }
        let fifthID = controller.report.activeCameraID!
        await camera.finish(reason: "3-second capture limit reached", measurement: measurement(fifthID))
        try await wait { await classifier.runCount == 3 }
        let candidates = completed.cameraPrediction!.candidates
        completed = ClassifierMeasurement(id: controller.report.activeClassifierID!)
        completed.outcome = "candidate inference completed"
        completed.cameraPrediction = CameraPredictionMeasurement(captureID: fifthID)
        completed.cameraPrediction?.candidates = candidates
        await classifier.finish(measurement: completed)
        try await wait { !controller.busy }
        precondition(controller.pendingPrediction?.captureID == fifthID)
        controller.dismissCandidates(captureID: secondID)
        precondition(controller.pendingPrediction != nil)
        controller.dismissCandidates(captureID: fifthID)
        precondition(controller.pendingPrediction == nil && controller.confirmedTokens.isEmpty)
        await camera.setFeatures(features)
        controller.startCamera()
        try await wait { await camera.captureCount == 6 }
        let sixthID = controller.report.activeCameraID!
        await camera.finish(reason: "3-second capture limit reached", measurement: measurement(sixthID))
        try await wait { await classifier.runCount == 4 }
        completed = ClassifierMeasurement(id: controller.report.activeClassifierID!)
        completed.outcome = "candidate inference completed"
        completed.cameraPrediction = CameraPredictionMeasurement(captureID: sixthID)
        completed.cameraPrediction?.candidates = candidates
        await classifier.finish(measurement: completed)
        try await wait { !controller.busy }
        precondition(controller.confirmCandidate(captureID: sixthID, index: 5))
        let retainedID = controller.confirmedTokens[0].id
        await camera.setFeatures(features)
        controller.startCamera()
        try await wait { await camera.captureCount == 7 }
        precondition(controller.pendingPrediction == nil && controller.confirmedTokens[0].id == retainedID)
        precondition(!controller.editToken(id: retainedID, text: "busy edit"))
        controller.clearSignSession()
        controller.removeToken(id: retainedID)
        controller.repeatToken(id: retainedID)
        precondition(controller.confirmedTokens.count == 1, "Busy mutation changed confirmed text")
        let seventhID = controller.report.activeCameraID!
        controller.stopCamera()
        try await wait { await camera.stopCount == 3 }
        await camera.finish(reason: "Camera stopped by user", measurement: measurement(seventhID))
        try await wait { !controller.busy }
        precondition(controller.confirmedTokens.count == 1 && controller.confirmedTokens[0].id == retainedID)
        controller.generateSentence()
        precondition(controller.sentenceError != nil && !controller.busy, "Missing model was ignored")
        controller.importModel(source)
        try await wait { !controller.busy }
        precondition(controller.editToken(id: retainedID, text: "PRIVATE_GLOSS"))
        controller.repeatToken(id: retainedID)
        controller.generateSentence()
        try await wait { await sentenceRunner.generationCount == 1 }
        let submitted = await sentenceRunner.lastGlosses
        let usedGPU = await sentenceRunner.lastGPU
        precondition(submitted == "PRIVATE_GLOSS PRIVATE_GLOSS" && usedGPU,
                     "Generation did not preserve edited text, order, repetition or GPU policy")
        precondition(controller.busy && controller.generating && controller.sentenceDraft.isEmpty)
        controller.clearSignSession()
        precondition(controller.confirmedTokens.count == 2)
        await sentenceRunner.setHoldUnload(true)
        let completionStart = ProcessInfo.processInfo.systemUptime
        await sentenceRunner.finish(outcome: "completed", response: "PRIVATE_SENTENCE")
        try await wait { await sentenceRunner.unloadPending }
        precondition(controller.busy && !controller.speaking && speaker.requests.isEmpty,
                     "Speech or controls were released before native unload completed")
        await sentenceRunner.finishUnload()
        try await wait { !controller.busy }
        precondition(ProcessInfo.processInfo.systemUptime - completionStart < 1.5,
                     "Conversation retained the diagnostic two-second settling pause")
        precondition(controller.report.memoryObservations?.contains { $0.reason == "after engine release" } == true)
        precondition(controller.sentenceAvailable && controller.sentenceDraft == "PRIVATE_SENTENCE"
                     && !controller.engineLoaded && controller.response.isEmpty)
        precondition(controller.speaking && speaker.requests.count == 1
                     && speaker.requests[0].text == "PRIVATE_SENTENCE"
                     && controller.report.speechRuns?.last?.source == "automatic")
        let firstSpeechID = speaker.requests[0].id
        let previousLoads = await sentenceRunner.loadCount
        controller.load()
        controller.startCamera()
        controller.runClassifier()
        controller.generateSentence()
        let blockedLoads = await sentenceRunner.loadCount
        let blockedCaptures = await camera.captureCount
        precondition(previousLoads == blockedLoads && blockedCaptures == 7,
                     "Native work overlapped speech")
        let checkpoint = try String(contentsOf: support.appendingPathComponent("report.json"), encoding: .utf8)
        precondition(!checkpoint.contains("PRIVATE_GLOSS") && !checkpoint.contains("PRIVATE_SENTENCE")
                     && controller.report.generations.last?.response == "[conversation text omitted]")
        controller.editSentence("")
        precondition(!controller.speaking && speaker.stopCount == 1)
        controller.editSentence("PRIVATE_EDIT")
        precondition(controller.sentenceDraft == "PRIVATE_EDIT", "Empty edits could not be corrected")
        controller.speakSentence()
        precondition(controller.speaking && speaker.requests.last?.text == "PRIVATE_EDIT"
                     && controller.report.speechRuns?.last?.source == "replay")
        let replayID = speaker.requests.last!.id
        speaker.emit(id: firstSpeechID, event: .finished)
        precondition(controller.speaking, "Stale speech callback completed a newer playback")
        speaker.holdStop = true
        controller.stopSpeech()
        let speechCountBeforeDrain = speaker.requests.count
        controller.speakSentence()
        precondition(controller.speaking && controller.speechStopping
                     && speaker.requests.count == speechCountBeforeDrain, "Speech stop did not retain its completion barrier")
        speaker.emit(id: replayID, event: .cancelled)
        precondition(!controller.speaking && !controller.speechStopping)
        speaker.holdStop = false
        controller.speakSentence()
        controller.interrupt(reason: "App backgrounded")
        precondition(!controller.speaking && controller.report.speechRuns?.last?.outcome == "stopped")
        controller.speakSentence()
        controller.memoryWarningReceived()
        precondition(!controller.speaking && controller.sentenceAvailable)
        speaker.failStart = true
        controller.speakSentence()
        precondition(!controller.speaking && controller.speechError != nil
                     && controller.report.speechRuns?.last?.outcome == "failed to start")
        speaker.failStart = false
        controller.speakSentence()
        let completedSpeechID = speaker.requests.last!.id
        speaker.emit(id: replayID, event: .cancelled)
        precondition(controller.speaking)
        speaker.emit(id: completedSpeechID, event: .finished)
        precondition(!controller.speaking && controller.report.speechRuns?.last?.outcome == "completed")
        precondition(controller.editToken(id: retainedID, text: "CHANGED_GLOSS"))
        precondition(!controller.sentenceAvailable && controller.sentenceDraft.isEmpty)
        let spokenBeforeCancellation = speaker.requests.count
        controller.generateSentence()
        try await wait { await sentenceRunner.generationCount == 2 }
        controller.stopConversation()
        try await wait { await sentenceRunner.cancellationCount == 1 }
        await sentenceRunner.finish(outcome: "completed", response: "PRIVATE_LATE_SENTENCE")
        try await wait { !controller.busy }
        precondition(!controller.sentenceAvailable && controller.sentenceDraft.isEmpty && !controller.engineLoaded)
        precondition(!controller.reportText.contains("PRIVATE_LATE_SENTENCE"))
        precondition(speaker.requests.count == spokenBeforeCancellation, "Cancelled generation was spoken")
        controller.generateSentence()
        controller.stopConversation()
        try await wait { !controller.busy }
        let countAfterPreemption = await sentenceRunner.generationCount
        precondition(countAfterPreemption == 2, "Preempted conversation still invoked generation")
        controller.generateSentence()
        try await wait { await sentenceRunner.generationCount == 3 }
        await sentenceRunner.setHoldUnload(true)
        await sentenceRunner.finish(outcome: "completed", response: "PRIVATE_DRAIN_SENTENCE")
        try await wait { await sentenceRunner.unloadPending }
        precondition(controller.sentenceAvailable && controller.busy && !controller.speaking)
        controller.stopConversation()
        await sentenceRunner.finishUnload()
        try await wait { !controller.busy }
        precondition(!controller.sentenceAvailable && controller.sentenceDraft.isEmpty,
                     "Stop during engine release left a usable sentence")
        precondition(speaker.requests.count == spokenBeforeCancellation, "Drain-cancelled generation was spoken")
        controller.generateSentence()
        try await wait { await sentenceRunner.generationCount == 4 }
        await sentenceRunner.finish(outcome: "empty response")
        try await wait { !controller.busy }
        precondition(controller.sentenceError != nil && !controller.sentenceAvailable && !controller.engineLoaded)
        precondition(speaker.requests.count == spokenBeforeCancellation, "Empty output was spoken")
        controller.removeToken(id: controller.confirmedTokens[1].id)
        precondition(controller.editToken(id: retainedID, text: "drink"))
        controller.generateSentence()
        try await wait { await sentenceRunner.generationCount == 5 }
        await sentenceRunner.finish(outcome: "completed", response: "Drink drink")
        try await wait { !controller.busy }
        precondition(!controller.sentenceAvailable && !controller.engineLoaded
                     && controller.sentenceError?.contains("repeated") == true)
        precondition(speaker.requests.count == spokenBeforeCancellation, "Rejected output was spoken")
        let repetitionCheck = controller.report.generations.last!
        precondition(repetitionCheck.outcome == "rejected unexpected single-gloss repetition"
                     && repetitionCheck.textDiagnostics?.confirmedTokenCount == 1
                     && repetitionCheck.textDiagnostics?.inputWordCount == 1
                     && repetitionCheck.textDiagnostics?.outputWordCount == 2
                     && repetitionCheck.textDiagnostics?.outputTextPartCount == nil)
        controller.repeatToken(id: retainedID)
        controller.generateSentence()
        try await wait { await sentenceRunner.generationCount == 6 }
        await sentenceRunner.finish(outcome: "completed", response: "Drink drink")
        try await wait { !controller.busy }
        precondition(controller.sentenceAvailable && controller.sentenceDraft == "Drink drink",
                     "Intentional input repetition was silently removed or rejected")
        precondition(controller.speaking && !controller.engineLoaded)
        controller.removeToken(id: controller.confirmedTokens[1].id)
        precondition(!controller.speaking && !controller.sentenceAvailable)
        precondition(controller.editToken(id: retainedID, text: String(repeating: "x", count: 64)))
        controller.repeatToken(id: retainedID) // Two valid edits plus separator exceed the new 128-byte input budget.
        controller.generateSentence()
        precondition(!controller.busy && controller.sentenceError?.contains("shorten") == true)
        for _ in 0..<7 { controller.repeatToken(id: retainedID) }
        controller.generateSentence()
        precondition(!controller.busy && controller.sentenceError?.contains("eight") == true)
        let finalGenerationCount = await sentenceRunner.generationCount
        precondition(finalGenerationCount == 6, "Over-budget utterance reached Gemma")
        controller.clearSignSession()
        precondition(!controller.sentenceAvailable && controller.sentenceError == nil)
        precondition(!controller.reportText.contains("PRIVATE_SENTENCE") && !controller.reportText.contains("PRIVATE_EDIT"),
                     "Spoken text leaked into diagnostic metadata")
        let finalSpeechJSON = try JSONSerialization.jsonObject(with: controller.report.json()) as! [String: Any]
        precondition(finalSpeechJSON["speechRuns"] != nil)
        await camera.setFeatures(features)
        controller.recordConversationSign()
        try await wait { await camera.captureCount == 8 }
        precondition(controller.captureMode == .signCandidates && !controller.engineLoaded)
        let eighthID = controller.report.activeCameraID!
        controller.stopConversation()
        try await wait { await camera.stopCount == 4 }
        await camera.finish(reason: "Camera stopped by user", measurement: measurement(eighthID))
        try await wait { !controller.busy }
        print("PASS: conversation GPU load/generate/release, repeated edited glosses, draft editing/invalidation, privacy, missing-model/budget rejection and cancelled/empty output suppression")
        print("PASS: automatic speech after release, native exclusion, edited replay, stop/background/pressure, missing-voice recovery, stale callbacks and spoken-text privacy")
        print("PASS: explicit candidate confirmation, stale/duplicate/cancel rejection, aligned provenance, token correction/repetition/removal/bounds/reset and text privacy")
        print("PASS: bounded sign capture, feature handoff after teardown, rejection, finish/cancel routing, stale callback isolation, cancelled candidate suppression and report privacy")
    }

    @MainActor
    private static func checkCameraLifecycle(source: URL, support: URL, manifest: ModelManifest) async throws {
        let preemptedCamera = ControlledCamera()
        let preempted = ConversationController(runner: ControlledRunner(), camera: preemptedCamera,
                                       supportDirectory: support.appendingPathComponent("preempted"), manifest: manifest)
        preempted.startCamera()
        preempted.stopCamera()
        try await wait { !preempted.busy }
        let preemptedStarts = await preemptedCamera.captureCount
        precondition(preemptedStarts == 0 && preempted.report.cameraCaptures?.last?.frames == 0,
                     "An immediate stop still initiated camera authorization")
        let runner = ControlledRunner()
        let camera = ControlledCamera()
        let controller = ConversationController(runner: runner, camera: camera, supportDirectory: support, manifest: manifest)
        controller.captureMode = .handAndFace
        controller.cameraFramesPerSecond = 20
        controller.handTestScene = .anatomicalLeftOnly
        controller.startCamera()
        try await wait { await camera.captureCount == 1 }
        let selectedMode = await camera.mode
        precondition(selectedMode == .handAndFace, "Requested landmark mode was lost")
        let selectedConfiguration = await camera.configuration
        precondition(selectedConfiguration?.framesPerSecond == 20
                     && selectedConfiguration?.handTestScene == .anatomicalLeftOnly,
                     "Diagnostic capture configuration was lost")
        precondition(controller.cameraActive && controller.busy && controller.report.running)
        let firstID = controller.report.activeCameraID
        controller.load()
        controller.generate()
        controller.importModel(source)
        controller.startCamera()
        let firstCounts = await (runner.loadCount, runner.generationCount, camera.captureCount)
        precondition(firstCounts == (0, 0, 1) && !controller.hasModel, "Work overlapped pending camera authorization")

        // A stop request alone cannot unlock the UI: native teardown must finish.
        controller.stopCamera()
        controller.stopCamera()
        try await wait { await camera.stopCount == 1 }
        await camera.emit(.stage("late authorization granted"))
        precondition(controller.cameraStopping && controller.busy && controller.phase.contains("stopping camera"))
        controller.load()
        controller.startCamera()
        let stops = await camera.stopCount
        precondition(stops == 1, "Stop was duplicated")
        await camera.finish(reason: "Camera stopped by user")
        try await wait { !controller.busy }
        precondition(!controller.cameraActive && !controller.cameraStopping && controller.report.activeCameraID == nil)
        precondition(controller.report.cameraCaptures?.last?.frames == 0, "Permission-stage stop invented frames")

        // A previous capture's callback must not overwrite the next capture.
        controller.startCamera()
        try await wait { await camera.captureCount == 2 }
        precondition(controller.report.activeCameraID != firstID)
        await camera.emitPrevious(.stage("obsolete capture callback"))
        precondition(!controller.phase.contains("obsolete"), "Stale callback changed the new session")
        var frames = CameraMeasurement(id: controller.report.activeCameraID!)
        frames.captureMode = .handAndFace
        var landmarkSummary = LandmarkMeasurement()
        landmarkSummary.processedFrames = 31
        landmarkSummary.framesWithOneHand = 31
        landmarkSummary.latestHandPointCounts = [21]
        landmarkSummary.latestRawHandedness = ["Left"]
        landmarkSummary.latestRawHandednessScores = [0.95]
        landmarkSummary.singleHandRawLabelCounts = ["Left": 31]
        landmarkSummary.firstTimestampMilliseconds = 0
        landmarkSummary.lastTimestampMilliseconds = 1_000
        frames.landmarks = landmarkSummary
        frames.frames = 31
        frames.width = 480
        frames.height = 640
        frames.firstFrameTimestampSeconds = 100
        frames.lastFrameTimestampSeconds = 101
        frames.captureElapsedSeconds = 1.0
        frames.teardownSeconds = 0.1
        await camera.emit(.frames(frames))
        precondition(controller.cameraMeasurement?.deliveredFramesPerSecond == 30)
        precondition(controller.report.activeCameraMeasurement?.frames == 31, "Live checkpoint lost camera metadata")
        controller.interrupt(reason: "App backgrounded")
        try await wait { await camera.stopCount == 2 }
        precondition(controller.busy && controller.cameraStopping)
        await camera.finish(reason: "App backgrounded", measurement: frames)
        try await wait { !controller.busy }

        controller.startCamera()
        try await wait { await camera.captureCount == 3 }
        controller.memoryWarningReceived()
        controller.memoryWarningReceived()
        try await wait { await camera.stopCount == 3 }
        precondition(controller.report.memoryWarningCount == 2 && controller.busy)
        await camera.finish(reason: "Memory warning received")
        try await wait { !controller.busy }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(DiagnosticsReport.self, from: Data(contentsOf: support.appendingPathComponent("report.json")))
        precondition(report.cameraCaptures?.count == 3 && !report.running && report.activeCameraID == nil && report.activeCameraMeasurement == nil)
        precondition(report.cameraCaptures?[1].frames == 31 && report.cameraCaptures?[1].outcome == "App backgrounded")
        precondition(report.cameraCaptures?[1].landmarks?.processedFramesPerSecond == 30
                     && report.cameraCaptures?[1].landmarks?.latestHandPointCounts == [21],
                     "Landmark diagnostics did not survive interruption/checkpoint encoding")
        precondition(report.cameraCaptures?[1].captureElapsedSeconds == 1.0
                     && report.cameraCaptures?[1].teardownSeconds == 0.1
                     && report.cameraCaptures?[1].handTestScene == .anatomicalLeftOnly
                     && report.cameraCaptures?[1].landmarks?.singleHandRawLabelCounts == ["Left": 31],
                     "Capture timing/labelled-scene evidence was lost")
        let runtimeCounts = await (runner.loadCount, runner.unloadCount, runner.cancellationCount)
        precondition(runtimeCounts == (0, 0, 0), "Camera pressure invoked the language runtime")

        // Authorization/configuration errors recover without starting the engine.
        controller.startCamera()
        try await wait { await camera.captureCount == 4 }
        await camera.fail()
        try await wait { !controller.busy }
        precondition(!controller.cameraActive && controller.phase.contains("Failed:"))
        controller.importModel(source)
        try await wait { !controller.busy }
        controller.load()
        try await wait { !controller.busy }
        controller.startCamera()
        let captures = await camera.captureCount
        precondition(captures == 4 && controller.engineLoaded, "Camera started with Gemma loaded")
        controller.unload()
        try await wait { !controller.busy }
        controller.startCamera()
        try await wait { await camera.captureCount == 5 }
        await camera.finish(reason: "Ten-second capture limit reached")
        try await wait { !controller.busy }
        precondition(controller.report.cameraCaptures?.last?.outcome == "Ten-second capture limit reached")
        print("PASS: camera authorization stop, teardown barrier, mode exclusion, stale callbacks, background/pressure release, error recovery, persisted frame metadata")
    }

    private static func checkVideoTimestamps() {
        var gate = VideoTimestampGate()
        precondition(gate.accept(seconds: .nan) == nil && gate.accept(seconds: .infinity) == nil)
        precondition(gate.accept(seconds: 100) == 0)
        precondition(gate.accept(seconds: 100) == nil && gate.accept(seconds: 99) == nil)
        precondition(gate.accept(seconds: 100.0001) == nil, "Millisecond collision reached a tracking graph")
        precondition(gate.accept(seconds: 100.125) == 125)
        precondition(gate.accept(seconds: .greatestFiniteMagnitude) == nil, "Timestamp conversion overflowed")
        precondition(gate.accept(seconds: 100.250) == 250, "Rejected timestamps poisoned subsequent valid input")
        var fresh = VideoTimestampGate()
        precondition(fresh.accept(seconds: 200) == 0, "A new capture inherited a previous timestamp")
        print("PASS: shared monotonic video timestamps, collision/invalid rejection, per-capture reset")
    }

    private static func checkCaptureBoundaries() throws {
        var value = CameraMeasurement(id: UUID())
        precondition(!value.captureLimitReached(at: 200), "Pending permission exhausted a capture deadline")
        value.captureStartUptime = 100
        precondition(!value.captureLimitReached(at: 109.999) && value.captureLimitReached(at: 110),
                     "A frame at/after the capture deadline was admitted")
        value.markCaptureEnded(at: 110.025)
        let ended = value.captureEndedAt
        value.markCaptureEnded(at: 111)
        precondition(value.captureEndUptime == 110.025 && value.captureEndedAt == ended)
        precondition(abs(value.captureElapsedSeconds! - 10.025) < 0.0001,
                     "Repeated finish changed the capture boundary")
        value.observeGeometry(width: 480, height: 640, rotation: 90)
        value.frames += 1
        value.observeGeometry(width: 480, height: 640, rotation: 90)
        value.frames += 1
        // applyRotation may update the output setting before the next sample.
        value.captureRotationDegrees = 270
        value.observeGeometry(width: 480, height: 640, rotation: 270)
        value.frames += 1
        precondition(value.geometryChangeCount == 1, "Same-size upside-down rotation was missed")
        for index in 0..<40 {
            value.observeGeometry(width: index.isMultiple(of: 2) ? 640 : 480,
                                  height: index.isMultiple(of: 2) ? 480 : 640,
                                  rotation: index.isMultiple(of: 2) ? 0 : 90)
            value.frames += 1
        }
        precondition(value.geometryObservations?.count == 16 && value.geometryChangeCount == 41,
                     "Geometry history was unbounded or stopped counting changes")
        let preview = PreviewGeometryObservation(widthPoints: 350, heightPoints: 260,
                                                rotationDegrees: 0, mirrored: true)
        value.observePreviewGeometry(preview)
        value.observePreviewGeometry(preview)
        precondition(value.previewGeometryObservations?.count == 1,
                     "Repeated layout filled preview history")
        value.observePreviewGeometry(PreviewGeometryObservation(widthPoints: 0, heightPoints: 260,
                                                               rotationDegrees: .nan, mirrored: true))
        precondition(value.latestPreviewGeometry == preview, "Invalid/unattached preview replaced valid evidence")
        for index in 0..<40 {
            value.observePreviewGeometry(PreviewGeometryObservation(widthPoints: Double(351 + index),
                heightPoints: 260, rotationDegrees: index.isMultiple(of: 2) ? 0 : 90, mirrored: true))
        }
        precondition(value.previewGeometryObservations?.count == 16
                     && value.latestPreviewGeometry?.widthPoints == 390,
                     "Preview history was unbounded or lost its latest layout")
        let encoded = try JSONEncoder().encode(value)
        let roundTrip = try JSONDecoder().decode(CameraMeasurement.self, from: encoded)
        precondition(roundTrip.latestPreviewGeometry == value.latestPreviewGeometry
                     && roundTrip.previewGeometryObservations?.count == 16,
                     "Preview diagnostics did not survive checkpoint encoding")
        let json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        precondition(json["captureStartUptime"] == nil && json["captureEndUptime"] == nil
                     && json["lastObservedFrameGeometry"] == nil, "Queue-local timing/geometry leaked into report")
        print("PASS: frame deadline boundary, idempotent capture end, bounded geometry history, report privacy")
        print("PASS: bounded/deduplicated preview layout, invalid geometry rejection, checkpoint persistence, legacy preview absence")
    }

    private static func checkFrameBrightness() throws {
        // Nonzero alpha and row padding must not make black BGRA pixels bright.
        var black = Data(repeating: 255, count: 16 * 80)
        for row in 0..<16 {
            for column in 0..<16 {
                for channel in 0..<3 { black[row * 80 + column * 4 + channel] = 0 }
            }
        }
        let dark = black.withUnsafeBytes { FrameBrightnessSample.bgra($0, width: 16, height: 16, bytesPerRow: 80) }
        precondition(dark?.mean == 0 && dark?.minimum == 0 && dark?.maximum == 0
                     && dark?.nearBlackFraction == 1, "Brightness read alpha or row padding as pixels")
        let white = Data(repeating: 255, count: 16 * 64)
        let bright = white.withUnsafeBytes { FrameBrightnessSample.bgra($0, width: 16, height: 16, bytesPerRow: 64) }
        precondition(bright?.mean == 255 && bright?.nearBlackFraction == 0)
        let truncated = white.withUnsafeBytes { FrameBrightnessSample.bgra($0, width: 16, height: 17, bytesPerRow: 64) }
        let badStride = white.withUnsafeBytes { FrameBrightnessSample.bgra($0, width: 16, height: 16, bytesPerRow: 63) }
        precondition(truncated == nil && badStride == nil)
        var value = CameraMeasurement(id: UUID())
        var brightness = FrameBrightnessMeasurement()
        brightness.record(dark)
        brightness.record(bright)
        brightness.record(nil)
        precondition(brightness.sampledFrames == 2 && brightness.nearBlackFrames == 1
                     && brightness.failedSamples == 1 && brightness.maximumObservedMean == 255)
        value.frameBrightness = brightness
        let encoded = try JSONEncoder().encode(value)
        let restored = try JSONDecoder().decode(CameraMeasurement.self, from: encoded)
        precondition(restored.frameBrightness?.first?.mean == 0 && restored.frameBrightness?.latest?.mean == 255)
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "frameBrightness")
        let old = try JSONDecoder().decode(CameraMeasurement.self,
                                          from: JSONSerialization.data(withJSONObject: legacy))
        precondition(old.frameBrightness == nil)
        print("PASS: BGRA brightness sampling, alpha/stride isolation, truncated-buffer rejection, aggregate/legacy reports")
    }

    private static func checkLandmarkClip() throws {
        var clip = LandmarkClipBuffer()
        let portrait = CameraGeometryObservation(frameNumber: 1, width: 480, height: 640, rotationDegrees: 90)
        let landscape = CameraGeometryObservation(frameNumber: 80, width: 640, height: 480, rotationDegrees: 0)
        let hand = Array(repeating: LandmarkPoint(x: 0.1, y: 0.2, z: -0.3), count: 21)
        let face = Array(repeating: LandmarkPoint(x: 0.4, y: 0.5, z: 0.6), count: 478)
        for index in 0..<80 {
            clip.append(seconds: Double(index) / 20, left: hand, right: index == 79 ? nil : hand,
                        face: face, geometry: portrait, epoch: 0, mirrored: false)
        }
        precondition(clip.frames.count == 64 && clip.measurement.evictedFrames == 16)
        precondition(clip.frames.first?.seconds == 0.8 && clip.frames.last?.seconds == 3.95)
        precondition(clip.frames.last?.right == nil && clip.measurement.framesWithBothCandidates == 63,
                     "Missing hands were replaced by stale coordinates")
        clip.append(seconds: 4, left: hand, right: nil, face: face,
                    geometry: landscape, epoch: 1, mirrored: false)
        precondition(clip.frames.count == 1 && clip.measurement.resetCount == 1,
                     "Clip combined different capture geometries")
        clip.append(seconds: 4.5, left: nil, right: nil, face: nil,
                    geometry: landscape, epoch: 1, mirrored: false)
        precondition(clip.frames.count == 1 && clip.measurement.resetCount == 2,
                     "Long capture gap retained stale motion context")
        var invalidHand = hand
        invalidHand[0] = LandmarkPoint(x: .nan, y: 0, z: 0)
        clip.append(seconds: 4.55, left: invalidHand, right: Array(hand.prefix(20)), face: face,
                    geometry: landscape, epoch: 1, mirrored: false)
        precondition(clip.frames.last?.left == nil && clip.frames.last?.right == nil
                     && clip.measurement.invalidParts == 2)
        clip.append(seconds: 4.55, left: hand, right: hand, face: face,
                    geometry: landscape, epoch: 1, mirrored: false)
        precondition(clip.frames.isEmpty && clip.measurement.invalidTimestampFrames == 1)
        clip.append(seconds: .infinity, left: nil, right: nil, face: nil,
                    geometry: landscape, epoch: 1, mirrored: false)
        precondition(clip.frames.isEmpty && clip.measurement.invalidTimestampFrames == 2)
        clip.append(seconds: 5, left: hand, right: nil, face: face,
                    geometry: landscape, epoch: 1, mirrored: false)
        clip.append(seconds: 5.05, left: nil, right: nil, face: nil,
                    geometry: landscape, epoch: 1, mirrored: true)
        precondition(clip.frames.count == 1 && clip.measurement.lastResetReason == "capture geometry changed")
        let report = LandmarkMeasurement()
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as! [String: Any]
        legacy.removeValue(forKey: "clip")
        let restored = try JSONDecoder().decode(LandmarkMeasurement.self,
                                               from: JSONSerialization.data(withJSONObject: legacy))
        precondition(restored.clip == nil)
        let summary = try JSONSerialization.jsonObject(with: JSONEncoder().encode(clip.measurement)) as! [String: Any]
        precondition(summary["frames"] == nil && summary["left"] == nil && summary["face"] == nil,
                     "Raw landmark coordinates leaked into report")
        print("PASS: bounded landmark clips, explicit absence, geometry/gap resets, invalid points/timestamps, aggregate-only reports")
    }

    private static func checkHandIdentity() throws {
        // Match LandmarkProcessor's class-stored struct and exercise the same
        // production helper with runtime exclusivity checking enabled.
        final class MeasurementOwner {
            var measurement = LandmarkMeasurement()
        }
        let owner = MeasurementOwner()
        let geometry = CameraGeometryObservation(frameNumber: 1, width: 480, height: 640, rotationDegrees: 90)
        owner.measurement.latestHandPointCounts = [21]
        owner.measurement.latestRawHandedness = ["Left"]
        owner.measurement.latestRawHandednessScores = [0.95]
        owner.measurement.recordHandIdentity(geometry: geometry, epoch: 0, mirrored: false)
        precondition(owner.measurement.handIdentity?.latestResolution.leftSourceIndex == 0,
                     "Class-stored measurement update failed")
        owner.measurement.latestHandPointCounts = []
        owner.measurement.latestRawHandedness = []
        owner.measurement.latestRawHandednessScores = []
        owner.measurement.recordHandIdentity(geometry: geometry, epoch: 0, mirrored: false)
        precondition(owner.measurement.handIdentity?.counts.processedFrames == 2
                     && owner.measurement.handIdentity?.counts.framesWithLeftCandidate == 1
                     && owner.measurement.handIdentity?.latestResolution.leftSourceIndex == nil,
                     "Class-stored update lost prior counts or reused stale hand slots")
        print("PASS: class-stored landmark diagnostics update without overlapping Swift accesses")
        let reversed = HandSlotResolution.resolve(pointCounts: [21, 21], labels: ["Right", "Left"],
                                                  scores: [0.9, 0.95], mirrored: false)
        let forward = HandSlotResolution.resolve(pointCounts: [21, 21], labels: ["Left", "Right"],
                                                 scores: [0.95, 0.9], mirrored: false)
        precondition(reversed.leftSourceIndex == 1 && reversed.rightSourceIndex == 0
                     && forward.leftSourceIndex == 0 && forward.rightSourceIndex == 1,
                     "Hand slots depended on result order")
        let duplicate = HandSlotResolution.resolve(pointCounts: [21, 21], labels: ["Left", "Left"],
                                                   scores: [0.99, 0.6], mirrored: false)
        precondition(duplicate.leftSourceIndex == nil && duplicate.rightSourceIndex == nil
                     && duplicate.rejectionReasons == ["duplicate hand label"],
                     "A duplicate-label tie was silently resolved")
        for score: Float in [0.799, .nan, .infinity, -0.1, 1.1] {
            let rejected = HandSlotResolution.resolve(pointCounts: [21], labels: ["Left"],
                                                       scores: [score], mirrored: false)
            precondition(rejected.leftSourceIndex == nil && !rejected.rejectionReasons.isEmpty)
        }
        let boundary = HandSlotResolution.resolve(pointCounts: [21], labels: ["Left"],
                                                  scores: [0.8], mirrored: false)
        precondition(boundary.leftSourceIndex == 0, "Diagnostic score boundary was inconsistent")
        let cases: [([Int], [String], [Float], Bool)] = [
            ([20], ["Left"], [0.9], false), ([21], ["unknown"], [0.9], false),
            ([21], [], [], false), ([21], ["Left"], [], false),
            ([21, 21, 21], ["Left", "Right", "Left"], [0.9, 0.9, 0.9], false),
            ([21], ["Left"], [0.9], true)
        ]
        for (points, labels, scores, mirrored) in cases {
            let rejected = HandSlotResolution.resolve(pointCounts: points, labels: labels,
                                                       scores: scores, mirrored: mirrored)
            precondition(rejected.leftSourceIndex == nil && rejected.rightSourceIndex == nil
                         && !rejected.rejectionReasons.isEmpty)
        }
        var diagnostics = HandIdentityMeasurement()
        let portrait = CameraGeometryObservation(frameNumber: 1, width: 480, height: 640, rotationDegrees: 90)
        diagnostics.record(pointCounts: [21, 21], labels: ["Right", "Left"], scores: [0.9, 0.95],
                           geometry: portrait, epoch: 0, mirrored: false)
        diagnostics.record(pointCounts: [], labels: [], scores: [], geometry: portrait, epoch: 0, mirrored: false)
        precondition(diagnostics.latestResolution.leftSourceIndex == nil
                     && diagnostics.latestResolution.rightSourceIndex == nil
                     && diagnostics.latestResolution.rejectionReasons.isEmpty,
                     "Missing hands reused stale slots")
        let landscape = CameraGeometryObservation(frameNumber: 3, width: 640, height: 480, rotationDegrees: 0)
        diagnostics.record(pointCounts: [21], labels: ["Right"], scores: [0.6],
                           geometry: landscape, epoch: 1, mirrored: false)
        precondition(diagnostics.counts.framesWithBothCandidates == 1
                     && diagnostics.counts.framesWithRejectedHands == 1
                     && diagnostics.counts.lowScoreHandCount == 1
                     && diagnostics.geometrySegments[0].counts.processedFrames == 2
                     && diagnostics.geometrySegments[1].counts.singleHandRawLabelCounts == ["Right": 1],
                     "Orientation segments mixed hand evidence")
        for epoch in 2...40 {
            diagnostics.record(pointCounts: [], labels: [], scores: [], geometry: portrait, epoch: epoch, mirrored: false)
        }
        precondition(diagnostics.geometrySegments.count == 16
                     && diagnostics.geometrySegments.first?.geometryEpoch == 25
                     && diagnostics.counts.processedFrames == 42,
                     "Bounded segment history lost capture totals")
        let encoded = try JSONEncoder().encode(diagnostics)
        let restored = try JSONDecoder().decode(HandIdentityMeasurement.self, from: encoded)
        precondition(restored.geometrySegments.count == 16 && restored.counts.processedFrames == 42
                     && restored.mappingStatus.contains("provisional") && restored.minimumLabelScore == 0.8)
        print("PASS: order-independent hand candidates, weak/duplicate/invalid rejection, missing-slot reset, bounded orientation evidence, legacy calibration reports")
    }

    @MainActor
    private static func checkMemoryInterruption(source: URL, support: URL, manifest: ModelManifest) async throws {
        let mock = ControlledRunner()
        let controller = ConversationController(runner: mock, supportDirectory: support, manifest: manifest)
        controller.importModel(source)
        try await wait { !controller.busy }
        controller.load()
        try await wait { !controller.busy }
        controller.promptIndex = 2
        controller.generate()
        try await wait { await mock.started }
        controller.memoryWarningReceived()
        controller.memoryWarningReceived()
        try await wait { await mock.cancellationObserved }
        precondition(controller.report.memoryWarningCount == 2, "Notifications were lost or counted twice")
        precondition(controller.report.events.filter { $0.contains("Memory warning notification #") }.count == 2)
        let warnings = controller.report.memoryObservations?.filter { $0.reason == "memory warning" } ?? []
        precondition(warnings.map(\.warningNumber) == [1, 2])
        precondition(warnings.first?.phase == "creating conversation" && warnings.first?.promptID == "gloss-3")
        precondition(controller.busy && controller.stopping && controller.engineLoaded)
        controller.unload()
        controller.generate()
        let pendingCounts = await (mock.cancellationCount, mock.unloadCount, mock.generationCount)
        precondition(pendingCounts == (1, 0, 1), "Repeated warnings duplicated cancellation or overlapped native work")
        await mock.finish(outcome: "completed", response: "No like milk.")
        try await wait { !controller.busy }
        precondition(controller.report.generations.last?.outcome == "Memory warning received")
        precondition(controller.report.generations.last?.response == "No like milk.", "Late native evidence was lost")
        precondition(!controller.engineLoaded)
        let observations = controller.report.memoryObservations ?? []
        precondition(observations.contains { $0.reason == "before engine release" })
        precondition(observations.contains { $0.reason == "two seconds after engine release" })
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode(DiagnosticsReport.self, from: Data(contentsOf: support.appendingPathComponent("report.json")))
        precondition(persisted.memoryWarningCount == 2 && persisted.memoryObservations?.count == observations.count)
        #if !os(iOS)
        precondition(observations.allSatisfy { $0.availableProcessMemoryBytes == nil },
                     "Host tests must not invent an iOS memory allowance")
        #endif
        controller.memoryWarningReceived() // Count an idle notification without initiating work.
        precondition(controller.report.memoryWarningCount == 3 && !controller.busy)
        let finalCounts = await (mock.loadCount, mock.unloadCount)
        precondition(finalCounts == (1, 1), "Memory pressure triggered an automatic reload or repeated unload")
        print("PASS: memory notification counting, one cancellation, delayed release, late response classification, persisted diagnostic snapshots")
    }

    @MainActor
    private static func checkWatchdog(source: URL, support: URL, manifest: ModelManifest) async throws {
        let mock = ControlledRunner(holdCancellation: true)
        let controller = ConversationController(runner: mock, supportDirectory: support, manifest: manifest,
                                         generationTimeoutSeconds: 1, cancellationGraceSeconds: 1)
        controller.importModel(source)
        try await wait { !controller.busy }
        controller.load()
        try await wait { !controller.busy }
        controller.promptIndex = 3
        let monitor = Task { await controller.monitor() }
        defer { monitor.cancel() }
        controller.generate()
        try await wait { controller.restartRequired }
        precondition(controller.busy && controller.generating && controller.stopping && controller.report.running)
        precondition(controller.report.activePromptID == "gloss-4")
        precondition(controller.report.events.contains { $0.contains("deadline reached") })
        precondition(controller.report.sampleCount > 5, "Monitoring stopped while native work was pending")
        let cancelPending = await mock.cancellationObserved
        precondition(cancelPending, "Watchdog did not request native cancellation")
        await mock.emitProgress("late native progress")
        precondition(controller.phase.contains("unresponsive"), "Late progress hid the stall warning")

        // Neither a stuck request nor a stuck cancellation call may unlock the engine.
        controller.generate()
        controller.load()
        controller.unload()
        let counts = await (mock.generationCount, mock.loadCount, mock.unloadCount)
        precondition(counts == (1, 1, 0), "Native work overlapped after timeout")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let checkpoint = try decoder.decode(DiagnosticsReport.self, from: Data(contentsOf: support.appendingPathComponent("report.json")))
        precondition(checkpoint.running && checkpoint.activePromptID == "gloss-4" && checkpoint.phase.contains("unresponsive"))

        await mock.finishCancellation()
        await mock.finish(outcome: "completed")
        try await wait { !controller.busy }
        precondition(!controller.engineLoaded && !controller.restartRequired && !controller.report.running)
        precondition(controller.report.activePromptID == nil)
        precondition(controller.report.generations.last?.outcome == "timeout requested",
                     "A late native response was incorrectly counted as a successful trial")
        precondition(controller.report.generations.last?.promptID == "gloss-4")
        let unloads = await mock.unloadCount
        precondition(unloads == 1, "Timed-out engine was not retired after native completion")

        // Completed requests cancel their timers; an old deadline cannot cancel a later run.
        controller.load()
        try await wait { !controller.busy }
        for expectedCount in 2...3 {
            controller.generate()
            try await wait { await mock.generationCount == expectedCount }
            await mock.finish(outcome: "completed")
            try await wait { !controller.busy }
        }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let cancellations = await mock.cancellationCount
        precondition(cancellations == 1 && controller.engineLoaded && !controller.stopping)
        print("PASS: watchdog covers conversation setup, blocked cancellation, persisted stall, guarded recovery, expired-timer isolation")
    }

    private static func checkLargeImportMemory(root: URL) async throws {
        let fixture = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = fixture.appendingPathComponent("large.bin")
        let chunk = Data(repeating: 0, count: 1_048_576)
        let chunkCount = 256
        let tail = Data("short final chunk".utf8)
        var expectedHash = SHA256()
        for _ in 0..<chunkCount { expectedHash.update(data: chunk) }
        expectedHash.update(data: tail)
        guard FileManager.default.createFile(atPath: source.path, contents: nil) else {
            throw AppError.invalidModel("Could not create large import fixture")
        }
        let file = try FileHandle(forWritingTo: source)
        defer { try? file.close() }
        // A sparse zero-filled file avoids allocating a model-sized Data fixture.
        try file.truncate(atOffset: UInt64(chunk.count * chunkCount))
        _ = try file.seekToEnd()
        try file.write(contentsOf: tail)
        try file.close()
        let manifest = ModelManifest(
            filename: "large.bin", revision: "test",
            bytes: Int64(chunk.count * chunkCount + tail.count),
            sha256: expectedHash.finalize().map { String(format: "%02x", $0) }.joined()
        )
        let models = ModelStore(directory: fixture.appendingPathComponent("installed"), manifest: manifest)
        guard let baseline = physicalFootprint() else { fatalError("Memory sampling unavailable") }
        let sampler = Task.detached { () -> UInt64 in
            var peak = baseline
            while !Task.isCancelled {
                peak = max(peak, physicalFootprint() ?? 0)
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            return peak
        }
        defer { sampler.cancel() }
        try await models.install(from: source)
        _ = try await models.validatedModelURL()
        let endingFootprint = physicalFootprint() ?? 0
        sampler.cancel()
        let peak = max(await sampler.value, endingFootprint)
        let growth = peak > baseline ? peak - baseline : 0
        precondition(growth < 64 * 1_048_576,
                     "256 MiB import and revalidation grew memory by \(growth / 1_048_576) MiB; read buffers may be accumulating")
        print("PASS: 256 MiB import + revalidation, sampled memory growth \(growth / 1_048_576) MiB (host regression limit: 64 MiB)")
    }

    @MainActor
    static func wait(_ predicate: @MainActor () async -> Bool) async throws {
        for _ in 0..<5_000 {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        fatalError("Timed out waiting for controller state")
    }
}

actor ControlledClassifier: ClassifierDriver {
    private var continuation: CheckedContinuation<ClassifierMeasurement, Never>?
    private var progress: (@Sendable (ClassifierProgress) async -> Void)?
    private var previousProgress: (@Sendable (ClassifierProgress) async -> Void)?
    private var id: UUID?
    var runCount = 0
    var stopCount = 0

    func run(id: UUID, progress: @escaping @Sendable (ClassifierProgress) async -> Void) async -> ClassifierMeasurement {
        self.id = id
        previousProgress = self.progress
        self.progress = progress
        await progress(.stage("controlled classifier invocation"))
        return await withCheckedContinuation {
            continuation = $0
            runCount += 1
        }
    }

    func stop(id: UUID, reason: String) { if self.id == id { stopCount += 1 } }
    func emit(_ event: ClassifierProgress) async { await progress?(event) }
    func emitPrevious(_ event: ClassifierProgress) async { await previousProgress?(event) }
    func finish(measurement: ClassifierMeasurement? = nil) {
        var value = measurement ?? ClassifierMeasurement(id: id!)
        if measurement == nil { value.outcome = "passed" } // Deliberately late success; controller must override it.
        value.endedAt = Date()
        continuation?.resume(returning: value)
        continuation = nil
        id = nil
    }
}

actor ControlledCamera: CameraDriver {
    private var continuation: CheckedContinuation<CameraMeasurement, Error>?
    private var progress: (@Sendable (CameraProgress) async -> Void)?
    private var previousProgress: (@Sendable (CameraProgress) async -> Void)?
    private var id: UUID?
    var captureCount = 0
    var stopCount = 0
    var configuration: CameraConfiguration?
    private var encodedFeatures: FeatureEncoder.Encoded?
    private var automaticGlosses: [ClassifierCandidate] = []
    var mode: CaptureMode? { configuration?.mode }

    func setFeatures(_ features: FeatureEncoder.Encoded) { encodedFeatures = features }
    func setAutomaticGlosses(_ glosses: [ClassifierCandidate]) { automaticGlosses = glosses }

    func captureClip(id: UUID, configuration: CameraConfiguration,
                     progress: @escaping @Sendable (CameraProgress) async -> Void) async throws -> CapturedCameraClip {
        defer { encodedFeatures = nil; automaticGlosses = [] }
        let value = try await capture(id: id, configuration: configuration, progress: progress)
        return CapturedCameraClip(measurement: value, features: encodedFeatures, automaticGlosses: automaticGlosses)
    }

    func capture(id: UUID, configuration: CameraConfiguration,
                 progress: @escaping @Sendable (CameraProgress) async -> Void) async throws -> CameraMeasurement {
        self.id = id
        self.configuration = configuration
        previousProgress = self.progress
        self.progress = progress
        await progress(.stage("requesting camera permission"))
        return try await withCheckedThrowingContinuation {
            continuation = $0
            captureCount += 1
        }
    }

    func stop(id: UUID, reason: String) async {
        guard self.id == id else { return }
        stopCount += 1 // Keep native capture pending to test the completion barrier.
    }

    func emit(_ event: CameraProgress) async { await progress?(event) }
    func emitPrevious(_ event: CameraProgress) async { await previousProgress?(event) }

    func finish(reason: String, measurement: CameraMeasurement? = nil) {
        var value = measurement ?? configuration!.measurement(id: id!)
        value.captureMode = configuration?.mode
        value.handTestScene = configuration?.handTestScene
        value.outcome = reason
        value.endedAt = Date()
        continuation?.resume(returning: value)
        continuation = nil
        id = nil
    }

    func fail() {
        continuation?.resume(throwing: AppError.invalidState)
        continuation = nil
        id = nil
    }
}

@MainActor
final class ControlledSpeech: SpeechDriver {
    var requests: [(id: UUID, text: String)] = []
    var stopCount = 0
    var failStart = false
    var holdStop = false
    private var activeID: UUID?
    private var callbacks: [UUID: @MainActor (SpeechEvent) -> Void] = [:]

    func speak(id: UUID, text: String, progress: @escaping @MainActor (SpeechEvent) -> Void) throws -> SpeechVoice {
        if failStart { throw AppError.invalidState }
        precondition(activeID == nil)
        activeID = id
        callbacks[id] = progress
        requests.append((id, text))
        progress(.started)
        return SpeechVoice(identifier: "owned-test-voice", language: "en-US")
    }

    func stop() {
        stopCount += 1
        if holdStop { return }
        guard let id = activeID else { return }
        activeID = nil
        callbacks[id]?(.cancelled)
    }

    func emit(id: UUID, event: SpeechEvent) {
        if activeID == id {
            switch event {
            case .finished, .cancelled: activeID = nil
            case .started: break
            }
        }
        callbacks[id]?(event)
    }
}

actor ControlledRunner: SentenceGenerator {
    private var continuation: CheckedContinuation<GenerationMeasurement, Never>?
    private var cancellationContinuation: CheckedContinuation<Void, Never>?
    private var unloadContinuation: CheckedContinuation<Void, Never>?
    private var holdUnload = false
    var unloadPending: Bool { unloadContinuation != nil }
    private var progress: (@Sendable (String) async -> Void)?
    private var activePromptID = ""
    private let holdCancellation: Bool
    var started = false
    var cancellationObserved = false
    var generationCount = 0
    var cancellationCount = 0
    var loadCount = 0
    var unloadCount = 0
    var lastGlosses = ""
    var lastGPU = false
    var lastContextTokens = 0
    var lastProfiling = false
    var lastPromptStyle: SentencePromptStyle = .reference

    init(holdCancellation: Bool = false) { self.holdCancellation = holdCancellation }

    func load(model: URL, gpu: Bool, cache: URL, contextTokens: Int, profiling: Bool) async throws -> Double {
        loadCount += 1
        lastGPU = gpu
        lastContextTokens = contextTokens
        lastProfiling = profiling
        return 0.001
    }

    func generate(id: UUID, promptID: String, glosses: String, promptStyle: SentencePromptStyle,
                  progress: @escaping @Sendable (String) async -> Void) async throws -> GenerationMeasurement {
        self.progress = progress
        lastPromptStyle = promptStyle
        lastGlosses = glosses
        activePromptID = promptID
        await progress("creating conversation")
        started = true
        generationCount += 1
        return await withCheckedContinuation { continuation = $0 }
    }

    func cancel(id: UUID, reason: String) async throws {
        cancellationObserved = true
        cancellationCount += 1
        if holdCancellation { await withCheckedContinuation { cancellationContinuation = $0 } }
    }

    func finishCancellation() {
        cancellationContinuation?.resume()
        cancellationContinuation = nil
    }

    func emitProgress(_ stage: String) async { await progress?(stage) }

    func finish(outcome: String = "user cancellation requested", response: String = "", measurement: GenerationMeasurement? = nil) {
        continuation?.resume(returning: measurement ?? GenerationMeasurement(
            backend: "CPU", promptID: activePromptID, elapsedSeconds: 0.01, firstTextSeconds: nil,
            streamChunks: 0, conversationTokens: nil, outcome: outcome, response: response, nativeError: nil
        ))
        continuation = nil
    }

    func setHoldUnload(_ hold: Bool) { holdUnload = hold }

    func finishUnload() {
        holdUnload = false
        unloadContinuation?.resume()
        unloadContinuation = nil
    }

    func unload() async throws {
        unloadCount += 1
        if holdUnload { await withCheckedContinuation { unloadContinuation = $0 } }
    }
}

@MainActor
final class ControlledModelDownloader: ModelDownloading {
    var onEvent: (@MainActor @Sendable (ModelDownloadEvent) -> Void)?
    var recovery = ModelDownloadRecovery.none
    var starts = 0
    var cancelled: [Int] = []
    func restore() async -> ModelDownloadRecovery { recovery }
    func start() throws -> Int { starts += 1; return starts }
    func cancel(taskID: Int) { cancelled.append(taskID) }
    func emit(_ event: ModelDownloadEvent) { onEvent?(event) }
}
