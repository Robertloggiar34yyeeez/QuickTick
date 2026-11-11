import SwiftUI
import UIKit

/// Local-only search for saved media. Every word must match somewhere in the
/// title, provider, creator, tags or ID; underscores and case are normalized.
enum CollectionSearch {
    private static func normalized(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private static func matches(query: String, fields: [String]) -> Bool {
        matches(words: normalized(query).split(whereSeparator: \.isWhitespace).map(String.init), fields: fields)
    }

    private static func matches(words: [String], fields: [String]) -> Bool {
        guard !words.isEmpty else { return true }
        let haystack = normalized(fields.joined(separator: " "))
        return words.allSatisfy { haystack.contains($0) }
    }

    // Batch searches tokenize once, off the UI thread. Individual matches()
    // stays available for single-post actions and regression tests.
    static func filter(_ posts: [Post], query: String) -> [Post] {
        let words = normalized(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return posts }
        return posts.filter { post in
            matches(words: words, fields: [post.caption ?? "", post.creator ?? "", post.category ?? "",
                                         post.provider, post.id] + post.tags)
        }
    }

    static func matchingDownloadKeys(_ records: [DownloadRecord], query: String) -> Set<String> {
        let words = normalized(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return Set(records.map(\.key)) }
        return Set(records.lazy.filter { record in
            matches(words: words, fields: [record.title, record.provider, record.postID,
                                         record.mediaType ?? "", record.state.rawValue] + record.tags)
        }.map(\.key))
    }

    static func matches(_ post: Post, query: String) -> Bool {
        matches(query: query, fields: [post.caption ?? "", post.creator ?? "", post.category ?? "",
                                       post.provider, post.id] + post.tags)
    }

    static func matches(_ record: DownloadRecord, query: String) -> Bool {
        matches(query: query, fields: [record.title, record.provider, record.postID,
                                       record.mediaType ?? "", record.state.rawValue] + record.tags)
    }
}

/// Stable collection grouping across canonical IDs and older imported source names.
enum CollectionProviderOrder {
    static func key(_ raw: String) -> String {
        Provider.identify(raw)?.rawValue ?? raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func name(_ key: String) -> String {
        Provider.identify(key)?.displayName ?? key.capitalized
    }

    static func available(_ sources: [String]) -> [String] {
        Array(Set(sources.map(key))).sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }

}

struct CollectionSearchField: View {
    @Binding var text: String
    let placeholder: String
    let identifier: String
    var isSearching = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.secondaryLabel)
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityIdentifier(identifier)
            if isSearching {
                ProgressView().controlSize(.small).accessibilityLabel("Searching saved media")
            }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppTheme.secondaryLabel)
                        .frame(minWidth: 34, minHeight: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier(identifier + "-clear")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
        .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(AppTheme.border))
    }
}

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

/// Keep the same stable, opt-in shuffle behavior as Favorites. A progress
/// publish changes the record data, never its position in the shuffled deck.
struct DownloadShuffleOrder {
    private(set) var isShuffled = false
    private(set) var keys: [String] = []

    mutating func shuffle(records: [DownloadRecord]) {
        keys = records.map(\.key).shuffled()
        isShuffled = true
    }

    mutating func restoreOriginalOrder() {
        keys = []
        isShuffled = false
    }

    mutating func reconcile(records: [DownloadRecord]) {
        guard isShuffled else { return }
        let current = Set(records.map(\.key))
        keys.removeAll { !current.contains($0) }
        let existing = Set(keys)
        keys += records.map(\.key).filter { !existing.contains($0) }
    }

    func ordered(_ records: [DownloadRecord]) -> [DownloadRecord] {
        guard isShuffled else { return records }
        let byKey = Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) })
        let known = Set(keys)
        return keys.compactMap { byKey[$0] } + records.filter { !known.contains($0.key) }
    }
}

/// Search terms and local paths change only when the catalog changes, not
/// when the download manager publishes a new progress fraction.
private struct DownloadSearchIdentity: Equatable {
    let key: String
    let title: String
    let provider: String
    let postID: String
    let tags: [String]
    let state: DownloadState
    let mediaType: String?
    let localMediaPath: String?
    let thumbnailLocalPath: String?
    let fileSize: Int64?
    let errorMessage: String?

    init(_ record: DownloadRecord) {
        key = record.key; title = record.title; provider = record.provider
        postID = record.postID; tags = record.tags; state = record.state
        mediaType = record.mediaType; localMediaPath = record.localMediaPath
        thumbnailLocalPath = record.thumbnailLocalPath
        fileSize = record.fileSize; errorMessage = record.errorMessage
    }
}

/// Stable size sorting keeps unknown/incomplete file sizes last and preserves
/// the current order when two files have the same measured byte count.
enum DownloadSizeOrder {
    static func largestFirst(_ records: [DownloadRecord]) -> [DownloadRecord] {
        records.enumerated().sorted { lhs, rhs in
            let leftSize = lhs.element.fileSize ?? -1
            let rightSize = rhs.element.fileSize ?? -1
            return leftSize == rightSize ? lhs.offset < rhs.offset : leftSize > rightSize
        }.map { $0.element }
    }
}

struct DownloadsFeedView: View {
    @EnvironmentObject private var store: AppStore
    var scrollToTopRevision = 0
    var onImmersiveChange: (Bool) -> Void = { _ in }
    var body: some View {
        DownloadContent(manager: store.downloads, scrollToTopRevision: scrollToTopRevision,
                        onImmersiveChange: onImmersiveChange)
    }
}

private struct DownloadContent: View {
    // Download progress publishes often. Only transfer rows subscribe to it;
    // the large scroll container redraws when its catalog actually changes.
    let manager: DownloadManager
    @State private var catalogRecords: [DownloadRecord] = []
    var scrollToTopRevision = 0
    var onImmersiveChange: (Bool) -> Void = { _ in }
    @State private var immersive = false
    @State private var rhythm = false
    @State private var immersivePostID: String?
    @State private var selecting = false
    @State private var selectedKeys: Set<String> = []
    @State private var confirmDelete = false
    @State private var downloadOrder = DownloadShuffleOrder()
    @State private var selectedProviderID: String?
    @State private var sortByProvider = false
    @State private var sortBySizeDescending = false
    @State private var searchText = ""
    @State private var matchingKeys: Set<String> = []
    @State private var offlinePostCache: [String: Post] = [:]
    @State private var offlineCacheReady = false
    @State private var recordIdentity: [DownloadSearchIdentity] = []
    @State private var offlineMediaIdentity: [String] = []
    @State private var searchableIdentity: [String] = []
    @State private var recordRevision = 0
    @State private var searchRevision = 0
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var cacheTask: Task<Void, Never>?
    private var cardInset: CGFloat { AppTheme.isDeSlopified ? AppTheme.contentMargin : 0 }
    private var availableProviders: [String] { CollectionProviderOrder.available(catalogRecords.map(\.provider)) }
    private var filteredRecords: [DownloadRecord] {
        var records = downloadOrder.ordered(catalogRecords)
        if let selectedProviderID {
            records = records.filter { CollectionProviderOrder.key($0.provider) == selectedProviderID }
        }
        if sortBySizeDescending {
            records = DownloadSizeOrder.largestFirst(records)
        } else if sortByProvider {
            records = records.enumerated().sorted { lhs, rhs in
                let a = CollectionProviderOrder.name(CollectionProviderOrder.key(lhs.element.provider))
                let b = CollectionProviderOrder.name(CollectionProviderOrder.key(rhs.element.provider))
                let comparison = a.localizedStandardCompare(b)
                return comparison == .orderedSame ? lhs.offset < rhs.offset : comparison == .orderedAscending
            }.map { $0.element }
        }
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return records }
        // A Set lookup is cheap enough during progress publishes and scrolling;
        // the expensive tag/title matching runs only when search inputs change.
        return records.filter { matchingKeys.contains($0.key) }
    }
    private var collectionSubtitle: String {
        if searching { return "Searching your downloads…" }
        if searchText.isEmpty && selectedProviderID == nil { return "\(catalogRecords.count) downloads, always with you" }
        return "\(filteredRecords.count) of \(catalogRecords.count) downloads"
    }
    private var exportURLs: [URL] {
        catalogRecords.filter { selectedKeys.contains($0.key) }.compactMap(\.exportURL)
    }
    private func refreshCatalog(_ records: [DownloadRecord]) {
        let next = records.map(DownloadSearchIdentity.init)
        guard next != recordIdentity else { return }
        recordIdentity = next
        catalogRecords = records
        downloadOrder.reconcile(records: records)
        let searchable = records.map { "\($0.key)|\($0.provider)|\($0.title)|\($0.tags.joined(separator: ","))" }
        if searchable != searchableIdentity {
            searchableIdentity = searchable
            scheduleSearch(records: records)
        }
        // File sizes, error strings and sort changes must not discard all
        // decoded offline posts. Rebuild only when playable paths change.
        let playable = records.filter { $0.state == .complete }
            .map { "\($0.key)|\($0.localMediaPath ?? "")|\($0.thumbnailLocalPath ?? "")|\($0.mediaType ?? "")" }
        guard playable != offlineMediaIdentity else { return }
        offlineMediaIdentity = playable
        recordRevision &+= 1
        let revision = recordRevision
        cacheTask?.cancel()
        cacheTask = Task { @MainActor in
            let built = await Task.detached(priority: .utility) {
                var posts: [String: Post] = [:]
                for record in records where record.state == .complete {
                    if let post = record.offlinePost { posts[record.key] = post }
                }
                return posts
            }.value
            guard !Task.isCancelled, revision == recordRevision else { return }
            offlinePostCache = built
            offlineCacheReady = true
        }
    }
    private func scheduleSearch(records: [DownloadRecord]) {
        searchTask?.cancel()
        searchRevision &+= 1
        let revision = searchRevision
        let query = searchText
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searching = false
            matchingKeys = []
            return
        }
        searching = true
        searchTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(90)) } catch { return }
            let keys = await Task.detached(priority: .userInitiated) {
                CollectionSearch.matchingDownloadKeys(records, query: query)
            }.value
            guard !Task.isCancelled, revision == searchRevision else { return }
            matchingKeys = keys
            searching = false
        }
    }
    var body: some View {
        ZStack {
                GeometryReader { geometry in
                ScrollViewReader { scrollProxy in
                ScrollView {
                LazyVStack(spacing: 18) {
                    if AppTheme.premium {
                        PremiumPageHeader(title: "Downloads", eyebrow: "QUICKTICK / OFFLINE",
                                          subtitle: collectionSubtitle, icon: "arrow.down.to.line")
                            .padding(.horizontal, AppTheme.contentMargin)
                            .padding(.top, 16)
                            .id("downloads-feed-top")
                    } else {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Saved offline")
                                .font(.system(size: AppTheme.isDeSlopified ? 26 : 30,
                                              weight: AppTheme.isDeSlopified ? .semibold : .bold,
                                              design: AppTheme.isDeSlopified ? .default : .rounded))
                                .tracking(AppTheme.isDeSlopified ? -0.4 : -1)
                            Text(collectionSubtitle)
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
                    .padding(.horizontal, AppTheme.contentMargin)
                    .id("downloads-feed-top")
                    }
                    CollectionSearchField(text: $searchText, placeholder: "Search downloads",
                                          identifier: "downloads-search", isSearching: searching)
                        .padding(.horizontal, AppTheme.contentMargin)
                    HStack(spacing: 10) {
                        Menu {
                            Button("All providers", systemImage: selectedProviderID == nil ? "checkmark" : "square.grid.2x2") {
                                selectedProviderID = nil
                                immersivePostID = nil
                            }
                            ForEach(availableProviders, id: \.self) { id in
                                Button(CollectionProviderOrder.name(id),
                                       systemImage: selectedProviderID == id ? "checkmark" : "square.grid.2x2") {
                                    selectedProviderID = id
                                    immersivePostID = nil
                                }
                            }
                        } label: {
                            Label(selectedProviderID.map(CollectionProviderOrder.name) ?? "All providers",
                                  systemImage: "line.3.horizontal.decrease")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .background(AppTheme.elevatedSurface, in: Capsule())
                                .overlay(Capsule().stroke(AppTheme.border))
                        }
                        .accessibilityIdentifier("downloads-provider-filter")
                        Spacer()
                        if sortBySizeDescending {
                            Text("Largest first").font(.caption).foregroundStyle(AppTheme.secondaryLabel)
                        } else if sortByProvider {
                            Text("Provider A–Z").font(.caption).foregroundStyle(AppTheme.secondaryLabel)
                        }
                    }
                    .padding(.horizontal, AppTheme.contentMargin)
                    // Selection actions stay docked below while cards scroll.
                    if let error = manager.storageError {
                        Text(error).foregroundStyle(.orange)
                            .padding(.horizontal, AppTheme.contentMargin)
                    }
                    if catalogRecords.isEmpty {
                        ContentUnavailableView("No downloads yet", systemImage: "arrow.down.to.line", description: Text("Save posts to view them offline here."))
                            .padding(.horizontal, AppTheme.contentMargin)
                    }
                    else if filteredRecords.isEmpty && !searching {
                        ContentUnavailableView("No matching downloads", systemImage: "magnifyingglass", description: Text("Try another title, tag, or provider."))
                            .padding(.horizontal, AppTheme.contentMargin)
                    }
                    ForEach(filteredRecords) { record in
                        if record.state == .complete {
                            // Transfer progress changes the parent several times a second.
                            // Equatable completed rows keep expensive media/card state
                            // mounted without rebuilding on unrelated progress packets.
                            DownloadCachedCardRow(record: record,
                                                  offlinePost: offlinePostCache[record.key],
                                                  cacheReady: offlineCacheReady,
                                                  available: CGSize(width: max(1, min(AppTheme.feedWidth, geometry.size.width) - cardInset * 2), height: geometry.size.height),
                                                  manager: manager, selecting: selecting,
                                                  selected: selectedKeys.contains(record.key)) {
                                toggleSelection(record.key)
                            }
                            .equatable()
                            .padding(.horizontal, cardInset)
                            .frame(maxWidth: .infinity)
                        } else {
                            DownloadTransferRow(manager: manager, fallback: record,
                                                selecting: selecting, selected: selectedKeys.contains(record.key)) {
                                toggleSelection(record.key)
                            }
                            .padding(.horizontal, AppTheme.contentMargin)
                        }
                    }
                }
                // Match Home: controls retain a readable gutter, while cards
                // occupy the full feed column (up to 680pt on iPad).
                .frame(maxWidth: AppTheme.feedWidth)
                .padding(.vertical, AppTheme.contentMargin)
                .frame(maxWidth: .infinity)
                }
                .onChange(of: scrollToTopRevision) { _, _ in
                    immersive = false
                    immersivePostID = nil
                    withAnimation(.easeOut(duration: 0.22)) {
                        scrollProxy.scrollTo("downloads-feed-top", anchor: .top)
                    }
                }
                }
                }
                .opacity(immersive ? 0 : 1)
                .allowsHitTesting(!immersive)
            if immersive {
                ImmersiveFeedView(posts: localPosts, offline: true, activePostID: $immersivePostID,
                                  onClose: { immersive = false })
                    .transition(.move(edge: .trailing))
            }
        }.scrollContentBackground(.hidden).background(ThemeBackdrop()).navigationTitle("Downloads")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if selecting && !immersive {
                    selectionControls
                        .frame(maxWidth: AppTheme.feedWidth)
                        .padding(.horizontal, AppTheme.contentMargin)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity)
                        .background(AppTheme.chrome)
                        .overlay(alignment: .top) { Rectangle().fill(AppTheme.border).frame(height: 1) }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { rhythm = true } label: { Label("Rhythm", systemImage: "waveform.path") }
                        .disabled(localPosts.isEmpty)
                        .accessibilityIdentifier("downloads-rhythm")
                    Menu {
                        Button("Shuffle downloads", systemImage: "shuffle") {
                            sortBySizeDescending = false
                            sortByProvider = false
                            downloadOrder.shuffle(records: catalogRecords)
                            immersivePostID = nil
                        }
                        Button("Original order", systemImage: "list.bullet") {
                            sortBySizeDescending = false
                            sortByProvider = false
                            downloadOrder.restoreOriginalOrder()
                            immersivePostID = nil
                        }
                        .disabled(!downloadOrder.isShuffled && !sortByProvider && !sortBySizeDescending)
                        Button("Provider A–Z", systemImage: "square.grid.2x2") {
                            downloadOrder.restoreOriginalOrder()
                            sortByProvider = true
                            sortBySizeDescending = false
                            immersivePostID = nil
                        }
                        .disabled(sortByProvider)
                        Button("Largest first", systemImage: "arrow.down.to.line") {
                            downloadOrder.restoreOriginalOrder()
                            sortByProvider = false
                            sortBySizeDescending = true
                            immersivePostID = nil
                        }
                        .disabled(sortBySizeDescending)
                        .accessibilityIdentifier("downloads-sort-largest")
                    } label: {
                        Image(systemName: sortBySizeDescending ? "arrow.down.circle.fill" :
                                            (sortByProvider ? "line.3.horizontal.decrease.circle.fill" :
                                            (downloadOrder.isShuffled ? "shuffle.circle.fill" : "shuffle")))
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .disabled(catalogRecords.isEmpty)
                    .accessibilityLabel("Sort downloads")
                    .accessibilityValue(sortBySizeDescending ? "Largest first" :
                                        (sortByProvider ? "Provider A–Z" :
                                        (downloadOrder.isShuffled ? "Shuffled" : "Original order")))
                    .accessibilityIdentifier("downloads-shuffle")
                    Button(immersive ? "Feed" : "Offline Immersive") { immersive.toggle() }
                        .disabled(!immersive && !localPosts.contains(where: \.isImmersiveMedia))
                    Button(selecting ? "Done" : "Select") {
                        selecting.toggle()
                        if !selecting { selectedKeys.removeAll() }
                    }
                    .disabled(filteredRecords.isEmpty)
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
            .onAppear {
                refreshCatalog(manager.records)
                onImmersiveChange(immersive)
            }
            .onReceive(manager.catalogDidChange) { refreshCatalog(manager.records) }
            .onChange(of: immersive) { _, value in onImmersiveChange(value) }
            .onChange(of: searchText) { _, _ in
                selectedKeys.removeAll()
                scheduleSearch(records: manager.records)
            }
            .onDisappear {
                searchTask?.cancel(); cacheTask?.cancel()
                onImmersiveChange(false)
            }
    }
    private var selectionControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("\(selectedKeys.count) selected")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(selectedKeys.count == filteredRecords.count ? "Clear" : "Select all") {
                    selectedKeys = selectedKeys.count == filteredRecords.count
                        ? [] : Set(filteredRecords.map(\.key))
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
        filteredRecords.compactMap { offlinePostCache[$0.key] }
    }
    private func toggleSelection(_ key: String) {
        if !selectedKeys.insert(key).inserted { selectedKeys.remove(key) }
    }
}

/// Only an active transfer observes byte-level progress, preventing a
/// running background HLS download from invalidating the entire offline feed.
private struct DownloadTransferRow: View {
    @ObservedObject var manager: DownloadManager
    let fallback: DownloadRecord
    let selecting: Bool
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        let record = manager.records.first(where: { $0.key == fallback.key }) ?? fallback
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let path = record.thumbnailLocalPath {
                    CachedMediaImage(url: URL(fileURLWithPath: path).absoluteString, pixels: 216)
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.premium ? 12 : 0))
                } else if AppTheme.premium {
                    Image(systemName: record.kind == .hlsPackage ? "film.stack" : "arrow.down.to.line")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                        .frame(width: 72, height: 72)
                        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        if record.state == .downloading {
                            if AppTheme.premium {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 19, weight: .semibold))
                                    .foregroundStyle(AppTheme.accent)
                            } else {
                                InfinityLoader(size: 27)
                            }
                        }
                        Text(record.title).font(.subheadline.weight(AppTheme.premium ? .bold : .semibold)).lineLimit(2)
                    }
                    Text("\(record.provider) · \(transferStatus(record))")
                        .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
                    Text(record.formattedSize).font(.caption.monospacedDigit())
                    if record.state == .queued {
                        ProgressView().tint(AppTheme.accent)
                            .accessibilityLabel("Resolving the video source")
                    } else {
                        HStack(spacing: 8) {
                            ProgressView(value: max(0, min(1, record.progress))).tint(AppTheme.accent)
                            if AppTheme.premium && (record.state == .downloading || record.state == .paused) {
                                Text("\(Int((record.progress * 100).rounded()))%")
                                    .font(.caption2.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(AppTheme.secondaryLabel)
                            }
                        }
                    }
                    if let error = record.errorMessage {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange).font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack {
                if record.state == .queued {
                    Button("Cancel", systemImage: "xmark.circle") { manager.cancel(record) }
                }
                if record.state == .downloading {
                    Button("Pause") { manager.pause(record) }
                    Button("Cancel") { manager.cancel(record) }
                }
                if record.state == .paused {
                    Button("Resume") { manager.resume(record) }
                    Button("Cancel") { manager.cancel(record) }
                }
                if record.state == .failed || record.state == .cancelled {
                    Button("Retry") { manager.retry(record) }
                }
                Spacer()
                if !selecting {
                    Button("Delete", role: .destructive) { manager.delete(record) }
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(AppTheme.premium ? 16 : 14)
        .background(AppTheme.premium ? AppTheme.surface : AppTheme.elevatedSurface,
                    in: RoundedRectangle(cornerRadius: AppTheme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: AppTheme.cardRadius).stroke(AppTheme.border))
        .overlay {
            if selecting {
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
        .accessibilityIdentifier("download-transfer-\(record.key)")
    }

    private func transferStatus(_ record: DownloadRecord) -> String {
        guard AppTheme.premium else { return record.state.rawValue }
        switch record.state {
        case .queued: return "Preparing video"
        case .downloading: return record.kind == .hlsPackage ? "Saving HLS video" : "Downloading file"
        case .paused: return "Paused"
        case .complete: return "Available offline"
        case .failed: return "Needs attention"
        case .cancelled: return "Cancelled"
        }
    }
}

/// Isolates completed media cards from other downloads' progress publishes.
/// The parent can refresh status labels without recreating decoded images,
/// video surfaces, context menus, and SwiftUI playback observers in each card.
private struct DownloadCachedCardRow: View, Equatable {
    let record: DownloadRecord
    let offlinePost: Post?
    let cacheReady: Bool
    let available: CGSize
    let manager: DownloadManager
    let selecting: Bool
    let selected: Bool
    let onSelect: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.record == rhs.record && lhs.offlinePost == rhs.offlinePost &&
            lhs.cacheReady == rhs.cacheReady && lhs.available == rhs.available &&
            lhs.selecting == rhs.selecting && lhs.selected == rhs.selected
    }

    var body: some View {
        VStack(spacing: 8) {
            if let post = offlinePost {
                HStack {
                    Text(record.formattedSize).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityIdentifier("download-size-\(record.key)")
                    Spacer()
                    if !selecting, let url = record.exportURL {
                        Button { DownloadExporter.share([url]) } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 13).padding(.vertical, 9)
                                .background(AppTheme.elevatedSurface, in: Capsule())
                                .overlay(Capsule().stroke(AppTheme.border))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("export-download-\(record.key)")
                    }
                }
                .padding(.horizontal, AppTheme.contentMargin)
                PostCardView(post: post, available: available, playbackTab: 3, offline: true,
                             onDelete: { manager.delete(record) })
                    .frame(maxWidth: .infinity)
                    .overlay { if selecting { selectionOverlay } }
            } else if !cacheReady {
                ProgressView("Preparing offline preview…")
                    .frame(maxWidth: .infinity, minHeight: 150)
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
