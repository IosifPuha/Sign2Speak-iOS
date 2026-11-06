import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ModelSetupView: View {
    @ObservedObject var session: ConversationController
    @State private var importing = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image("BrandMark").resizable().renderingMode(.original)
                    .scaledToFit().frame(width: 96, height: 96).accessibilityHidden(true)
                    .accessibilityHidden(true)
                Text("Sign2Speak").font(.largeTitle.bold())
                Text(session.hasModel ? "Your sentence model is ready." : "One download. Conversations on your iPhone.")
                    .font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                Text("Gemma turns your signs into English sentences. Download the 2.59 GB model once; translation then works without an internet connection.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                if session.hasModel {
                    Label("Installed on this iPhone", systemImage: "checkmark.circle.fill").foregroundStyle(.teal)
                } else {
                    downloadControls
                    Text("Wi-Fi recommended. Mobile data may be used. You can leave the app while it downloads; we'll check the file before it is ready.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                DisclosureGroup("Advanced setup") {
                    Button(session.hasModel ? "Replace from Files" : "Import an existing model from Files") { importing = true }
                        .disabled(session.nativeWorkBlocked || session.engineLoaded)
                        .padding(.top, 12)
                }.font(.footnote)
            }
            .frame(maxWidth: 480).padding(28).frame(maxWidth: .infinity)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { session.importModel(url) }
        }
    }

    @ViewBuilder
    private var downloadControls: some View {
        switch session.modelDownloadState {
        case .checking:
            ProgressView("Checking model setup…")
        case .verifying:
            ProgressView("Checking and installing download…")
        case .downloading(let bytes):
            VStack(spacing: 12) {
                ProgressView(value: Double(bytes), total: Double(session.report.model.bytes))
                Text("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: session.report.model.bytes, countStyle: .file))")
                    .font(.subheadline).monospacedDigit()
                Text("\(Int(100 * Double(bytes) / Double(session.report.model.bytes)))%")
                    .font(.caption).monospacedDigit()
                Button("Cancel download", role: .cancel) { session.cancelModelDownload() }
            }
        case .idle, .failed:
            if case .failed(let message) = session.modelDownloadState {
                Text(message).foregroundStyle(.red).font(.subheadline)
            }
            Button {
                session.downloadModel()
            } label: {
                Label(session.modelDownloadState == .idle ? "Download" : "Retry download", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.borderedProminent).tint(.teal)
                .disabled(session.busy || session.speaking)
                .accessibilityIdentifier("downloadSentenceModel")
        }
    }
}
