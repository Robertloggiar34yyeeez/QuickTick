import SwiftUI
import UIKit

/// Present exports from the active window rather than from a narrow SwiftUI
/// ShareLink inside a lazy scroll row. A full-height activity sheet on iPhone
/// and a generously sized form sheet on iPad keep the actions tappable.
@MainActor
enum DownloadExporter {
    static func localFileURL(_ address: String) -> URL? {
        guard let url = URL(string: address), url.isFileURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static func share(_ urls: [URL]) {
        guard !urls.isEmpty,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }

        var presenter = root
        while let next = presenter.presentedViewController { presenter = next }
        guard !(presenter is UIActivityViewController) else { return }

        let activity = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        let isPad = scene.traitCollection.userInterfaceIdiom == .pad
        activity.modalPresentationStyle = isPad ? .formSheet : .pageSheet
        activity.preferredContentSize = CGSize(width: 620, height: 680)
        if let sheet = activity.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        // Required on iPad if the system adapts its share presentation into
        // a popover, even though we request a larger form sheet by default.
        if let popover = activity.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX,
                                        y: presenter.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        presenter.present(activity, animated: true)
    }
}

struct DownloadsFeedView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View { DownloadContent(manager: store.downloads) }
}

private struct DownloadContent: View {
    @ObservedObject var manager: DownloadManager
    @State private var immersive = false
    @State private var rhythm = false
    @State private var immersivePostID: String?
    @State private var selecting = false
    @State private var selectedKeys: Set<String> = []
    @State private var confirmDelete = false
    private var exportURLs: [URL] {
        manager.records.filter { selectedKeys.contains($0.key) }.compactMap(\.exportURL)
    }
    var body: some View {
        ZStack {
                GeometryReader { geometry in
                ScrollView {
                LazyVStack(spacing: 18) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Saved offline")
                                .font(.system(size: AppTheme.isDeSlopified ? 26 : 30,
                                              weight: AppTheme.isDeSlopified ? .semibold : .bold,
                                              design: AppTheme.isDeSlopified ? .default : .rounded))
                                .tracking(AppTheme.isDeSlopified ? -0.4 : -1)
                            Text("\(manager.records.count) downloads, always with you")
                                .font(.subheadline).foregroundStyle(AppTheme.secondaryLabel)
                        }
                        Spacer()
                        if !AppTheme.isDeSlopified {
                        Image(systemName: "arrow.down.to.line")
                            .font(.system(size: 23))
                            .accessibilityHidden(true)
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
                    .padding(.top, 2)
                    if selecting { selectionControls }
                    if let error = manager.storageError { Text(error).foregroundStyle(.orange) }
                    if manager.records.isEmpty { ContentUnavailableView("No downloads yet", systemImage: "arrow.down.to.line", description: Text("Save posts to view them offline here.")) }
                    ForEach(manager.records) { record in
                        if record.state == .complete {
                            // Transfer progress changes the parent several times a second.
                            // Equatable completed rows keep expensive media/card state
                            // mounted without rebuilding on unrelated progress packets.
                            DownloadCachedCardRow(record: record,
                                                  available: CGSize(width: min(AppTheme.feedWidth, geometry.size.width - 32), height: geometry.size.height),
                                                  manager: manager, selecting: selecting,
                                                  selected: selectedKeys.contains(record.key)) {
                                toggleSelection(record.key)
                            }
                            .equatable()
                        } else {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                if let path = record.thumbnailLocalPath {
                                    CachedMediaImage(url: URL(fileURLWithPath: path).absoluteString, pixels: 216).frame(width: 72, height: 72).clipped()
                                }
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 8) {
                                        if record.state == .downloading { InfinityLoader(size: 27) }
                                        Text(record.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                                    }
                                    Text("\(record.provider) · \(record.state.rawValue)")
                                        .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
                                    Text(record.formattedSize).font(.caption.monospacedDigit())
                                    ProgressView(value: record.progress).tint(AppTheme.accent)
                                    if let error = record.errorMessage { Text(error).foregroundStyle(.orange).font(.caption) }
                                }
                            }
                            HStack {
                                if record.state == .downloading { Button("Pause") { manager.pause(record) }; Button("Cancel") { manager.cancel(record) } }
                                if record.state == .paused { Button("Resume") { manager.resume(record) }; Button("Cancel") { manager.cancel(record) } }
                                if record.state == .failed || record.state == .cancelled { Button("Retry") { manager.retry(record) } }
                                Spacer()
                                if !selecting { Button("Delete", role: .destructive) { manager.delete(record) } }
                            }.buttonStyle(.bordered)
                        }
                        .padding(14)
                        .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(AppTheme.border))
                        .overlay { if selecting { selectionOverlay(for: record) } }
                        }
                    }
                }
                // Share the Home feed's centred 680pt content column on iPad.
                // Title, actions, cards and export rows now use one left edge.
                .frame(maxWidth: AppTheme.feedWidth)
                .padding(.horizontal, AppTheme.contentMargin)
                .padding(.vertical, AppTheme.contentMargin)
                .frame(maxWidth: .infinity)
                }
                }
            if immersive {
                ImmersiveFeedView(posts: localPosts, offline: true, activePostID: $immersivePostID,
                                  onClose: { immersive = false })
                    .transition(.move(edge: .trailing))
            }
        }.scrollContentBackground(.hidden).background(ThemeBackdrop()).navigationTitle("Downloads")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { rhythm = true } label: { Label("Rhythm", systemImage: "waveform.path") }
                        .disabled(localPosts.isEmpty)
                        .accessibilityIdentifier("downloads-rhythm")
                    Button(immersive ? "Feed" : "Offline Immersive") { immersive.toggle() }
                        .disabled(!immersive && !localPosts.contains(where: \.isImmersiveMedia))
                    Button(selecting ? "Done" : "Select") {
                        selecting.toggle()
                        if !selecting { selectedKeys.removeAll() }
                    }
                    .disabled(manager.records.isEmpty)
                    .accessibilityIdentifier("downloads-select")
                }
            }
            .fullScreenCover(isPresented: $rhythm) { RhythmSessionView(posts: localPosts, offline: true) }
            .confirmationDialog("Delete \(selectedKeys.count) downloads?", isPresented: $confirmDelete,
                                titleVisibility: .visible) {
                Button("Delete selected files", role: .destructive) {
                    manager.delete(keys: selectedKeys)
                    selectedKeys.removeAll()
                    selecting = false
                }
            } message: { Text("The saved files will be removed from this device. This cannot be undone.") }
    }
    private var selectionControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("\(selectedKeys.count) selected")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(selectedKeys.count == manager.records.count ? "Clear" : "Select all") {
                    selectedKeys = selectedKeys.count == manager.records.count
                        ? [] : Set(manager.records.map(\.key))
                }
                .font(.caption.weight(.semibold))
            }
            HStack(spacing: 10) {
                if !exportURLs.isEmpty {
                    Button { DownloadExporter.share(exportURLs) } label: {
                        Label("Export \(exportURLs.count)", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .accessibilityIdentifier("downloads-export-selected")
                }
                Button { confirmDelete = true } label: {
                    Label("Delete", systemImage: "trash")
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .disabled(selectedKeys.isEmpty)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("downloads-delete-selected")
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(AppTheme.border))
        .accessibilityIdentifier("downloads-selection-controls")
    }
    private func selectionOverlay(for record: DownloadRecord) -> some View {
        Button { toggleSelection(record.key) } label: {
            RoundedRectangle(cornerRadius: 19).fill(.black.opacity(0.001))
                .overlay(alignment: .topLeading) {
                    Image(systemName: selectedKeys.contains(record.key) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 29, weight: .semibold))
                        .foregroundStyle(selectedKeys.contains(record.key) ? AppTheme.accent : .white)
                        .shadow(color: .black.opacity(0.6), radius: 5)
                        .padding(13)
                }
                .overlay(RoundedRectangle(cornerRadius: 19).stroke(selectedKeys.contains(record.key) ? AppTheme.accent : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(selectedKeys.contains(record.key) ? "Deselect" : "Select") \(record.title)")
        .accessibilityIdentifier("select-download-\(record.key)")
    }
    private var localPosts: [Post] {
        manager.records.compactMap(\.offlinePost)
    }
    private func toggleSelection(_ key: String) {
        if !selectedKeys.insert(key).inserted { selectedKeys.remove(key) }
    }
}

/// Isolates completed media cards from other downloads' progress publishes.
/// The parent can refresh status labels without recreating decoded images,
/// video surfaces, context menus, and SwiftUI playback observers in each card.
private struct DownloadCachedCardRow: View, Equatable {
    let record: DownloadRecord
    let available: CGSize
    let manager: DownloadManager
    let selecting: Bool
    let selected: Bool
    let onSelect: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.record == rhs.record && lhs.available == rhs.available &&
            lhs.selecting == rhs.selecting && lhs.selected == rhs.selected
    }

    var body: some View {
        VStack(spacing: 8) {
            if let post = record.offlinePost {
                PostCardView(post: post, available: available, playbackTab: 3, offline: true,
                             onDelete: { manager.delete(record) })
                    .frame(maxWidth: .infinity)
                    .overlay { if selecting { selectionOverlay } }
                HStack {
                    Text(record.formattedSize).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityIdentifier("download-size-\(record.key)")
                    Spacer()
                    if !selecting, let url = record.exportURL {
                        Button { DownloadExporter.share([url]) } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                            .accessibilityIdentifier("export-download-\(record.key)")
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(record.title).font(.headline).lineLimit(2)
                    Text("Saved file unavailable. Try restoring it from the source.")
                        .font(.caption).foregroundStyle(.orange)
                    HStack {
                        Button("Restore") { manager.retry(record) }
                            .accessibilityIdentifier("restore-download-\(record.key)")
                        Spacer()
                        if !selecting { Button("Delete", role: .destructive) { manager.delete(record) } }
                    }.buttonStyle(.bordered)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 18))
                .overlay { if selecting { selectionOverlay } }
            }
        }
    }

    private var selectionOverlay: some View {
        Button(action: onSelect) {
            RoundedRectangle(cornerRadius: 19).fill(.black.opacity(0.001))
                .overlay(alignment: .topLeading) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 29, weight: .semibold))
                        .foregroundStyle(selected ? AppTheme.accent : .white)
                        .shadow(color: .black.opacity(0.6), radius: 5)
                        .padding(13)
                }
                .overlay(RoundedRectangle(cornerRadius: 19)
                    .stroke(selected ? AppTheme.accent : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(selected ? "Deselect" : "Select") \(record.title)")
        .accessibilityIdentifier("select-download-\(record.key)")
    }
}
