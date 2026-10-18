import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @FocusState private var syncFieldFocused: Bool
    @State private var syncID = ""
    @State private var status = ""
    @State private var user = ""
    @State private var key = ""
    @State private var session = ""
    @State private var username = ""
    @State private var remember = true
    @State private var exclusions = ""
    @State private var onboarding = false
    @State private var sharedProfile: RecommendationTransfer?
    @State private var importingProfile = false
    @State private var preparingProfile = false
    var body: some View {
        Form {
            if let storageWarning = store.storageWarning { Section("Storage needs attention") { Text(storageWarning).foregroundStyle(.orange) } }
            Section("Optional website Sync") {
                Toggle("Enable website Sync", isOn: Binding(get: { store.cloudSyncEnabled }, set: { enabled in
                    Task { do { try await store.setCloudSyncEnabled(enabled) } catch { status = error.localizedDescription } }
                })).accessibilityIdentifier("cloud-sync-toggle")
                Text("Off by default. When enabled, encrypted Favorites, provider access and preferences are sent to your QuickTick website. Feeds and recommendations always run independently.").font(.footnote).foregroundStyle(.secondary)
                HStack {
                    Button("Copy my Sync ID") { UIPasteboard.general.string = store.syncID; status = "Sync ID copied." }
                        .disabled(!store.cloudSyncEnabled || store.syncID.isEmpty)
                    Spacer()
                    Button("Sync now") { Task { do { try await store.syncNow(); await reloadAccessFields() } catch {} } }.disabled(!store.cloudSyncEnabled || store.isSyncing)
                }.buttonStyle(.plain)
                SecureField("Paste Sync ID from another device", text: $syncID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                    .accessibilityIdentifier("sync-id-input").focused($syncFieldFocused).submitLabel(.done)
                HStack {
                    Button("Paste ID") { syncID = UIPasteboard.general.string ?? "" }
                    Spacer()
                    Button("Connect and merge") { syncFieldFocused = false; Task {
                        do { try await store.connectSyncID(syncID); status = ""; await reloadAccessFields(); await store.refresh() }
                        catch { status = error.localizedDescription }
                    } }.disabled(!store.cloudSyncEnabled || store.isSyncing || syncID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.buttonStyle(.plain)
                if store.isSyncing { ProgressView("Syncing profile…") }
                Text(status.isEmpty ? store.syncStatus : status).accessibilityIdentifier("sync-status").font(.footnote).foregroundStyle(store.syncFailed ? .orange : .secondary)
                Text("Your Sync ID is the key to your profile. Downloads stay on this device.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Provider access") {
                TextField("Rule34 user ID", text: $user).textInputAutocapitalization(.never)
                    .accessibilityIdentifier("rule34-user-input").accessibilityLabel("Rule34 user ID")
                SecureField("Rule34 API key", text: $key)
                    .accessibilityIdentifier("rule34-key-input").accessibilityLabel("Rule34 API key")
                Toggle("Remember Rule34 credentials", isOn: $remember)
                TextField("Pornhub username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("pornhub-user-input").accessibilityLabel("Pornhub username")
                SecureField("Supported Pornhub session", text: $session)
                    .accessibilityIdentifier("pornhub-session-input").accessibilityLabel("Supported Pornhub session")
                Button("Save access settings") { Task { await store.saveCredentials(user: user, key: key, session: session, remember: remember, username: username); await store.refresh() } }
            }.disabled(store.isSyncing)
            Section("Learned interests · \(store.selectedProvider.displayName)") {
                LabeledContent("Engine", value: store.recommendationMode)
                Text(store.learnedInterests.isEmpty ? "Interact with posts or search to learn interests." : store.learnedInterests.joined(separator: " · "))
                Button("Edit Into / Not Into") { onboarding = true }
                Button("Reset learned history", role: .destructive) { Task { await store.resetRecommendations() } }
                if let resetStatus = store.resetStatus { Text(resetStatus).font(.caption) }
            }
            Section("Move recommendations to another device") {
                Button { preparingProfile = true; Task {
                    defer { preparingProfile = false }
                    do { sharedProfile = try await store.exportRecommendationProfile() }
                    catch { store.profileTransferError = error.localizedDescription }
                } } label: { Label(preparingProfile ? "Preparing profile…" : "Share / AirDrop profile", systemImage: "square.and.arrow.up") }
                    .disabled(preparingProfile).accessibilityIdentifier("share-recommendation-profile")
                Button("Import recommendation profile") { importingProfile = true }.accessibilityIdentifier("import-recommendation-profile")
                Text("Transfers your chosen and learned interests, exclusions and semantic interests. No logins, Sync ID, downloaded files or individual viewing/search history. The file contains private interests; share it only with your chosen device.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Persistent exclusions") {
                TextField("Tags separated by spaces", text: $exclusions).textInputAutocapitalization(.never)
                Button("Save exclusions") { store.setExclusions(exclusions.split(whereSeparator: \.isWhitespace).map(String.init)); Task { await store.refresh() } }
            }
            Section("Playback") {
                Toggle("Immersion framing (fill)", isOn: $store.immersionFraming)
                Toggle("Mute", isOn: $store.muted)
            }
        }.scrollContentBackground(.hidden).background(AppTheme.canvas).navigationTitle("Settings")
            .sheet(isPresented: $onboarding) { TasteOnboardingView() }
            .sheet(item: $sharedProfile) { profile in
                NavigationStack {
                    VStack(spacing: 20) {
                        Image(systemName: "airplayaudio").font(.largeTitle)
                        Text("Your QuickTick interests").font(.title2.bold())
                        Text("Choose AirDrop in the share sheet. Open the received file in QuickTick on your other iPhone or iPad, then confirm the import.").foregroundStyle(.secondary)
                        ShareLink(item: profile, preview: SharePreview("QuickTick recommendation profile")) { Label("Choose device or save file", systemImage: "square.and.arrow.up") }
                            .buttonStyle(.borderedProminent).accessibilityIdentifier("airdrop-profile-share-link")
                    }.padding(24).navigationTitle("Share profile")
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { sharedProfile = nil } } }
                }.presentationDetents([.medium, .large])
            }
            .fileImporter(isPresented: $importingProfile, allowedContentTypes: [.quicktickProfile, .json]) { result in
                switch result {
                case .success(let url): Task { await store.previewRecommendationImport(url) }
                case .failure(let error): store.profileTransferError = error.localizedDescription
                }
            }
            .modifier(ProfileImportConfirmation())
            .task { await reloadAccessFields() }
            .onChange(of: store.isSyncing) { _, busy in if !busy { Task { await reloadAccessFields() } } }
    }
    private func reloadAccessFields() async {
        exclusions = store.exclusions.joined(separator: " ")
        let credentials = await store.api.credentials
        user = credentials.rule34User; key = credentials.rule34Key; session = credentials.pornhubSession
        username = store.syncedPornhubUsername; remember = store.rememberedProviderAccess
    }
}

struct ProfileImportConfirmation: ViewModifier {
    @EnvironmentObject private var store: AppStore
    var enabled = true
    func body(content: Content) -> some View {
        content.alert("Import recommendation profile?", isPresented: Binding(get: { enabled && store.pendingProfileImport != nil }, set: { shown in if enabled && !shown { store.pendingProfileImport = nil } })) {
            if let profile = store.pendingProfileImport {
                Button("Replace interests", role: .destructive) { Task { await store.importRecommendationProfile(profile) } }
            }
            Button("Cancel", role: .cancel) { store.pendingProfileImport = nil }
        } message: { Text("Replaces chosen and learned interests and exclusions on this device. Favorites, downloads, logins and website Sync settings stay as they are.") }
        .alert("Profile transfer", isPresented: Binding(get: { enabled && store.profileTransferError != nil }, set: { if enabled && !$0 { store.profileTransferError = nil } })) {
            Button("OK", role: .cancel) { store.profileTransferError = nil }
        } message: { Text(store.profileTransferError ?? "") }
    }
}
