import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("quicktick-show-ai-tab-v1") private var showAITab = true
    @AppStorage("quicktick-modern-ui-v1") private var modernUI = true
    @AppStorage("quicktick-accent-palette-v1") private var accentPalette = "violet"
    @AppStorage("quicktick-skip-video-intros-v1") private var skipVideoIntros = false
    @FocusState private var syncFieldFocused: Bool
    @State private var syncID = ""
    @State private var status = ""
    @State private var user = ""
    @State private var key = ""
    @State private var session = ""
    @State private var username = ""
    @State private var remember = true
    @State private var onboarding = false
    @State private var sharedProfile: RecommendationTransfer?
    @State private var importingProfile = false
    @State private var preparingProfile = false
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: 15))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Make QuickTick yours")
                            .font(.system(.title3, design: .rounded).weight(.bold))
                        Text("Preferences, privacy and visual recommendations")
                            .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
                    }
                }
                .padding(.top, 12)
            if let storageWarning = store.storageWarning { SettingsGroup(title: "Storage needs attention", icon: "exclamationmark.triangle") { Text(storageWarning).foregroundStyle(.orange) } }
            SettingsGroup(title: "Navigation", icon: "square.grid.2x2") {
                Toggle("Show AI tab", isOn: $showAITab)
                    .accessibilityIdentifier("show-ai-tab-toggle")
                Text(showAITab ? "Five tabs" : "Four tabs · Turn this on to open Create again")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            SettingsGroup(title: "Appearance", icon: "paintbrush.pointed") {
                Toggle("Modern interface", isOn: $modernUI)
                    .accessibilityIdentifier("modern-ui-toggle")
                Text(modernUI ? "Rounded surfaces, compact chips and animated navigation." : "Previous QuickTick interface restored.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Accent gradient").font(.subheadline.weight(.semibold))
                HStack(spacing: 7) {
                    ForEach(AppTheme.AccentPalette.allCases) { palette in
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) { accentPalette = palette.rawValue }
                        } label: {
                            VStack(spacing: 6) {
                                Circle().fill(LinearGradient(colors: [palette.primary, palette.secondary],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 35, height: 35)
                                    .overlay(Circle().stroke(.white.opacity(accentPalette == palette.rawValue ? 0.9 : 0.18), lineWidth: 2))
                                    .overlay {
                                        if accentPalette == palette.rawValue {
                                            Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                                        }
                                    }
                                Text(palette.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(QuicktickPressStyle())
                        .accessibilityIdentifier("accent-\(palette.rawValue)")
                    }
                }
            }
            SettingsGroup(title: "Website Sync", icon: "arrow.triangle.2.circlepath") {
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
            SettingsGroup(title: "Provider access", icon: "lock.shield") {
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
            SettingsGroup(title: "Learned interests · \(store.selectedProvider.displayName)", icon: "sparkles") {
                LabeledContent("Engine", value: store.recommendationMode)
                Text(store.learnedInterests.isEmpty ? "Interact with posts or search to learn interests." : store.learnedInterests.joined(separator: " · "))
                Button("Edit Into / Not Into") { onboarding = true }
                Button {
                    Task { await store.rebuildRecommended() }
                } label: {
                    Label("Rescan Recommended", systemImage: "arrow.triangle.2.circlepath")
                }
                .accessibilityIdentifier("rescan-recommended")
                Text("Ranking upgrades automatically rebuild the discovery queue. Rescan now to start fresh without losing favorites, dislikes, blocked tags or viewing history.")
                    .font(.footnote).foregroundStyle(AppTheme.secondaryLabel)
                if let status = store.recommendationRescanStatus { Text(status).font(.caption).foregroundStyle(AppTheme.accent) }
                Button("Reset learned history", role: .destructive) { Task { await store.resetRecommendations() } }
                if let resetStatus = store.resetStatus { Text(resetStatus).font(.caption) }
            }
            SettingsGroup(title: "Transfer recommendations", icon: "square.and.arrow.up") {
                Button { preparingProfile = true; Task {
                    defer { preparingProfile = false }
                    do { sharedProfile = try await store.exportRecommendationProfile() }
                    catch { store.profileTransferError = error.localizedDescription }
                } } label: { Label(preparingProfile ? "Preparing profile…" : "Share / AirDrop profile", systemImage: "square.and.arrow.up") }
                    .disabled(preparingProfile || !store.bootstrapped).accessibilityIdentifier("share-recommendation-profile")
                Button("Import recommendation profile") { importingProfile = true }.accessibilityIdentifier("import-recommendation-profile")
                Text("Transfers your chosen and learned interests, exclusions and semantic interests. No logins, Sync ID, downloaded files or individual viewing/search history. The file contains private interests; share it only with your chosen device.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            SettingsGroup(title: "Persistent exclusions", icon: "line.3.horizontal.decrease.circle") {
                PersistentExclusionEditor()
            }
            SettingsGroup(title: "Visual intelligence", icon: "eye") {
                Toggle("Learn visual taste while browsing", isOn: $store.visualAnalysisEnabled)
                Text("Separate anime and real-life tastes. Reuses previews and gradually checks small favorite thumbnails on Wi-Fi. Pauses while scrolling, loading or playing media, and in Low Power Mode.").font(.footnote).foregroundStyle(.secondary)
                ManualVisualRefreshPanel(manager: store.downloads)
            }
            SettingsGroup(title: "Playback", icon: "play.rectangle") {
                Toggle("Immersion framing (fill)", isOn: $store.immersionFraming)
                Toggle("Mute", isOn: $store.muted)
                Toggle("Skip Pornhub intros (10 seconds)", isOn: $skipVideoIntros)
                    .accessibilityIdentifier("skip-video-intros-toggle")
                Text("Pornhub videos longer than 12 seconds start at 0:10. All other sources start at 0:00.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 30)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(AppTheme.canvas)
        .navigationTitle("Settings")
        .toolbarBackground(AppTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .preferredColorScheme(.dark)
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
            .onDisappear { store.cancelManualVisualRefresh() }
            .onChange(of: store.isSyncing) { _, busy in if !busy { Task { await reloadAccessFields() } } }
    }
    private func reloadAccessFields() async {
        let credentials = await store.api.credentials
        user = credentials.rule34User; key = credentials.rule34Key; session = credentials.pornhubSession
        username = store.syncedPornhubUsername; remember = store.rememberedProviderAccess
    }
}

/// The same removable orange capsules used for excluded search tags, except
/// every edit persists immediately across sources and app upgrades.
private struct PersistentExclusionEditor: View {
    @EnvironmentObject private var store: AppStore
    @State private var draft = ""
    @State private var suggestions: [TagSuggestion] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keep unwanted tags out of every feed. Tap × to allow a tag again.")
                .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                ForEach(store.exclusions, id: \.self) { tag in
                    HStack(spacing: 6) {
                        Image(systemName: "nosign").font(.caption.weight(.semibold))
                        Text(tag.replacingOccurrences(of: "_", with: " "))
                            .font(.caption).lineLimit(1)
                        Spacer(minLength: 0)
                        Button { update(store.exclusions.filter { $0 != tag }) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 19, weight: .medium))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(QuicktickPressStyle())
                        .accessibilityLabel("Remove blocked tag \(tag)")
                    }
                    .foregroundStyle(.orange)
                    .padding(.leading, 12)
                    .padding(.trailing, 4)
                    .frame(minHeight: 42)
                    .background(.orange.opacity(0.14), in: Capsule())
                    .overlay(Capsule().stroke(.orange.opacity(0.5)))
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(AppTheme.secondaryLabel)
                TextField("Block a tag or phrase", text: $draft)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.done).onSubmit(addDraft)
                    .accessibilityIdentifier("persistent-block-tag-input")
                Button(action: addDraft) {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 40, height: 40)
                        .background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(QuicktickPressStyle())
                .accessibilityLabel("Block tags")
                .accessibilityIdentifier("persistent-block-tag-add")
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(7)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(AppTheme.border))
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(suggestions.prefix(8)) { suggestion in
                            Button(suggestion.value) { update(store.exclusions + [suggestion.value]); draft = "" }
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 12).frame(minHeight: 36)
                                .background(AppTheme.accent.opacity(0.13), in: Capsule())
                                .overlay(Capsule().stroke(AppTheme.accent.opacity(0.3)))
                        }
                    }
                }
            }
        }
        .task(id: "\(store.selectedProvider.rawValue):\(draft)") {
            suggestions = []
            guard store.selectedProvider == .rule34,
                  let last = draft.split(whereSeparator: \.isWhitespace).last, last.count >= 2 else { return }
            do {
                try await Task.sleep(for: .milliseconds(260))
                let results = try await store.api.suggestions(provider: .rule34, query: String(last))
                if !Task.isCancelled { suggestions = results }
            } catch { suggestions = [] }
        }
    }

    private func addDraft() {
        // A phrase such as "looking at viewer" represents one booru tag.
        // Commas permit deliberately entering several separate tags at once.
        update(store.exclusions + draft.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) })
        draft = ""; suggestions = []
    }

    private func update(_ tags: [String]) {
        let normalized = Array(Set(tags.map(RecommendationTagRules.canonical)
            .filter { !$0.isEmpty && $0.count <= 80 })).sorted().prefix(128)
        store.setExclusions(Array(normalized))
        Task { await store.refresh(immersive: store.activeTab == 1) }
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.88))
                .padding(.leading, 3)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .font(.subheadline)
            .textFieldStyle(.roundedBorder)
            .buttonStyle(.bordered)
            .tint(AppTheme.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
        }
    }
}

private struct ManualVisualRefreshPanel: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var manager: DownloadManager
    @State private var previewURL: URL?
    @State private var previewReady = false
    var body: some View {
        Group {
            Button { store.startManualVisualRefresh() } label: {
                Label("Update visual taste now", systemImage: "sparkles")
            }.disabled(store.isManualVisualScanRunning).accessibilityIdentifier("force-visual-refresh")
            Text("Checks every favorite, reuses valid scans and updates recommendations. Playback pauses during this manual update. Unavailable previews can be retried later.")
                .font(.caption).foregroundStyle(.secondary)
            if let progress = store.manualVisualProgress {
                ProgressView(value: progress.fraction) {
                    Text(progress.status).accessibilityIdentifier("manual-visual-status")
                }.accessibilityIdentifier("manual-visual-progress")
                    .accessibilityValue("\(progress.completed) of \(progress.total) new posts analyzed")
                if let previewURL {
                    AnimatedGIFSurface(url: previewURL,
                        playing: store.isForeground && !reduceMotion && !ProcessInfo.processInfo.isLowPowerModeEnabled && ProcessInfo.processInfo.thermalState.rawValue < 2,
                        pixels: 160, frameLimit: 24) { _ in previewReady = true }
                        .frame(maxWidth: .infinity).frame(height: 160).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)).allowsHitTesting(false)
                        .accessibilityElement(children: .ignore)
                        .accessibilityValue(previewReady ? "Looping" : "Loading")
                        .accessibilityLabel("Looping downloaded GIF").accessibilityIdentifier("visual-refresh-gif")
                } else {
                    Label("Download a GIF to show a looping preview here", systemImage: "photo")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if progress.running {
                    Button("Stop update", role: .cancel) { store.cancelManualVisualRefresh() }
                        .accessibilityIdentifier("cancel-visual-refresh")
                }
            }
        }.task(id: manager.records.count) {
            // Local downloads only; never fetch or decode a video for decoration.
            let record = manager.records.first { record in
                record.state == .complete && (record.mediaType?.lowercased() == "gif" || URL(fileURLWithPath: record.localMediaPath ?? "").pathExtension.lowercased() == "gif")
                    && (record.fileSize ?? 0) <= 8 * 1024 * 1024
            }
            previewReady = false; previewURL = record?.exportURL
        }
    }
}

struct ProfileImportConfirmation: ViewModifier {
    @EnvironmentObject private var store: AppStore
    var enabled = true
    func body(content: Content) -> some View {
        content.alert("Import recommendation profile?", isPresented: Binding(get: { enabled && store.bootstrapped && store.pendingProfileImport != nil }, set: { shown in if enabled && !shown { store.pendingProfileImport = nil } })) {
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
