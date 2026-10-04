import SwiftUI

import UIKit



struct SettingsView: View {

    @EnvironmentObject private var store: AppStore

    @State private var syncID = ""

    @State private var status = ""

    @State private var user = ""

    @State private var key = ""

    @State private var session = ""

    @State private var username = ""

    @State private var remember = true

    @State private var exclusions = ""

    @State private var onboarding = false

    var body: some View {

        Form {

            if let storageWarning = store.storageWarning { Section("Storage needs attention") { Text(storageWarning).foregroundStyle(.orange) } }

            Section("Quicktick Sync") {

                Text("Use the same Sync ID on web and iOS to share Favorites, access settings and interests.").font(.footnote).foregroundStyle(.secondary)

                HStack {

                    Button("Copy my Sync ID") { UIPasteboard.general.string = store.syncID; status = "Sync ID copied." }

                        .disabled(store.syncID.isEmpty)

                    Spacer()

                    Button("Sync now") { Task { do { try await store.syncNow(); await reloadAccessFields() } catch {} } }.disabled(store.isSyncing)

                }.buttonStyle(.plain)

                SecureField("Paste Sync ID from another device", text: $syncID)

                    .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()

                    .accessibilityIdentifier("sync-id-input")

                HStack {

                    Button("Paste ID") { syncID = UIPasteboard.general.string ?? "" }

                    Spacer()

                    Button("Connect and merge") { Task {

                        do { try await store.connectSyncID(syncID); status = ""; await reloadAccessFields(); await store.refresh() }

                        catch { status = error.localizedDescription }

                    } }.disabled(store.isSyncing || syncID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                }.buttonStyle(.plain)

                if store.isSyncing { ProgressView("Syncing profile…") }

                Text(status.isEmpty ? store.syncStatus : status).font(.footnote).foregroundStyle(store.syncFailed ? .orange : .secondary)

                Text("Your Sync ID is the key to your profile. Downloads stay on this device.").font(.caption).foregroundStyle(.secondary)

            }

            Section("Provider access") {

                TextField("Rule34 user ID", text: $user).textInputAutocapitalization(.never)

                SecureField("Rule34 API key", text: $key)

                Toggle("Remember Rule34 credentials", isOn: $remember)

                TextField("Pornhub username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()

                SecureField("Supported Pornhub session", text: $session)

                Button("Save access settings") { Task { await store.saveCredentials(user: user, key: key, session: session, remember: remember, username: username); await store.refresh() } }

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

        }.scrollContentBackground(.hidden).background(AppTheme.canvas).navigationTitle("Settings")

            .sheet(isPresented: $onboarding) { TasteOnboardingView() }

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

