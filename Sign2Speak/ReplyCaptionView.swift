import SwiftUI

@MainActor
struct ReplyCaptionView: View {
    @ObservedObject var session: ConversationController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var status: String {
        switch session.replyState {
        case .idle: return session.replyText.isEmpty ? "Ready to listen" : "Spoken reply"
        case .preparing: return "Getting ready…"
        case .listening: return "Listening…"
        case .finishing: return "Finishing…"
        }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: session.replyState == .listening ? "mic.fill" : "text.bubble")
                    Text(status).font(.headline)
                    if session.replyState == .preparing || session.replyState == .finishing { ProgressView() }
                }
                .accessibilityIdentifier("replyCaptionStatus")
                ScrollViewReader { scroll in
                    ScrollView {
                        Text(session.replyText.isEmpty ? "Hearing person speaks in English. Their words will appear here." : session.replyText)
                            .font(.title2).foregroundStyle(session.replyText.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id("captionText")
                            .accessibilityIdentifier("replyTranscript")
                    }
                    .onChange(of: session.replyText) { _, _ in
                        if session.replyActive { scroll.scrollTo("captionText", anchor: .bottom) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let error = session.replyError {
                    Text(error.message).font(.subheadline).foregroundStyle(.orange)
                        .accessibilityIdentifier("replyCaptionError")
                    if error.opensSettings {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    }
                }
                Text("English captions stay on this iPhone. Listen for up to one minute at a time.")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack {
                    if session.replyActive {
                        Button {
                            if session.replyState == .listening { session.finishReplyTranscription() }
                            else { session.cancelReplyTranscription() }
                        } label: {
                            Label(session.replyState == .listening ? "Stop listening" : "Cancel", systemImage: "stop.fill")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(session.replyState == .finishing)
                        .accessibilityIdentifier("stopReplyTranscription")
                    } else {
                        Button { session.startReplyTranscription() } label: {
                            Label("Listen", systemImage: "mic.fill").frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(session.nativeWorkBlocked || session.restartRequired)
                        .accessibilityIdentifier("startReplyTranscription")
                    }
                    Button("Clear") { session.clearReply() }
                        .buttonStyle(.bordered)
                        .disabled(session.replyActive || (session.replyText.isEmpty && session.replyError == nil))
                        .accessibilityIdentifier("clearReplyTranscript")
                }
            }
            .padding()
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("Read their words")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { session.cancelReplyTranscription(); dismiss() }
                }
            }
        }
        .tint(.teal)
        .onDisappear { session.cancelReplyTranscription() }
    }
}
