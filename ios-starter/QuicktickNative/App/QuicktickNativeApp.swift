import SwiftUI

@main
struct QuicktickNativeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(maxWidth: ProcessInfo.processInfo.arguments.contains("--compact-ui-testing") ? 320 : .infinity)
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .task { await store.bootstrap() }
        }
    }
}
