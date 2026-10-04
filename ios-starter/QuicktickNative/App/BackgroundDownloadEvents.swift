import UIKit

@MainActor
enum BackgroundDownloadEvents {
    static var handlers: [String: () -> Void] = [:]
    static func complete(_ identifier: String) { handlers.removeValue(forKey: identifier)?() }
}

@MainActor final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        BackgroundDownloadEvents.handlers[identifier] = completionHandler
    }
}
