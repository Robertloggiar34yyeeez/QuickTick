import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    // Share the same state as the dock, so toggling this setting immediately
    // updates the visible tabs even before the Settings sheet dismisses.
    @Binding var showAITab: Bool
    @AppStorage("quicktick-modern-ui-v1") private var modernUI = true
    @AppStorage("quicktick-suggested-themes-v1") private var suggestedThemesEnabled = true
    @AppStorage(SuggestedThemeMode.storageKey) private var suggestedThemesMode = SuggestedThemeMode.balanced.rawValue
    @AppStorage("quicktick-accent-palette-v1") private var accentPalette = "violet"
    @AppStorage(BackgroundArtworkStore.enabledKey) private var customBackgroundEnabled = false
    @AppStorage(BackgroundArtworkStore.revisionKey) private var customBackgroundRevision = 0
    @State private var selectedBackgroundPhoto: PhotosPickerItem?
    @State private var backgroundImporting = false
    @State private var backgroundError: String?
    @AppStorage("quicktick-skip-video-intros-v1") private var skipVideoIntros = false
    @AppStorage("quicktick-skip-hhaven-intros-v1") private var skipHavenIntros = true
    @AppStorage(VideoPlaybackPreferences.autoplayKey) private var autoplayVideos = true
    @AppStorage("quicktick-rhythm-finish-text-v1") private var rhythmFinishText = "Beautiful rhythm. Session complete."
    @AppStorage("quicktick-rhythm-finish-style-v1") private var rhythmFinishStyle = "Glow"
    @AppStorage("quicktick-rhythm-finish-animation-v1") private var rhythmFinishAnimation = "Scale"
    @AppStorage("quicktick-rhythm-mode-v1") private var rhythmMode = "adaptive"
    @AppStorage("quicktick-rhythm-metronome-v1") private var rhythmClicks = false
    @AppStorage("quicktick-rhythm-haptics-v1") private var rhythmHaptics = true
    @State private var status = ""
    @State private var user = ""
    @State private var key = ""
    @State private var session = ""
    @State private var username = ""
    @State private var remember = true
    @State private var onboarding = false
    @State private var viewedProvider: Provider = .rule34
    @State private var providerProfiles: [String: RecommendationProfile] = [:]
    @State private var visualInterests: [String: [String]] = [:]
    @State private var sharedProfile: RecommendationTransfer?
    @State private var exportProfileFile: RecommendationProfileFile?
    @State private var exportingProfileFile = false
    @State private var importingProfile = false
    @State private var preparingProfile = false
    @State private var activeSection: SettingsDestination = .appearance
    @State private var mobileCLIPInstalled = MobileCLIPRealLifeEncoder.isInstalled()
    @State private var mobileCLIPInstalling = false
    @State private var mobileCLIPError: String?

    var body: some View {
        settingsPage
    }

    private var swipeableProviderProfiles: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Provider profiles").font(.subheadline.weight(.semibold))
                Spacer()
                Text("Swipe left or right")
                    .font(.caption2).foregroundStyle(AppTheme.secondaryLabel)
            }
            TabView(selection: $viewedProvider) {
                ForEach(Provider.allCases) { provider in
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 10) {
                            ProviderLogoView(provider: provider)
                                .frame(width: 38, height: 38)
                                .background(AppTheme.elevatedSurface,
                                            in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.displayName).font(.headline)
                                Text(provider == store.selectedProvider ?
                                     "Current feed" : "Separate learned profile")
                                    .font(.caption2).foregroundStyle(AppTheme.secondaryLabel)
                            }
                            Spacer()
                            if provider == store.selectedProvider {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(AppTheme.accent)
                            }
                        }
                        let terms = providerProfiles[provider.rawValue]?.terms ?? [:]
                        let learned = terms.filter { $0.value > 0 }
                            .sorted { $0.value > $1.value }.prefix(8).map(\.key)
                        let chosen = store.tasteSetup.sources[provider.rawValue]?.into ?? []
                        let visuals = visualInterests[provider.rawValue] ?? []
                        let visible = Array(Set(learned + chosen + visuals))
                            .filter(TasteTagSuggestions.isUseful).sorted().prefix(9)
                        if visible.isEmpty {
                            Text("No interests yet. Like posts to build this profile.")
                                .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
                        } else {
                            Text(visible.map {
                                $0.replacingOccurrences(of: "_", with: " ")
                            }.joined(separator: " · "))
                                .font(.caption).lineLimit(3)
                        }
                        HStack {
                            Text("\(learned.count) learned interests")
                                .font(.caption2).foregroundStyle(AppTheme.secondaryLabel)
                            Spacer()
                            if provider != store.selectedProvider {
                                Button("Use \(provider.displayName)") {
                                    store.selectedProvider = provider
                                    Task { await store.refresh() }
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.accent)
                            }
                        }
                    }
                    .padding(13).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 17))
                    .overlay(RoundedRectangle(cornerRadius: 17).stroke(AppTheme.border))
                    .tag(provider)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 182)
            HStack(spacing: 5) {
                ForEach(Provider.allCases) { provider in
                    Capsule()
                        .fill(provider == viewedProvider ? AppTheme.accent : AppTheme.elevatedSurface)
                        .frame(width: provider == viewedProvider ? 19 : 6, height: 6)
                }
            }
            .accessibilityLabel("Provider profile pages")
        }
        .task {
            viewedProvider = store.selectedProvider
            let snapshot = await store.recommendations.snapshot()
            providerProfiles = snapshot.profiles
            var visualProfiles: [String: [String]] = [:]
            for provider in Provider.allCases {
                visualProfiles[provider.rawValue] = await store.visual.discoveryTerms(provider: provider)
            }
            visualInterests = visualProfiles
        }
    }

    private var settingsPage: some View {
        ScrollViewReader { scroll in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                settingsHero
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 9) {
                        ForEach(SettingsDestination.allCases) { destination in
                            Button {
                                activeSection = destination
                                withAnimation(.smooth(duration: 0.36)) { scroll.scrollTo(destination.rawValue, anchor: .top) }
                            } label: {
                                Label(destination.title, systemImage: destination.symbol)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(activeSection == destination ? .white : .white.opacity(0.76))
                                    .padding(.horizontal, 14)
                                    .frame(height: 37)
                                    .background(activeSection == destination
                                        ? (AppTheme.isDeSlopified ? AnyShapeStyle(AppTheme.surface) : AnyShapeStyle(AppTheme.gradient))
                                        : AnyShapeStyle(AppTheme.elevatedSurface), in: Capsule())
                                    .overlay(Capsule().stroke(activeSection == destination ? AppTheme.border.opacity(1) : AppTheme.border.opacity(0.55)))
                            }
                            .buttonStyle(QuicktickPressStyle())
                        }
                    }
                    .padding(.vertical, 3)
                }
                .accessibilityIdentifier("settings-category-chips")
            if let storageWarning = store.storageWarning { SettingsGroup(title: "Storage needs attention", icon: "exclamationmark.triangle") { Text(storageWarning).foregroundStyle(.orange) } }
            SettingsGroup(title: "Navigation", icon: "square.grid.2x2") {
                HStack(spacing: 12) {
                    Text("Show AI tab")
                    Spacer(minLength: 8)
                    // Keep the switch's accessible frame on the actual
                    // control, rather than the entire scroll-view row. UI
                    // automation and normal taps now hit the same target.
                    Toggle("Show AI tab", isOn: $showAITab)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("show-ai-tab-toggle")
                        .frame(minWidth: 52, minHeight: 44)
                }
                .modifier(SettingsControlRow())
                Text(showAITab ? "Five tabs" : "Four tabs · Turn this on to open Create again")
                    .font(.footnote).foregroundStyle(.secondary)
            }.id(SettingsDestination.navigation.rawValue)
            SettingsGroup(title: "Appearance", icon: "paintbrush.pointed") {
                Toggle("Modern interface", isOn: $modernUI)
                    .modifier(SettingsControlRow())
                    .accessibilityIdentifier("modern-ui-toggle")
                Text(modernUI ? "Rounded surfaces, compact chips and animated navigation." : "Previous QuickTick interface restored.")
                    .font(.footnote).foregroundStyle(.secondary)
                Label("Color theme", systemImage: "paintpalette.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.secondaryLabel)
                SettingsPaletteSelector(selected: $accentPalette)
                Text("De-slopified uses flat neutral surfaces, consistent spacing and restrained colour. Other themes retain their original appearance.")
                    .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
                HStack(spacing: 10) {
                    Image(systemName: "photo.artframe")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(AppTheme.accent)
                        .frame(width: 45, height: 45)
                        .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Blurred photo background").font(.subheadline.weight(.semibold))
                        Text("Your image stays on this device. Blur is created only once on import.")
                            .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
                    }
                    Spacer(minLength: 0)
                }
                Toggle("Show custom background", isOn: $customBackgroundEnabled)
                    .modifier(SettingsControlRow())
                    .accessibilityIdentifier("custom-background-toggle")
                PhotosPicker(selection: $selectedBackgroundPhoto, matching: .images) {
                    Label(backgroundImporting ? "Preparing background…" : "Choose background image", systemImage: "photo.on.rectangle.angled")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 14))
                }
                .disabled(backgroundImporting)
                .accessibilityIdentifier("choose-background-photo")
                if customBackgroundEnabled {
                    Button(role: .destructive) {
                        customBackgroundEnabled = false
                    } label: {
                        Label("Use theme background instead", systemImage: "paintpalette")
                            .font(.caption.weight(.medium))
                    }
                }
                if let backgroundError { Text(backgroundError).font(.caption).foregroundStyle(.orange) }
            }.id(SettingsDestination.appearance.rawValue)
            SettingsGroup(title: "Provider access", icon: "lock.shield") {
                TextField("Rule34 user ID", text: $user).textInputAutocapitalization(.never)
                    .modifier(SettingsTextFieldSurface())
                    .accessibilityIdentifier("rule34-user-input").accessibilityLabel("Rule34 user ID")
                SecureField("Rule34 API key", text: $key)
                    .modifier(SettingsTextFieldSurface())
                    .accessibilityIdentifier("rule34-key-input").accessibilityLabel("Rule34 API key")
                Toggle("Remember Rule34 credentials", isOn: $remember)
                TextField("Pornhub username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .modifier(SettingsTextFieldSurface())
                    .accessibilityIdentifier("pornhub-user-input").accessibilityLabel("Pornhub username")
                SecureField("Supported Pornhub session", text: $session)
                    .modifier(SettingsTextFieldSurface())
                    .accessibilityIdentifier("pornhub-session-input").accessibilityLabel("Supported Pornhub session")
                Button("Save access settings") { Task { await store.saveCredentials(user: user, key: key, session: session, remember: remember, username: username); await store.refresh() } }
            }.disabled(store.isSyncing).id(SettingsDestination.access.rawValue)
            SettingsGroup(title: "Suggested themes", icon: "square.grid.2x2.fill") {
                Toggle("Suggested themes on Home", isOn: $suggestedThemesEnabled)
                    .modifier(SettingsControlRow())
                    .accessibilityIdentifier("suggested-themes-toggle")
                Text("Use image-backed themes from your likes and learned interests. The row changes on every Home refresh.")
                    .font(.footnote).foregroundStyle(AppTheme.secondaryLabel)
                Text("Rule34 discovery style")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    ForEach(SuggestedThemeMode.allCases) { mode in
                        let selected = suggestedThemesMode == mode.rawValue
                        Button { suggestedThemesMode = mode.rawValue } label: {
                            Text(mode.label)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(selected ? .white : AppTheme.secondaryLabel)
                                .frame(maxWidth: .infinity, minHeight: 42)
                                .background(selected ? AnyShapeStyle(AppTheme.gradient) : AnyShapeStyle(AppTheme.elevatedSurface), in: Capsule())
                                .overlay(Capsule().stroke(selected ? AppTheme.accent : AppTheme.border))
                        }
                        .buttonStyle(QuicktickPressStyle())
                        .accessibilityIdentifier("suggested-mode-\(mode.rawValue)")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                Text("Tags follows your favorite attributes. Franchises recommends popular series detected in Rule34 posts using a curated name database. Mix alternates both for discovery. Other providers continue using their own tags and categories.")
                    .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
            }.id(SettingsDestination.suggestions.rawValue)
            SettingsGroup(title: "Learned interests · \(store.selectedProvider.displayName)", icon: "sparkles") {
                swipeableProviderProfiles
                Button { onboarding = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 46, height: 46)
                            .background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: 15))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Make QuickTick yours")
                                .font(.system(.headline, design: .rounded))
                                .foregroundStyle(.white)
                            Text("Edit interests and dislikes with live tag suggestions")
                                .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").foregroundStyle(AppTheme.secondaryLabel)
                    }
                    .padding(12)
                    .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(AppTheme.accent.opacity(0.25)))
                }
                .buttonStyle(QuicktickPressStyle())
                .accessibilityIdentifier("personalize-feed")
                LabeledContent("Engine", value: store.recommendationMode)
                if store.learnedInterests.isEmpty {
                    Text("Interact with posts or search to learn interests.")
                        .foregroundStyle(AppTheme.secondaryLabel)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 115), spacing: 7)], spacing: 7) {
                        ForEach(Array(store.learnedInterests.filter(TasteTagSuggestions.isUseful).prefix(24)), id: \.self) { interest in
                            Text(interest.replacingOccurrences(of: "_", with: " "))
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .padding(.horizontal, 11)
                                .frame(maxWidth: .infinity, minHeight: 34)
                                .background(AppTheme.accent.opacity(0.14), in: Capsule())
                                .overlay(Capsule().stroke(AppTheme.accent.opacity(0.24)))
                        }
                    }
                }
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
            }.id(SettingsDestination.recommendations.rawValue)
            SettingsGroup(title: "Transfer recommendations", icon: "square.and.arrow.up") {
                Button { preparingProfile = true; Task {
                    defer { preparingProfile = false }
                    do { sharedProfile = try await store.exportRecommendationProfile() }
                    catch { store.profileTransferError = error.localizedDescription }
                } } label: { Label(preparingProfile ? "Preparing profile…" : "Share / AirDrop profile", systemImage: "square.and.arrow.up") }
                    .disabled(preparingProfile || !store.bootstrapped).accessibilityIdentifier("share-recommendation-profile")
                Button { preparingProfile = true; Task {
                    defer { preparingProfile = false }
                    do {
                        exportProfileFile = RecommendationProfileFile(profile: try await store.exportRecommendationProfile())
                        exportingProfileFile = true
                    } catch { store.profileTransferError = error.localizedDescription }
                } } label: { Label("Export .quicktickprofile file", systemImage: "doc.badge.arrow.up") }
                    .disabled(preparingProfile || !store.bootstrapped)
                    .accessibilityIdentifier("export-recommendation-file")
                Button("Import recommendation profile") { importingProfile = true }.accessibilityIdentifier("import-recommendation-profile")
                Text("AirDrop or save a .quicktickprofile file, then open it on another device or use Import here. Only interests and exclusions transfer—never logins, downloads or viewing history. Treat the file as private.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            SettingsGroup(title: "Persistent exclusions", icon: "line.3.horizontal.decrease.circle") {
                PersistentExclusionEditor()
            }
            SettingsGroup(title: "Visual intelligence", icon: "eye") {
                Toggle("Learn visual taste while browsing", isOn: $store.visualAnalysisEnabled)
                    .modifier(SettingsControlRow())
                Text("Separate anime and real-life tastes. Reuses previews and gradually checks small favorite thumbnails on Wi-Fi. Pauses while scrolling, loading or playing media, and in Low Power Mode.").font(.footnote).foregroundStyle(.secondary)
                Button {
                    guard !mobileCLIPInstalling, !mobileCLIPInstalled else { return }
                    mobileCLIPInstalling = true; mobileCLIPError = nil
                    Task {
                        do {
                            try await MobileCLIPRealLifeEncoder.shared.install()
                            mobileCLIPInstalled = true
                            store.visualModelDidInstall()
                        } catch { mobileCLIPError = error.localizedDescription }
                        mobileCLIPInstalling = false
                    }
                } label: {
                    HStack(spacing: 10) {
                        if mobileCLIPInstalling { InfinityLoader(size: 22) }
                        else { Image(systemName: mobileCLIPInstalled ? "checkmark.circle.fill" : "arrow.down.circle") }
                        Text(mobileCLIPInstalled ? "MobileCLIP ready" : (mobileCLIPInstalling ? "Installing MobileCLIP…" : "Install MobileCLIP · 23 MB"))
                        Spacer()
                    }
                    .frame(minHeight: 44)
                }
                .buttonStyle(QuicktickPressStyle())
                .disabled(mobileCLIPInstalling || mobileCLIPInstalled)
                .accessibilityIdentifier("install-mobileclip-button")
                Text("Optional Apple on-device model for real-life visual similarity. Keeps anime and photo tastes separate; existing tags still determine specific themes. Runs during idle visual analysis, never during video playback.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let mobileCLIPError {
                    Text("MobileCLIP installation failed: \(mobileCLIPError)")
                        .font(.footnote).foregroundStyle(.orange)
                }
                ManualVisualRefreshPanel(manager: store.downloads)
            }
            SettingsGroup(title: "Playback", icon: "play.rectangle") {
                Toggle("Immersion framing (fill)", isOn: $store.immersionFraming)
                    .modifier(SettingsControlRow())
                Toggle("Mute", isOn: $store.muted)
                    .modifier(SettingsControlRow())
                Toggle("Autoplay in Home & cards", isOn: $autoplayVideos)
                    .modifier(SettingsControlRow())
                    .accessibilityIdentifier("autoplay-videos-toggle")
                Text("When off, videos in Home and other card views stay on previews until you tap Play. Immersive always autoplays as you swipe.")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("Skip Pornhub intros (10 seconds)", isOn: $skipVideoIntros)
                    .modifier(SettingsControlRow())
                    .accessibilityIdentifier("skip-video-intros-toggle")
                Toggle("Skip Hentai Haven intros (10 seconds)", isOn: $skipHavenIntros)
                    .modifier(SettingsControlRow())
                    .accessibilityIdentifier("skip-hhaven-intros-toggle")
                Text("For enabled providers with videos longer than 12 seconds, QuickTick waits for the 0:10 position to load before showing playback. Hentai Haven is enabled by default.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.id(SettingsDestination.playback.rawValue)
            SettingsGroup(title: "Rhythm & floating player", icon: "waveform.path") {
                Picker("Default rhythm", selection: $rhythmMode) {
                    ForEach(RhythmPattern.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
                }
                Toggle("Metronome sounds", isOn: $rhythmClicks)
                    .modifier(SettingsControlRow())
                Toggle("Beat haptics", isOn: $rhythmHaptics)
                    .modifier(SettingsControlRow())
                TextField("Completion message", text: $rhythmFinishText, axis: .vertical)
                    .lineLimit(2...4)
                    .modifier(SettingsTextFieldSurface())
                Picker("Completion appearance", selection: $rhythmFinishStyle) {
                    ForEach(["Glow", "Glass", "Minimal"], id: \.self) { Text($0) }
                }
                Picker("Completion animation", selection: $rhythmFinishAnimation) {
                    ForEach(["Scale", "Slide", "Fade"], id: \.self) { Text($0) }
                }
                Toggle("Mute feed audio during floating video", isOn: $store.pipMuteFeed)
                    .modifier(SettingsControlRow())
                Text("Otherwise feed audio is reduced to 15% while a floating video plays. Normal audio returns when it closes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            }
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, AppTheme.contentMargin)
            .padding(.bottom, 44)
        }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(AppTheme.canvas)
        .background(ThemeBackdrop())
        .onChange(of: selectedBackgroundPhoto) { _, item in
            guard let item else { return }
            backgroundImporting = true
            backgroundError = nil
            Task {
                defer { backgroundImporting = false }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw APIError.server("Could not read the selected photo.")
                    }
                    try await BackgroundArtworkStore.install(data)
                    customBackgroundRevision &+= 1
                    customBackgroundEnabled = true
                } catch { backgroundError = error.localizedDescription }
            }
        }
        .navigationTitle("Settings")
        .toolbarBackground(AppTheme.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .preferredColorScheme(.dark)
        .tint(AppTheme.accent)
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
            .fileExporter(isPresented: $exportingProfileFile, document: exportProfileFile,
                          contentType: .quicktickProfile, defaultFilename: "QuickTick-Recommendations") { result in
                if case .failure(let error) = result { store.profileTransferError = error.localizedDescription }
            }
            .modifier(ProfileImportConfirmation())
            .task { await reloadAccessFields() }
            .onDisappear { store.cancelManualVisualRefresh() }
    }

    @ViewBuilder private var settingsHero: some View {
        if AppTheme.isDeSlopified {
            VStack(alignment: .leading, spacing: 5) {
                Text("Settings")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Your appearance, preferences and playback.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryLabel)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 15)
            .padding(.bottom, 7)
        } else {
            legacySettingsHero
        }
    }

    private var legacySettingsHero: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("YOUR QUICKTICK")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(2.1)
                    .foregroundStyle(AppTheme.accent)
                Text("Your space.")
                    .font(.system(size: 33, weight: .bold, design: .rounded))
                    .tracking(-1.0)
                Text("One look, everywhere.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.secondaryLabel)
                HStack(spacing: 8) {
                    Label("Private by default", systemImage: "lock.shield")
                    Label("Made for you", systemImage: "sparkles")
                }
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.82))
                .padding(.top, 5)
            }
            Spacer(minLength: 0)
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 27, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .frame(width: 76, height: 76)
                .background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .shadow(color: AppTheme.accent.opacity(0.28), radius: 20, y: 7)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(AppTheme.accent.opacity(0.18)))
        .padding(.top, 12)
    }

    private func reloadAccessFields() async {
        let credentials = await store.api.credentials
        user = credentials.rule34User; key = credentials.rule34Key; session = credentials.pornhubSession
        username = store.syncedPornhubUsername; remember = store.rememberedProviderAccess
    }
}

private enum SettingsDestination: String, CaseIterable, Identifiable {
    case appearance, suggestions, navigation, recommendations, playback, access
    var id: String { rawValue }
    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .suggestions: "Themes"
        case .navigation: "Navigation"
        case .recommendations: "For you"
        case .playback: "Playback"
        case .access: "Access"
        }
    }
    var symbol: String {
        switch self {
        case .appearance: "paintpalette"
        case .suggestions: "square.grid.2x2.fill"
        case .navigation: "square.grid.2x2"
        case .recommendations: "sparkles"
        case .playback: "play.rectangle"
        case .access: "lock.shield"
        }
    }
}

private struct SettingsPaletteSelector: View {
    @Binding var selected: String
    @State private var showingAll = false
    private var visiblePalettes: [AppTheme.AccentPalette] {
        if showingAll { return AppTheme.AccentPalette.allCases }
        let current = AppTheme.AccentPalette(rawValue: selected) ?? .violet
        var featured: [AppTheme.AccentPalette] = []
        for palette in [current, .deSlopified, .oledBlack, .galaxy, .darkCosmos] where !featured.contains(palette) {
            featured.append(palette)
        }
        return Array(featured.prefix(3))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
        // Adaptive columns maintain one 10pt gutter without squeezing theme
        // names into 90pt cells on narrow iPhones.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 180), spacing: 10)], spacing: 10) {
            ForEach(visiblePalettes) { palette in
                let chosen = selected == palette.rawValue
                let swatchColors = palette == .deSlopified
                    ? [Color(red: 0.067, green: 0.067, blue: 0.067), Color(red: 0.15, green: 0.15, blue: 0.15)]
                    : palette.gradientColors
                Button {
                    withAnimation(.smooth(duration: 0.26)) { selected = palette.rawValue }
                } label: {
                    VStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(LinearGradient(colors: swatchColors,
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(height: 49)
                            .overlay(alignment: .bottomLeading) {
                                if palette == .deSlopified {
                                    Capsule().fill(palette.primary).frame(width: 44, height: 4).padding(10)
                                }
                            }
                            .overlay {
                                if [.galaxy, .darkCosmos, .auroraNight, .solarEclipse, .oledBlack, .graphite, .midnightBlue, .emeraldNoir, .crimsonNoir, .nebulaDrift, .obsidianGold, .polarNight].contains(palette) {
                                    HStack(alignment: .top) {
                                        Image(systemName: "sparkle").font(.system(size: 13, weight: .light))
                                        Spacer()
                                        Image(systemName: "star.fill").font(.system(size: 5))
                                    }
                                    .foregroundStyle(.white.opacity(0.88))
                                    .padding(10)
                                    .allowsHitTesting(false)
                                }
                            }
                            .overlay {
                                if chosen {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 22, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .shadow(color: .black.opacity(0.4), radius: 4)
                                }
                            }
                            .overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(chosen ? 0.9 : 0.14), lineWidth: chosen ? 2 : 1))
                        Text(palette.name)
                            .font(.system(size: 11, weight: chosen ? .bold : .medium, design: .rounded))
                            .foregroundStyle(chosen ? .white : AppTheme.secondaryLabel)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(5)
                    .background(chosen ? AppTheme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(QuicktickPressStyle())
                .accessibilityLabel("\(palette.name) accent")
                .accessibilityAddTraits(chosen ? .isSelected : [])
                .accessibilityIdentifier("accent-\(palette.rawValue)")
            }
        }
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { showingAll.toggle() }
        } label: {
            Label(showingAll ? "Show fewer themes" : "See all \(AppTheme.AccentPalette.allCases.count) themes",
                  systemImage: showingAll ? "chevron.up" : "chevron.down")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.accent)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(QuicktickPressStyle())
        .accessibilityIdentifier("show-all-themes")
        }
    }
}

private struct SettingsTextFieldSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.subheadline)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(AppTheme.background.opacity(0.65), in: RoundedRectangle(cornerRadius: AppTheme.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: AppTheme.controlRadius).stroke(AppTheme.border))
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
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 36, height: 36)
                    .background(AppTheme.isDeSlopified ? Color.clear : AppTheme.accent.opacity(0.13),
                                in: RoundedRectangle(cornerRadius: 12))
                Text(title)
                    .font(.system(size: 16, weight: .semibold,
                                  design: AppTheme.isDeSlopified ? .default : .rounded))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .font(.subheadline)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(AppTheme.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(AppTheme.isDeSlopified ? AppTheme.contentMargin : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: AppTheme.panelRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: AppTheme.panelRadius, style: .continuous).stroke(AppTheme.border, lineWidth: 1))
    }
}

/// The same interactive row surface is shared by Settings switches across
/// appearance, personalization, media and rhythm preferences.
private struct SettingsControlRow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .frame(minHeight: 50)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous)
                .stroke(AppTheme.border.opacity(0.65), lineWidth: 1))
    }
}

private struct ManualVisualRefreshPanel: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var manager: DownloadManager
    @State private var carouselURLs: [String] = []
    @State private var carouselIndex = 0
    @State private var carouselSlide = 0.0
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
                if !carouselURLs.isEmpty {
                    GeometryReader { area in
                        ZStack {
                            ForEach(-2...2, id: \.self) { slot in
                                let offset = (carouselIndex + slot + carouselURLs.count * 4) % carouselURLs.count
                                let position = Double(slot) + carouselSlide
                                CachedMediaImage(url: carouselURLs[offset], pixels: 400, fill: true)
                                    .frame(width: min(174, area.size.width * 0.54), height: 154)
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(abs(position) < 0.5 ? 0.38 : 0.10)))
                                    .scaleEffect(max(0.66, 1 - abs(position) * 0.17))
                                    .rotation3DEffect(.degrees(position * -12), axis: (x: 0, y: 1, z: 0))
                                    .offset(x: CGFloat(position) * min(130, area.size.width * 0.34))
                                    .opacity(max(0.35, 1 - abs(position) * 0.29))
                                    .zIndex(3 - abs(position))
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                    }
                    .frame(height: 165)
                    .background(AppTheme.navigationSurface, in: RoundedRectangle(cornerRadius: 20))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Visual taste download carousel")
                    .accessibilityValue("Scanning \(progress.completed) of \(progress.total)")
                    .accessibilityIdentifier("visual-refresh-carousel")
                }
                if progress.running {
                    Button("Stop update", role: .cancel) { store.cancelManualVisualRefresh() }
                        .accessibilityIdentifier("cancel-visual-refresh")
                }
            }
        }.task(id: manager.records.count) {
            // Thumbnails only: the old animated-GIF strip decoded media
            // concurrently with Core ML and made manual scans stutter.
            carouselURLs = manager.records.filter { $0.state == .complete }
                .compactMap { item in item.thumbnailLocalPath.map { URL(fileURLWithPath: $0).absoluteString }
                    ?? (item.offlinePost?.type.lowercased() == "image" ? item.exportURL?.absoluteString : nil) }
                .shuffled()
            carouselIndex = 0; carouselSlide = 0
        }
        .task(id: store.isManualVisualScanRunning) {
            guard store.isManualVisualScanRunning else { return }
            while !Task.isCancelled && store.isManualVisualScanRunning {
                guard carouselURLs.count > 1 else {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    continue
                }
                if reduceMotion {
                    carouselIndex = (carouselIndex + 1) % carouselURLs.count
                    do { try await Task.sleep(for: .seconds(1.15)) } catch { return }
                } else {
                    // Animate the *positions* first, then rotate the image
                    // indices with animations disabled at the invisible seam.
                    withAnimation(.smooth(duration: 0.72)) { carouselSlide = -1 }
                    do { try await Task.sleep(for: .milliseconds(760)) } catch { return }
                    withTransaction(Transaction(animation: nil)) {
                        carouselIndex = (carouselIndex + 1) % carouselURLs.count
                        carouselSlide = 0
                    }
                    do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                }
            }
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
        } message: { Text("Replaces chosen and learned interests and exclusions on this device. Favorites, downloads and logins stay as they are. Only import a file from someone you trust.") }
        .alert("Profile transfer", isPresented: Binding(get: { enabled && store.profileTransferError != nil }, set: { if enabled && !$0 { store.profileTransferError = nil } })) {
            Button("OK", role: .cancel) { store.profileTransferError = nil }
        } message: { Text(store.profileTransferError ?? "") }
    }
}
