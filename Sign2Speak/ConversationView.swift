import SwiftUI

// The signing surface stays visible; editing and setup live in separate sheets.
@MainActor
struct ConversationView: View {
    @ObservedObject var session: ConversationController
    @State private var showingReview = false
    @State private var showingSetup = false
    @State private var showingRecognitionInfo = false
    @State private var showingDiagnostics = false
    @State private var showingReply = false
    @State private var showFullCameraFrame = false
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase

    private var keepsDisplayAwake: Bool {
        let conversationVisible = !showingSetup && !showingRecognitionInfo && !showingDiagnostics
        let activityRunning = session.busy || session.speaking || session.replyActive
        return scenePhase == .active && (conversationVisible || activityRunning)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GeometryReader { geometry in
                    cameraStage
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
                .ignoresSafeArea()
                GeometryReader { geometry in
                    VStack(spacing: 12) {
                        header
                        if !session.cameraActive {
                            VStack(spacing: 0) {
                                activitySummary
                                Spacer(minLength: 12)
                                bottomPanel(compact: geometry.size.height < 520 || textSize.isAccessibilitySize)
                            }
                            .frame(maxWidth: 520, maxHeight: .infinity)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 12)
                            .padding(.bottom, 8)
                        } else if geometry.size.width > geometry.size.height {
                            Spacer(minLength: 0)
                            HStack {
                                Spacer(minLength: 0)
                                bottomPanel(compact: true)
                                    .frame(width: min(420, geometry.size.width * 0.55))
                            }
                        } else {
                            Spacer(minLength: 0)
                            bottomPanel(compact: geometry.size.height < 520 || textSize.isAccessibilitySize)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
            .background(Color(uiColor: .systemBackground))
            .toolbar(.hidden, for: .navigationBar)
            .tint(.teal)
            .sheet(isPresented: $showingReview) { ConversationReviewView(session: session) }
            .sheet(isPresented: $showingSetup) { setup }
            .sheet(isPresented: $showingRecognitionInfo) { recognitionInfo }
            .sheet(isPresented: $showingReply, onDismiss: { session.cancelReplyTranscription() }) {
                ReplyCaptionView(session: session)
            }
            .sheet(isPresented: $showingDiagnostics) {
                DiagnosticsView(controller: session)
                    .safeAreaInset(edge: .top) {
                        HStack {
                            Spacer()
                            Button("Done") { showingDiagnostics = false }.padding(12)
                        }.background(Color(uiColor: .systemBackground))
                    }
            }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = keepsDisplayAwake }
        .onChange(of: keepsDisplayAwake) { _, value in
            UIApplication.shared.isIdleTimerDisabled = value
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Sign2Speak").font(.headline)
                status
            }
            Spacer(minLength: 0)
            finishProgress
            Menu {
                Toggle("Show full camera frame", isOn: $showFullCameraFrame)
                Button("Review & correct", systemImage: "pencil") { showingReview = true }
                    .disabled(session.busy)
                Button("About recognition", systemImage: "info.circle") { showingRecognitionInfo = true }
                Button("Sentence model", systemImage: "internaldrive") { showingSetup = true }
                    .disabled(session.nativeWorkBlocked)
                Button("Diagnostics", systemImage: "wrench.and.screwdriver") { showingDiagnostics = true }
                Button("Clear conversation", systemImage: "trash", role: .destructive) { session.clearSignSession() }
                    .disabled(session.busy)
            } label: {
                Image(systemName: "ellipsis.circle").font(.title2)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
                    .accessibilityLabel("Conversation options")
            }
        }
        .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 4)
        .foregroundStyle(.primary)
        .background(Color(uiColor: .systemBackground)
            .opacity(reduceTransparency ? 1 : colorScheme == .light ? 0.85 : 0.4),
                    in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var finishProgress: some View {
        if session.cameraActive, let live = session.liveRecognition, !live.handsVisible, live.hasSeenHands {
            let progress = min(1, max(0, live.noHandsSeconds / ContinuousSigningPolicy.noHandsTimeoutSeconds))
            ZStack {
                Circle().stroke(.primary.opacity(0.25), lineWidth: 3)
                Circle().trim(from: 0, to: progress)
                    .stroke(.primary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 24, height: 24).padding(8)
            .animation(reduceMotion ? nil : .linear(duration: 0.2), value: progress)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Finishing utterance")
            .accessibilityValue(Text("\(max(0, ContinuousSigningPolicy.noHandsTimeoutSeconds - live.noHandsSeconds), specifier: "%.1f") seconds remaining"))
            .accessibilityIdentifier("utteranceFinishProgress")
        }
    }

    private func bottomPanel(compact: Bool) -> some View {
        VStack(spacing: compact ? 6 : 10) {
            if session.cameraActive, !(session.liveRecognition.map { !$0.handsVisible && $0.hasSeenHands } ?? false) {
                recognitionOverlay
            }
            signs
            if session.sentenceAvailable || session.generating { sentence(compact: compact) }
            noticeView(compact: compact)
            controls
            if !session.cameraActive && !session.busy {
                Button {
                    showingReply = true
                    if session.replyText.isEmpty { session.startReplyTranscription() }
                } label: {
                    Label(session.replyText.isEmpty ? "Let the hearing person speak" : "Read spoken reply", systemImage: "mic")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
                .disabled(session.restartRequired || session.replyActive || session.modelDownloadState.isActive)
                .accessibilityIdentifier("spokenReply")
            }
        }
        .padding(12)
        .foregroundStyle(.primary)
        .background(Color(uiColor: .systemBackground)
            .opacity(reduceTransparency ? 1 : colorScheme == .light ? 0.85 : 0.28),
                    in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(.primary.opacity(0.15), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var status: some View {
        HStack(spacing: 8) {
            Circle().fill(session.speaking ? Color.teal : session.cameraActive ? .green : .secondary)
                .frame(width: 8, height: 8)
            Text(statusText).font(.subheadline.weight(.semibold))
                .lineLimit(1).minimumScaleFactor(0.75)
                .accessibilityIdentifier("conversationStatus")
        }
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        if session.restartRequired { return "Restart needed" }
        if session.replyActive { return session.replyState == .listening ? "Listening to a reply" : "Preparing captions…" }
        if session.speaking { return session.speechStopping ? "Stopping audio…" : "Speaking" }
        if session.generating { return session.stopping ? "Stopping…" : "Making your sentence…" }
        if session.cameraActive {
            if session.cameraStopping || session.finishingSignCapture { return "Finishing capture…" }
            return "Ready for your signs"
        }
        if session.busy { return "Getting ready…" }
        return session.sentenceAvailable ? "Your sentence" : "Ready when you are"
    }

    private var cameraStage: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            if session.cameraActive, let camera = session.cameraDriver as? CameraCapture,
               let id = session.report.activeCameraID {
                CameraPreview(camera: camera, captureID: id, fillsView: !showFullCameraFrame)
                    .id(id)
                    .accessibilityLabel("Mirrored front camera")
            }
        }
        .accessibilityIdentifier("signingCamera")
    }

    private var activitySummary: some View {
        VStack(spacing: 8) {
            Group {
                if session.speaking {
                    Image(systemName: "waveform").font(.system(size: 24, weight: .light))
                } else if session.generating {
                    Image(systemName: "text.bubble").font(.system(size: 24, weight: .light))
                } else {
                    Image("BrandMark").resizable().renderingMode(.original)
                        .scaledToFit().frame(width: 64, height: 64)
                }
            }.accessibilityHidden(true)
            Text(session.speaking ? "Speaking for you" : session.generating ? "Turning signs into a sentence" : "A conversation starts with your hands")
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if !session.nativeWorkBlocked && !session.sentenceAvailable {
                Text("Keep your face and hands in view.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if session.busy { ProgressView().tint(.primary) }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .accessibilityIdentifier("conversationActivitySummary")
    }

    private var recognitionOverlay: some View {
        VStack(alignment: .leading, spacing: 5) {
            let live = session.liveRecognition
            if let live, live.handsVisible, let candidate = live.candidates.first {
                HStack(alignment: .firstTextBaseline) {
                    Text(candidate.label.capitalized)
                        .font(.title2.weight(.bold)).lineLimit(1).minimumScaleFactor(0.6)
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("Score").font(.caption2).foregroundStyle(.secondary)
                        Text(candidate.score, format: .percent.precision(.fractionLength(0)))
                            .font(.title3.monospacedDigit().weight(.semibold))
                    }
                        .accessibilityLabel("Model score \(Int(candidate.score * 100)) percent")
                }
                .accessibilityIdentifier("liveSignPrediction")
                Text(predictionStatus(live.status)).font(.caption.weight(.medium))
                if live.status == .lowScore || live.status == .ambiguous {
                    Text(live.candidates.dropFirst().map {
                        "\($0.label.capitalized) \(Int($0.score * 100))%"
                    }.joined(separator: "   ·   "))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text(live?.handsVisible == true ? "Reading your sign…" : "Bring your hands into view")
                    .font(.headline)
                Text("Hands out of view for \(Int(ContinuousSigningPolicy.noHandsTimeoutSeconds)) seconds finishes automatically.").font(.caption)
            }
        }
        .foregroundStyle(.primary).padding(.horizontal, 2).padding(.vertical, 4)
    }

    private func predictionStatus(_ status: RecognitionFeedbackStatus) -> String {
        switch status {
        case .added, .alreadyAdded: return "Added to your signs"
        case .stabilizing: return "Checking this sign… · Not added yet"
        case .lowScore: return "Unsure · Not added yet"
        case .ambiguous: return "Between possible signs · Not added yet"
        case .collecting: return "Reading your sign…"
        case .noHands: return "Hands out of view"
        }
    }

    private var signs: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("YOUR SIGNS").font(.caption2.weight(.bold)).tracking(1)
                Spacer()
                Text("\(session.confirmedTokens.count)/8").font(.caption2.monospacedDigit())
            }.foregroundStyle(.secondary)
            ScrollViewReader { scroll in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if session.confirmedTokens.isEmpty {
                            Text("Signs appear here as you sign.").foregroundStyle(.secondary)
                        }
                        ForEach(session.confirmedTokens) { token in
                            Text(token.text.capitalized).fontWeight(.semibold)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Color.teal.opacity(0.12), in: Capsule())
                                .id(token.id)
                        }
                    }.font(.subheadline).frame(minHeight: 36)
                }
                .onChange(of: session.confirmedTokens.count) { _, _ in
                    if let id = session.confirmedTokens.last?.id { scroll.scrollTo(id, anchor: .trailing) }
                }
            }
        }
        .accessibilityIdentifier("recognizedSigns")
    }

    private func sentence(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("SENTENCE").font(.caption2.weight(.bold)).tracking(1).foregroundStyle(.secondary)
                Spacer()
                if session.sentenceAvailable {
                    Button { session.speakSentence() } label: {
                        Image(systemName: "speaker.wave.2.fill").frame(minWidth: 44, minHeight: 28)
                    }
                    .disabled(session.nativeWorkBlocked || session.restartRequired || session.engineLoaded)
                    .accessibilityLabel("Replay sentence").accessibilityIdentifier("replaySentence")
                }
            }
            if session.sentenceAvailable {
                // Long utterances can be read here without moving the camera or controls.
                ScrollView { Text(session.sentenceDraft).font(compact ? .headline : .title3)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    .frame(height: compact ? 44 : 70)
                    .accessibilityIdentifier("sentenceDraft")
            } else {
                Text(session.generating ? "Finding the words for your signs…" : "Your spoken sentence will appear here.")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if session.nativeWorkBlocked {
                if session.cameraActive && !session.confirmedTokens.isEmpty {
                    Button("Finish now", systemImage: "checkmark") { session.finishUtterance() }
                        .buttonStyle(.bordered).disabled(session.cameraStopping || session.finishingSignCapture || !session.hasModel)
                        .accessibilityIdentifier("finishUtterance")
                }
                Button(role: .destructive) { session.stopConversation() } label: {
                    Label(session.speaking ? "Stop audio" : "Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.speechStopping || session.cameraStopping || session.stopping
                    || (!session.replyActive && !session.speaking && !session.generating && !session.cameraActive && !session.classifierActive))
                .accessibilityIdentifier("conversationStop")
            } else if !session.hasModel {
                Button("Set up sentence model", systemImage: "arrow.down.circle") { showingSetup = true }
                    .frame(maxWidth: .infinity, minHeight: 44).buttonStyle(.borderedProminent)
            } else {
                Button { session.startSigning() } label: {
                    Label(session.sentenceAvailable ? "Sign another sentence" : "Start signing", systemImage: "camera.fill")
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.borderedProminent).disabled(session.restartRequired)
                .accessibilityIdentifier("conversationRecord")
                if !session.confirmedTokens.isEmpty && !session.sentenceAvailable {
                    Button("Make sentence") { session.generateSentence() }.buttonStyle(.bordered)
                        .disabled(session.restartRequired).accessibilityIdentifier("finishUtterance")
                }
            }
        }
        .controlSize(.large)
    }

    private var notice: String? {
        if session.restartRequired { return "Restart the app. Your diagnostic report is in Diagnostics." }
        if let error = session.sentenceError { return error }
        if let error = session.speechError { return error }
        if session.phase.hasPrefix("Failed:") { return session.phase }
        return nil
    }

    @ViewBuilder
    private func noticeView(compact: Bool) -> some View {
        if let notice {
            Text(notice).font(.caption).foregroundStyle(.orange)
                .lineLimit(compact ? 2 : 3).accessibilityIdentifier("conversationNotice")
        }
    }

    private var setup: some View {
        NavigationStack {
            ModelSetupView(session: session)
            .navigationTitle("Sentence model").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingSetup = false } } }
        }.presentationDetents([.medium, .large])
    }

    private var recognitionInfo: some View {
        NavigationStack {
            Form {
                Text("The percentage is the model's score for its current guess, not a measured chance of being correct. A guess appears before it is added. Only stable predictions that pass the acceptance rules join your signs.")
                Text("Continuous recognition is still being improved. Missed or incorrect signs change the sentence; check the signs or use Review & correct when needed.")
                Text("Keep both hands out of view for \(Int(ContinuousSigningPolicy.noHandsTimeoutSeconds)) seconds to finish. A brief return of either hand cancels the countdown. Each recording supports up to eight signs and one minute.")
                Text("Signs, scores, corrections and sentences stay in memory. Conversation text is excluded from diagnostic reports.")
                Text("The full-screen preview crops the image edges to fill the display. Choose Show full camera frame in the options menu to see the entire image. Recognition always uses the full captured frame.")
            }
            .navigationTitle("About recognition").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingRecognitionInfo = false } } }
        }.presentationDetents([.medium, .large])
    }
}

@MainActor
private struct ConversationReviewView: View {
    @ObservedObject var session: ConversationController
    @Environment(\.dismiss) private var dismiss
    @State private var editingTokenID: UUID?
    @State private var correction = ""
    @State private var editing = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Your signs") {
                    if session.confirmedTokens.isEmpty { Text("No signs added yet.").foregroundStyle(.secondary) }
                    ForEach(session.confirmedTokens) { token in
                        HStack {
                            Text(token.text.capitalized)
                            Spacer()
                            Text(token.originalCandidate.score, format: .percent.precision(.fractionLength(0)))
                                .font(.caption).foregroundStyle(.secondary).accessibilityLabel("Original prediction score")
                            Menu {
                                Button("Correct") { editingTokenID = token.id; correction = token.text; editing = true }
                                Button("Repeat") { session.repeatToken(id: token.id) }
                                    .disabled(session.confirmedTokens.count >= 8)
                                Button("Remove", role: .destructive) { session.removeToken(id: token.id) }
                            } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
                            .accessibilityLabel("Actions for \(token.text)").disabled(session.busy)
                        }
                    }
                    Button("Make sentence from these signs") { dismiss(); session.generateSentence() }
                        .disabled(session.nativeWorkBlocked || session.restartRequired || !session.hasModel || session.confirmedTokens.isEmpty)
                }
                if session.sentenceAvailable {
                    Section("Edit sentence") {
                        TextEditor(text: Binding(get: { session.sentenceDraft }, set: { session.editSentence($0) }))
                            .frame(minHeight: 110).disabled(session.busy).accessibilityLabel("Editable sentence")
                        Text("Editing stops playback. Replay speaks your edited text.").font(.caption).foregroundStyle(.secondary)
                        Button("Replay sentence") { session.speakSentence() }
                            .disabled(session.nativeWorkBlocked || session.restartRequired || session.engineLoaded)
                    }
                }
                Section { Button("Clear conversation", role: .destructive) { session.clearSignSession(); dismiss() }.disabled(session.busy) }
            }
            .navigationTitle("Review & correct").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Correct sign", isPresented: $editing) {
                TextField("Intended sign", text: $correction)
                Button("Save") { if let id = editingTokenID { session.editToken(id: id, text: correction) } }
                    .disabled(session.busy || ConversationController.normalizedToken(correction) == nil)
                Button("Cancel", role: .cancel) {}
            } message: { Text("Enter up to 64 characters.") }
        }
    }
}
