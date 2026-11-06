import SwiftUI
import UIKit

@main
struct Sign2SpeakApp: App {
    @UIApplicationDelegateAdaptor(DownloadAppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup { AppRootView(runner: GemmaRunner()) }
    }
}

@MainActor
final class DownloadAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundModelDownloader.sessionIdentifier else { completionHandler(); return }
        ModelDownloadBackgroundEvents.register(completionHandler)
    }
}
