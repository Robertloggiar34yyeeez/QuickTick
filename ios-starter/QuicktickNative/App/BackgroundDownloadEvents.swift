import UIKit
import AVFAudio

@MainActor
enum BackgroundDownloadEvents {
    static var handlers: [String: () -> Void] = [:]
    static func complete(_ identifier: String) { handlers.removeValue(forKey: identifier)?() }
}

@MainActor final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { print("Playback audio session unavailable:", error.localizedDescription) }
        return true
    }
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        BackgroundDownloadEvents.handlers[identifier] = completionHandler
    }
}
