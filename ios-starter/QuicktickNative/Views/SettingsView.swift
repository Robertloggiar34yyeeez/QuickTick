import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var syncID = ""
    @State private var status = "Sync IDs are sensitive."
    @State private var user = ""
    @State private var key = ""
    @State private var session = ""
    @State private var remember = true
    @State private var exclusions = ""
    @State private var onboarding = false
    var body: some View {
        Form {
            if let storageWarning = store.storageWarning { Section("Storage needs attention") { Text(storageWarning).foregroundStyle(.orange) } }
            Section("Quicktick Sync") {
                SecureField("QT6-…", text: $syncID).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Connect / Merge / Push") { Task {
                    do { try await store.connectSyncID(syncID); try await store.syncNow(); status = "Cloud profile merged and saved." }
                    catch { status = error.localizedDescription }
                } }
                Text(status).font(.caption)
            }
            Section("Provider access") {
                TextField("Rule34 user ID", text: $user).textInputAutocapitalization(.never)
                SecureField("Rule34 API key", text: $key)
                Toggle("Remember Rule34 credentials", isOn: $remember)
                SecureField("Supported Pornhub session", text: $session)
                Button("Save access settings") { Task { await store.saveCredentials(user: user, key: key, session: session, remember: remember); await store.refresh() } }
            }
            Section("Learned interests · \(store.selectedProvider.displayName)") {
                LabeledContent("Engine", value: store.recommendationMode)
                Text(store.learnedInterests.isEmpty ? "Interact with posts or search to learn interests." : store.learnedInterests.joined(separator: " · "))
                Button("Edit Into / Not Into") { onboarding = true }
                Button("Reset learned history", role: .destructive) { Task { await store.resetRecommendations() } }
                if let resetStatus = store.resetStatus { Text(resetStatus).font(.caption) }
            }
            Section("Persistent exclusions") {
                TextField("Tags separated by spaces", text: $exclusions).textInputAutocapitalization(.never)
                Button("Save exclusions") { store.setExclusions(exclusions.split(whereSeparator: \.isWhitespace).map(String.init)); Task { await store.refresh() } }
            }
            Section("Playback") {
                Toggle("Immersion framing (fill)", isOn: $store.immersionFraming)
                Toggle("Mute", isOn: $store.muted)
            }
        }.navigationTitle("Settings")
            .sheet(isPresented: $onboarding) { TasteOnboardingView() }
            .task {
                syncID = store.syncID; exclusions = store.exclusions.joined(separator: " ")
                user = KeychainStore.get(account: "rule34-user") ?? ""
                key = KeychainStore.get(account: "rule34-key") ?? ""
                session = KeychainStore.get(account: "pornhub-session") ?? ""
            }
    }
}
