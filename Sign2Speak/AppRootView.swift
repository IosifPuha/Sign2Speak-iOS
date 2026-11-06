import Combine
import AVFoundation
import SwiftUI
import UIKit

@MainActor
struct AppRootView: View {
    @StateObject private var session: ConversationController
    @Environment(\.scenePhase) private var scenePhase

    init(runner: any SentenceGenerator) {
        let controller = ConversationController(runner: runner, camera: CameraCapture(), classifier: ClassifierRunner(),
            speech: LocalSpeechDriver(), reply: LocalReplyRecognitionDriver(),
            trainedClassifier: TrainedClassifierRunner(), cameraClassifierFactory: { id, features in
                CameraClassifierRunner(captureID: id, features: features)
            })
        controller.backend = "GPU"
        _session = StateObject(wrappedValue: controller)
    }

    var body: some View {
        Group {
            if session.hasModel { ConversationView(session: session) }
            else { NavigationStack { ModelSetupView(session: session) } }
        }
        .task { await session.monitor() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { session.interrupt(reason: "App backgrounded") }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .receive(on: DispatchQueue.main)) { _ in session.memoryWarningReceived() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: DispatchQueue.main)) { notification in
            if let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
               type == AVAudioSession.InterruptionType.began.rawValue {
                session.interrupt(reason: "Audio interrupted")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: DispatchQueue.main)) { _ in
            session.record("Thermal state: \(ProcessInfo.processInfo.thermalState.rawValue)")
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)) { notification in
            if let value = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
               AVAudioSession.RouteChangeReason(rawValue: value) == .oldDeviceUnavailable {
                session.cancelReplyTranscription()
            }
        }
    }
}

