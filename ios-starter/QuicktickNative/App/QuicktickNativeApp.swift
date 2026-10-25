import SwiftUI

@main
struct QuicktickNativeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = AppStore()

    init() {
        // Work around ggml-metal's unstable tensor/fused kernels on newer
        // iPhones before the optional Anima Metal backend is initialized.
        setenv("GGML_METAL_TENSOR_DISABLE", "1", 1)
        setenv("GGML_METAL_FUSION_DISABLE", "1", 1)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .task { await store.bootstrap() }
                .onOpenURL { url in Task { await store.previewRecommendationImport(url) } }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    store.handleMemoryPressure()
                }
                .onChange(of: scenePhase) { _, phase in store.isForeground = phase == .active; if phase == .active { Task { await store.syncWhenActive() } } }
        }
    }
}
