import SwiftUI

@main
struct QuicktickNativeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(maxWidth: ProcessInfo.processInfo.arguments.contains("--compact-ui-testing") ? 320 : .infinity)
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .task { await store.bootstrap() }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    store.handleMemoryPressure()
                }
                .onChange(of: scenePhase) { _, phase in store.isForeground = phase == .active; if phase == .active { Task { await store.syncWhenActive() } } }
        }
    }
}
