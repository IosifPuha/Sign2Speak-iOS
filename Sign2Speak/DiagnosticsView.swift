import Combine
import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
struct DiagnosticsView: View {
    @ObservedObject var controller: ConversationController
    @State private var importing = false
    @State private var editingTokenID: UUID?
    @State private var tokenDraft = ""
    @State private var showingTokenEditor = false
    @State private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var reportToShare: ReportSnapshot?

    var body: some View {
        NavigationStack {
            Form {
                Section("App diagnostics") {
                    Text("Model, camera and performance diagnostics for Sign2Speak.")
                    Text(controller.phase).accessibilityIdentifier("diagnosticsPhase")
                    if controller.speaking {
                        Button("Stop speaking", role: .destructive) { controller.stopSpeech() }
                            .disabled(controller.speechStopping)
                    }
                    if controller.restartRequired {
                        Text("Share the report, then stop the app in Xcode and run it again. The installed model is kept.")
                            .foregroundStyle(.red)
                    }
                    Text("Sampled process peak: \(Double(controller.report.peakPhysicalFootprintBytes) / 1_048_576, specifier: "%.1f") MiB")
                    Text("Memory warnings received: \(controller.report.memoryWarningCount ?? 0)")
                    if let error = controller.checkpointError { Text(error).foregroundStyle(.red) }
                }
                if let previous = controller.previousReport {
                    Section("Previous launch") {
                        Text(controller.previousUnfinished ? "Unfinished operation; cause unknown. Inspect the report and device termination logs." : "A previous report is available.")
                        ShareLink("Share previous report", item: previous)
                    }
                }
                Section("1. Import native Gemma 4 E2B") {
                    Text("Import copies and verifies the pinned 2.59 GB model. Keep enough space for both the original and installed copy.")
                    if !controller.hasModel {
                        Button("Download sentence model") { controller.downloadModel() }
                            .disabled(controller.nativeWorkBlocked)
                    }
                    Button(controller.hasModel ? "Replace model from Files" : "Import model from Files") { importing = true }
                        .disabled(controller.nativeWorkBlocked || controller.engineLoaded)
                }
                Section("2. Load engine") {
                    Picker("Sentence prompt", selection: $controller.diagnosticPromptStyle) {
                        Text("Full reference · baseline").tag(SentencePromptStyle.reference)
                        Text("Compact · trial").tag(SentencePromptStyle.compact)
                    }.disabled(controller.nativeWorkBlocked || controller.engineLoaded)
                    .onChange(of: controller.diagnosticPromptStyle) { _, style in
                        if style == .reference && controller.diagnosticContextTokens == SentenceGenerationPolicy.compactTrialContextTokens {
                            controller.diagnosticContextTokens = SentenceGenerationPolicy.contextTokens
                        }
                    }
                    Picker("Backend", selection: $controller.backend) {
                        Text("CPU").tag("CPU")
                        Text("GPU / Metal").tag("GPU")
                    }.disabled(controller.nativeWorkBlocked || controller.engineLoaded)
                    Picker("Context budget", selection: $controller.diagnosticContextTokens) {
                        if controller.diagnosticPromptStyle == .compact {
                            Text("512 · compact prompt only").tag(SentenceGenerationPolicy.compactTrialContextTokens)
                        }
                        Text("768 · lower memory trial").tag(SentenceGenerationPolicy.contextTokens)
                        Text("1,024 · baseline").tag(SentenceGenerationPolicy.extendedContextTokens)
                    }.disabled(controller.nativeWorkBlocked || controller.engineLoaded)
                    if controller.diagnosticPromptStyle == .compact {
                        Text("Diagnostic trial only. Normal signing uses the full reference prompt. Compare at 768 first, then try 512 if sentence meaning is preserved.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("\(SentenceGenerationPolicy.maxOutputTokens) output tokens · thinking off. Load cannot be cancelled through this runtime API.")
                    Toggle("Native performance counters", isOn: $controller.diagnosticNativeProfiling)
                        .disabled(controller.nativeWorkBlocked || controller.engineLoaded)
                    Text("Optional experimental counters for prompt processing and answer generation. Enable before Load; results appear in the JSON report. Profiling may affect timing.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Load") { controller.load() }
                        .disabled(controller.nativeWorkBlocked || controller.engineLoaded || !controller.hasModel)
                    Button("Unload") { controller.unload() }
                        .disabled(controller.nativeWorkBlocked || !controller.engineLoaded)
                }
                Section("3. Generate from fixed glosses") {
                    Picker("Input", selection: $controller.promptIndex) {
                        ForEach(ConversationController.prompts.indices, id: \.self) { index in
                            Text(ConversationController.prompts[index]).tag(index)
                        }
                    }.disabled(controller.nativeWorkBlocked)
                    Button("Generate") { controller.generate() }.disabled(controller.nativeWorkBlocked || !controller.engineLoaded)
                    Button("Cancel generation", role: .destructive) { controller.cancel() }
                        .disabled(!controller.generating || controller.stopping)
                    Text(controller.response.isEmpty ? "No output yet." : controller.response).textSelection(.enabled)
                    Text("Full-response diagnostic mode. At 30 seconds the watchdog requests cancellation; after 10 more seconds without completion, restart the app. Cancellation is best effort: controls stay locked until native work returns.")
                }
                Section("4. Camera capture") {
                    if lowPowerMode {
                        Text("Low Power Mode is on. Turn it off in Settings → Battery for baseline camera comparisons.")
                            .foregroundStyle(.orange)
                    }
                    Text(controller.captureMode == .continuousSigning
                         ? "Continuous signing: \(Int(ContinuousSigningPolicy.noHandsTimeoutSeconds)) seconds without hands finishes automatically and starts sentence generation and speech. One minute/eight-sign limit."
                         : controller.captureMode == .signCandidates
                         ? "Unload Gemma, then record one complete sign. Capture stops after three seconds or 64 delivered frames."
                         : "Unload Gemma before starting. Camera tests stop after ten seconds or 300 delivered frames.")
                    Picker("Capture mode", selection: $controller.captureMode) {
                        Text("Camera only").tag(CaptureMode.cameraOnly)
                        Text("Hands + face").tag(CaptureMode.handAndFace)
                        Text("Sign candidates").tag(CaptureMode.signCandidates)
                        Text("Continuous").tag(CaptureMode.continuousSigning)
                    }
                    .pickerStyle(.segmented)
                    .disabled(controller.nativeWorkBlocked || controller.engineLoaded)
                    .accessibilityIdentifier("captureMode")
                    .onChange(of: controller.captureMode) { _, mode in
                        if mode == .signCandidates || mode == .continuousSigning { controller.cameraFramesPerSecond = 20 }
                    }
                    Picker("Requested capture rate", selection: $controller.cameraFramesPerSecond) {
                        Text("20 fps").tag(20)
                        Text("30 fps").tag(30)
                    }
                    .pickerStyle(.segmented)
                    .disabled(controller.nativeWorkBlocked || controller.engineLoaded || controller.captureMode == .signCandidates || controller.captureMode == .continuousSigning)
                    .accessibilityIdentifier("captureRate")
                    if controller.engineLoaded {
                        Text("Unload Gemma in section 2 to enable camera test settings.")
                    } else if controller.busy {
                        Text("Finish or stop the current operation before changing camera test settings.")
                    }
                    if controller.captureMode == .continuousSigning {
                        Text("Start begins a fresh utterance, just as in Conversation. Stable predictions accumulate without selection. Remove both hands for \(Int(ContinuousSigningPolicy.noHandsTimeoutSeconds)) seconds to finish; Stop cancels. Recognition and cadence remain unvalidated.")
                    } else if controller.captureMode == .signCandidates {
                        Text("Record one ASL sign once, keeping your face and signing hands visible. Tap Finish sign when complete, or capture ends after three seconds. Keep the phone still. Results need your confirmation.")
                        Text("This mode uses 20 fps and at most 64 frames. Cadence and recognition quality are still being evaluated. Model scores are not accuracy estimates.")
                    } else if controller.captureMode == .handAndFace {
                        Picker("Hand test scene", selection: $controller.handTestScene) {
                            ForEach(HandTestScene.allCases) { scene in Text(scene.title).tag(scene) }
                        }
                        .pickerStyle(.inline)
                        .disabled(controller.nativeWorkBlocked || controller.engineLoaded)
                        .accessibilityIdentifier("handTestScene")
                        Text("For left/right tests, select the hand you will show and keep only that anatomical hand visible. Labels describe your test scene; they do not change detector output.")
                        Text("Keep the whole hand in view for all ten seconds. Candidate slots use raw labels scoring at least 0.80; this provisional cutoff does not change MediaPipe detection. Duplicate labels are rejected. Stationary calibration passed; moving-hand identity and recognition quality still need evaluation.")
                    } else {
                        Text("Camera only measures frame delivery. Choose Hands + face above to enable landmark detection and hand-scene choices.")
                    }
                    if controller.cameraActive, let camera = controller.cameraDriver as? CameraCapture,
                       let captureID = controller.report.activeCameraID {
                        CameraPreview(camera: camera, captureID: captureID)
                            .id(captureID)
                            .frame(height: 260)
                            .accessibilityLabel("Mirrored front-camera preview")
                    }
                    Button(controller.captureMode == .continuousSigning ? "Start signing" : (controller.captureMode == .signCandidates ? "Record one sign" : (controller.captureMode == .handAndFace ? "Start hand/face test" : "Start camera-only test"))) {
                        if controller.captureMode == .continuousSigning { controller.startSigning() }
                        else { controller.startCamera() }
                    }
                        .disabled(controller.nativeWorkBlocked || controller.engineLoaded)
                        .accessibilityIdentifier("startCamera")
                    if controller.captureMode == .signCandidates {
                        Button("Finish sign") { controller.finishSignCapture() }
                            .disabled(!controller.cameraActive || controller.cameraStopping || controller.finishingSignCapture)
                            .accessibilityIdentifier("finishSign")
                    }
                    Button(controller.captureMode == .signCandidates ? "Cancel capture / inference" : "Stop camera", role: .destructive) {
                        if controller.cameraActive { controller.stopCamera() }
                        else { controller.stopClassifier() }
                    }
                        .disabled((!controller.cameraActive || controller.cameraStopping) && (!controller.classifierActive || controller.classifierStopping))
                        .accessibilityIdentifier("stopCamera")
                    if let measurement = controller.cameraMeasurement {
                        if let continuous = measurement.continuous {
                            Text("Continuous: \(continuous.inferenceCount) inferences · \(continuous.committedGlossCount) glosses · \(continuous.rejectedWindows) rejected windows")
                            Text("No hands: \(continuous.latestNoHandsSeconds, specifier: "%.1f") / \(continuous.noHandsTimeoutSeconds, specifier: "%.1f") s")
                        }
                        Text("\(measurement.frames) frames · \(measurement.droppedFrames) dropped · \(measurement.width) × \(measurement.height)")
                        if let rate = measurement.deliveredFramesPerSecond {
                            Text("Delivered frames/s: \(rate, specifier: "%.1f")")
                        }
                        Text("Invalid/non-increasing timestamps: \(measurement.invalidTimestampCount)")
                        if let brightness = measurement.frameBrightness, let latest = brightness.latest {
                            Text("Frame brightness: \(latest.mean, specifier: "%.1f")/255 · near-black samples: \(brightness.nearBlackFrames)/\(brightness.sampledFrames)")
                            if brightness.sampledFrames >= 3, brightness.nearBlackFrames == brightness.sampledFrames {
                                Text("Incoming camera frames appear nearly black. Check front-camera visibility and lighting; this result does not establish the cause.")
                                    .foregroundStyle(.orange)
                            }
                        }
                        if let fps = measurement.configuredFramesPerSecond {
                            Text("Requested / configured rate: \(measurement.requestedFramesPerSecond) / \(fps, specifier: "%.1f") fps")
                        }
                        if let rotation = measurement.captureRotationDegrees {
                            Text("Capture rotation: \(rotation, specifier: "%.1f")° · geometry changes: \(measurement.geometryChangeCount ?? 0)")
                        }
                        if let preview = measurement.latestPreviewGeometry {
                            Text("Preview angle: \(preview.rotationDegrees, specifier: "%.1f")° · \(preview.widthPoints, specifier: "%.0f") × \(preview.heightPoints, specifier: "%.0f") points · mirrored: \(preview.mirrored ? "yes" : "no")")
                        }
                        if let duration = measurement.captureElapsedSeconds, let teardown = measurement.teardownSeconds {
                            Text("Capture / release time: \(duration, specifier: "%.3f") / \(teardown, specifier: "%.3f") s")
                        }
                        if let landmarks = measurement.landmarks {
                            Text("Processed: \(landmarks.processedFrames) · timestamp skips: \(landmarks.skippedTimestampFrames) · errors: \(landmarks.errorCount)")
                            Text("Latest: \(landmarks.latestHandPointCounts.count) hands · \(landmarks.latestFacePointCount > 0 ? 1 : 0) face")
                            Text("Hand point counts: \(landmarks.latestHandPointCounts.map(String.init).joined(separator: ", ")) · face points: \(landmarks.latestFacePointCount)")
                            Text("Raw handedness: \(landmarks.latestRawHandedness.isEmpty ? "none" : landmarks.latestRawHandedness.joined(separator: ", "))")
                            if let scores = landmarks.latestRawHandednessScores {
                                Text("Raw label scores: \(scores.map { String(format: "%.2f", $0) }.joined(separator: ", "))")
                            }
                            if let identity = landmarks.handIdentity {
                                Text("Provisional slots: left \(identity.latestResolution.leftSourceIndex == nil ? "missing/rejected" : "present") · right \(identity.latestResolution.rightSourceIndex == nil ? "missing/rejected" : "present")")
                                Text("Candidate frames: left \(identity.counts.framesWithLeftCandidate) · right \(identity.counts.framesWithRightCandidate) · both \(identity.counts.framesWithBothCandidates)")
                                Text("Frames with rejected labels: \(identity.counts.framesWithRejectedHands) · low-score hands: \(identity.counts.lowScoreHandCount)")
                                if !identity.latestResolution.rejectionReasons.isEmpty {
                                    Text(identity.latestResolution.rejectionReasons.joined(separator: "; "))
                                }
                            }
                            if let rate = landmarks.processedFramesPerSecond {
                                Text("Processed frames/s: \(rate, specifier: "%.1f")")
                            }
                            if let clip = landmarks.clip {
                                Text("Raw clip: \(clip.bufferedFrames)/\(clip.capacity) frames · \(clip.spanSeconds, specifier: "%.2f") s · resets: \(clip.resetCount)")
                            }
                            if let encoding = landmarks.featureEncoding {
                                Text("Features: \(encoding.status)")
                                if let count = encoding.validFrames, let bytes = encoding.tensorBytes {
                                    Text("\(count) valid frames · \(bytes) tensor bytes · \(encoding.elapsedSeconds * 1_000, specifier: "%.1f") ms")
                                }
                            }
                            if let mean = landmarks.meanProcessingSeconds {
                                Text("Mean / max detection: \(mean * 1_000, specifier: "%.1f") / \(landmarks.maximumProcessingSeconds * 1_000, specifier: "%.1f") ms")
                            }
                            if let error = landmarks.lastError { Text(error).foregroundStyle(.red) }
                        }
                        if measurement.outcome != "pending" { Text(measurement.outcome) }
                        if let reason = measurement.candidateRejection { Text(reason).foregroundStyle(.orange) }
                    }
                    if let prediction = controller.classifierMeasurement?.cameraPrediction {
                        Text(prediction.status)
                        ForEach(prediction.candidates, id: \.index) { candidate in
                            Text("\(candidate.label) · model score \(candidate.score, specifier: "%.3f")")
                        }
                        if let seconds = prediction.invokeSeconds {
                            Text("Classifier invocation: \(seconds * 1_000, specifier: "%.1f") ms")
                        }
                        if let error = controller.classifierMeasurement?.error { Text(error).foregroundStyle(.red) }
                    }
                    if let prediction = controller.pendingPrediction {
                        Text("Choose the sign you intended. Nothing is added automatically.")
                        ForEach(prediction.candidates, id: \.index) { candidate in
                            Button("Add \(candidate.label)") {
                                controller.confirmCandidate(captureID: prediction.captureID, index: candidate.index)
                            }
                            .disabled(controller.confirmedTokens.count >= ConversationController.tokenLimit)
                            .accessibilityIdentifier("confirmCandidate_\(candidate.index)")
                        }
                        Button("None of these — discard result") {
                            controller.dismissCandidates(captureID: prediction.captureID)
                        }
                    }
                    Link("Camera settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                    Text("The preview is mirrored; captured frames are unmirrored. Late frames are discarded. Stop, backgrounding, or a memory warning releases the camera before another operation can start.")
                    Text("Sign candidates mode classifies a completed clip after releasing the camera. Up to 64 frames of landmarks and one temporary feature tensor are held in memory. Images, coordinates, and tensors are not saved or exported. Hand slots and sign candidates remain provisional.")
                }
                Section("Confirmed signs") {
                    Text("\(controller.confirmedTokens.count)/\(ConversationController.tokenLimit) signs · kept only until the app closes. Confirmed text is not included in diagnostic reports.")
                    if controller.confirmedTokens.isEmpty {
                        Text("Record a sign and choose a candidate to begin.")
                    }
                    ForEach(controller.confirmedTokens) { token in
                        VStack(alignment: .leading) {
                            Text(token.text).font(.headline)
                            HStack {
                                Button("Edit") {
                                    editingTokenID = token.id
                                    tokenDraft = token.text
                                    showingTokenEditor = true
                                }
                                Button("Repeat") { controller.repeatToken(id: token.id) }
                                    .disabled(controller.confirmedTokens.count >= ConversationController.tokenLimit)
                                Button("Remove", role: .destructive) { controller.removeToken(id: token.id) }
                            }
                            .buttonStyle(.borderless)
                            .disabled(controller.nativeWorkBlocked)
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel("Confirmed sign: \(token.text)")
                        }
                    }
                    Button("Clear sign session", role: .destructive) { controller.clearSignSession() }
                        .disabled(controller.nativeWorkBlocked || (controller.confirmedTokens.isEmpty && controller.pendingPrediction == nil))
                        .accessibilityIdentifier("clearSignSession")
                    Text("Edits express your intended sign. Use Conversation to generate and speak a sentence.")
                }
                Section("5. Classifier runtime test") {
                    Text("Unload Gemma first. This checks a bundled arithmetic model on CPU; it does not recognize signs. One run checks four known inputs twice, releases the interpreter, and repeats with a fresh interpreter.")
                    Button("Run classifier runtime test") { controller.runClassifier() }
                        .disabled(controller.nativeWorkBlocked || controller.engineLoaded)
                        .accessibilityIdentifier("runClassifier")
                    Button("Run trained ASL model runtime test") { controller.runClassifier(trained: true) }
                        .disabled(controller.nativeWorkBlocked || controller.engineLoaded)
                        .accessibilityIdentifier("runTrainedClassifier")
                    Text("The trained-model test uses synthetic inputs to check loading and inference. Its candidates are not recognized signs, and its scores are not calibrated accuracy.")
                    Button("Stop classifier test", role: .destructive) { controller.stopClassifier() }
                        .disabled(!controller.classifierActive || controller.classifierStopping)
                    if let value = controller.classifierMeasurement, value.cameraPrediction == nil {
                        if let trained = value.trainedValidation {
                            Text("Result: \(value.outcome)")
                            Text("Synthetic invocations: \(trained.cases.count)/\(trained.plannedInvocations)")
                            ForEach(Array(trained.cases.enumerated()), id: \.offset) { _, item in
                                Text("Pass \(item.pass) · \(item.recipe) · repeat \(item.repetition): \(item.invokeSeconds * 1_000, specifier: "%.2f") ms")
                                    .font(.caption.monospaced())
                            }
                        } else {
                            Text("Result: \(value.outcome) · \(value.cases.filter(\.passed).count)/\(value.plannedCases) comparisons passed")
                        }
                        Text("Interpreter loads: \(value.loadSeconds.count) · releases: \(value.completedReleases)")
                        if let version = value.nativeRuntimeVersion { Text("Native TensorFlow Lite: \(version)") }
                        ForEach(Array(value.cases.enumerated()), id: \.offset) { _, item in
                            Text("Pass \(item.pass) · \(item.recipe) · repeat \(item.repetition): \(item.passed ? "PASS" : "FAIL") · \(item.invokeSeconds * 1_000, specifier: "%.2f") ms")
                                .font(.caption.monospaced())
                        }
                        if let error = value.error { Text(error).foregroundStyle(.red) }
                    }
                    Text("Stop, backgrounding, and memory warnings stop further comparisons. An active native call must return before resources are released. A stalled call keeps controls locked and triggers a restart message.")
                }
                Section("6. Evidence") {
                    // Serialize only on demand, not on every 5 Hz report update.
                    Button("Share current JSON report") {
                        reportToShare = ReportSnapshot(text: controller.reportText)
                    }
                    ForEach(Array(controller.report.events.enumerated()), id: \.offset) { _, event in
                        Text(event).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Diagnostics")
            .sheet(item: $reportToShare) { snapshot in
                ReportShareSheet(text: snapshot.text)
            }
            .sheet(isPresented: $showingTokenEditor) {
                NavigationStack {
                    Form {
                        TextField("Intended sign", text: $tokenDraft)
                            .accessibilityIdentifier("tokenEditor")
                        Text("Enter 1–64 characters. This changes your confirmed text, not the model prediction.")
                    }
                    .navigationTitle("Edit sign")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showingTokenEditor = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                if let id = editingTokenID, controller.editToken(id: id, text: tokenDraft) {
                                    showingTokenEditor = false
                                }
                            }
                            .disabled(controller.nativeWorkBlocked || ConversationController.normalizedToken(tokenDraft) == nil)
                        }
                    }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
                Task { @MainActor in
                    switch result {
                    case .success(let url): controller.importModel(url)
                    case .failure(let error): controller.record("File selection failed: \(error)")
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
                .receive(on: DispatchQueue.main)) { _ in
                lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        }
    }
}

private struct ReportSnapshot: Identifiable {
    let id = UUID()
    let text: String
}

private struct ReportShareSheet: UIViewControllerRepresentable {
    let text: String
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
