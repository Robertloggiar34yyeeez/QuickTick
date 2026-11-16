import SwiftUI

/// A catalog entry is grouped only when its title explicitly identifies an
/// episode/part. Unrelated standalone titles never become a fake series.
struct HanimeSeries: Identifiable, Hashable {
    let id: String
    let title: String
    let episodes: [Post]
    let poster: Post

    private static let episodePattern =
        #"(?i)(?:[\s:–—-]+|^)(?:episode|ep\.?|part|chapter)\s*#?\s*(\d{1,3})(?:\s*[-–:]\s*.*)?$"#

    static func episodeNumber(_ title: String) -> Int? {
        guard let expression = try? NSRegularExpression(pattern: episodePattern),
              let match = expression.firstMatch(in: title,
                  range: NSRange(title.startIndex..., in: title)),
              let range = Range(match.range(at: 1), in: title) else { return nil }
        return Int(title[range])
    }

    static func showTitle(_ post: Post) -> String {
        let original = (post.caption ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = post.id.replacingOccurrences(of: "-", with: " ").capitalized
        guard !original.isEmpty else { return fallback }
        let base = original.replacingOccurrences(of: episodePattern, with: "",
                                                 options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -:–—"))
        return base.isEmpty ? original : base
    }

    static func group(_ posts: [Post]) -> [HanimeSeries] {
        var groups: [String: [Post]] = [:]
        var titles: [String: String] = [:]
        var used = Set<String>()
        for post in posts where post.providerKey == .hanime {
            guard used.insert(post.stableID).inserted else { continue }
            let name = showTitle(post)
            let key = name.lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            groups[key, default: []].append(post)
            if titles[key] == nil { titles[key] = name }
        }
        return groups.compactMap { key, posts -> HanimeSeries? in
            guard let poster = posts.first(where: { !$0.cardPreviewURL.isEmpty })
                ?? posts.first else { return nil }
            let episodes = posts.sorted {
                let left = episodeNumber($0.caption ?? "") ?? Int.max
                let right = episodeNumber($1.caption ?? "") ?? Int.max
                return left == right ? $0.stableID < $1.stableID : left < right
            }
            return HanimeSeries(id: key, title: titles[key] ?? key,
                                episodes: episodes, poster: poster)
        }.sorted { left, right in
            let leftScore = left.episodes.reduce(0.0) { $0 + $1.score }
            let rightScore = right.episodes.reduce(0.0) { $0 + $1.score }
            return leftScore == rightScore
                ? left.title.localizedStandardCompare(right.title) == .orderedAscending
                : leftScore > rightScore
        }
    }
}

/// Netflix-style alternative to QuickTick's existing instant video feed.
/// Only mounted when Shows is selected; no players or episode detail requests
/// run in the background while browsing the ordinary feed.
struct HanimeShowsView: View {
    @EnvironmentObject private var store: AppStore
    let seedPosts: [Post]
    let initialQuery: String
    @State private var catalog: [Post] = []
    @State private var search = ""
    @State private var activeSearch = ""
    @State private var nextPage = 1
    @State private var hasMore = true
    @State private var loading = false
    @State private var failure: String?
    @State private var selectedSeries: HanimeSeries?

    private var shows: [HanimeSeries] {
        let candidates = catalog + seedPosts.filter { $0.providerKey == .hanime }
        let all = HanimeSeries.group(candidates)
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty ? all : all.filter {
            $0.title.localizedCaseInsensitiveContains(needle) ||
                $0.episodes.contains { $0.caption?.localizedCaseInsensitiveContains(needle) == true }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Explore shows").font(.title2.weight(.bold))
                Text("Choose a title, then play or save an episode.")
                    .font(.subheadline).foregroundStyle(AppTheme.secondaryLabel)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(AppTheme.secondaryLabel)
                TextField("Find a show", text: $search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { activeSearch = search.trimmingCharacters(in: .whitespacesAndNewlines) }
                Button {
                    activeSearch = search.trimmingCharacters(in: .whitespacesAndNewlines)
                } label: {
                    Image(systemName: "arrow.right")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Search Hanime catalog")
            }
            .padding(.leading, 14)
            .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 14))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 152), spacing: 12)], spacing: 18) {
                ForEach(shows) { series in
                    Button { selectedSeries = series } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            PosterView(post: series.poster)
                                .frame(height: 210).frame(maxWidth: .infinity)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 15))
                            Text(series.title)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white).lineLimit(2)
                            Text(series.episodes.count == 1 ? "1 episode found" :
                                    "\(series.episodes.count) episodes found")
                                .font(.caption2).foregroundStyle(AppTheme.secondaryLabel)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(QuicktickPressStyle())
                    .accessibilityIdentifier("hanime-show-\(series.id)")
                }
            }
            if loading {
                ProgressView("Loading Hanime catalog").frame(maxWidth: .infinity).padding()
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(AppTheme.secondaryLabel)
            }
            if hasMore && !loading {
                Button {
                    Task { await loadNextPage() }
                } label: {
                    Label("Load more shows", systemImage: "rectangle.stack.badge.plus")
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("hanime-shows-load-more")
            }
        }
        .sheet(item: $selectedSeries) { series in
            HanimeEpisodePicker(series: series, downloads: store.downloads)
                .environmentObject(store)
        }
        .task(id: "\(initialQuery):\(activeSearch)") {
            catalog = []
            nextPage = 1
            hasMore = true
            failure = nil
            await loadNextPage()
        }
        .accessibilityIdentifier("hanime-shows-catalog")
    }

    @MainActor private func loadNextPage() async {
        guard !loading, hasMore, store.selectedProvider == .hanime else { return }
        loading = true
        defer { loading = false }
        let term = activeSearch.isEmpty ? initialQuery : activeSearch
        do {
            let result = try await store.api.posts(provider: .hanime,
                 query: QueryParser.parse(term), page: nextPage, sort: "popular")
            try Task.checkCancellation()
            let existing = Set(catalog.map(\.stableID))
            catalog.append(contentsOf: result.items.filter { !existing.contains($0.stableID) })
            hasMore = (result.hasMore ?? false) && nextPage < 40 && !result.items.isEmpty
            nextPage += 1
            failure = nil
        } catch is CancellationError {
        } catch {
            failure = "Couldn't load more shows: \(error.localizedDescription)"
        }
    }
}

private struct HanimeEpisodePicker: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let series: HanimeSeries
    @ObservedObject var downloads: DownloadManager
    @State private var playingEpisode: Post?
    @State private var activeEpisodeID: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    PosterView(post: series.poster)
                        .frame(height: 260).frame(maxWidth: .infinity)
                        .clipped().clipShape(RoundedRectangle(cornerRadius: 18))
                    Text(series.title).font(.title2.weight(.bold))
                    Text("Episodes found in the current catalog. Load more shows to discover additional episodes.")
                        .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
                    ForEach(series.episodes.indices, id: \.self) { index in
                        let episode = series.episodes[index]
                        let record = downloads.records.first { $0.key == episode.stableID }
                        HStack(spacing: 12) {
                            PosterView(post: episode)
                                .frame(width: 82, height: 92)
                                .clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 7) {
                                Text(HanimeSeries.episodeNumber(episode.caption ?? "").map {
                                    "Episode \($0)"
                                } ?? "Episode \(index + 1)")
                                    .font(.headline)
                                Text(episode.displayTitle ?? series.title)
                                    .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
                                    .lineLimit(2)
                                Button {
                                    activeEpisodeID = episode.stableID
                                    playingEpisode = episode
                                } label: {
                                    Label("Play", systemImage: "play.fill")
                                        .frame(minHeight: 40)
                                }.buttonStyle(.borderedProminent)
                            }
                            Spacer(minLength: 0)
                            Button {
                                if let record, record.state == .failed || record.state == .cancelled {
                                    downloads.retry(record)
                                } else if record?.state != .complete {
                                    downloads.download(episode)
                                }
                            } label: {
                                Image(systemName: record?.state == .complete ? "checkmark.circle.fill" :
                                    record?.state == .downloading || record?.state == .queued ?
                                    "arrow.down.circle.dotted" : "arrow.down.circle")
                                    .font(.system(size: 24))
                                    .frame(width: 48, height: 48)
                            }
                            .disabled(record?.state == .complete ||
                                      record?.state == .downloading || record?.state == .queued)
                            .accessibilityLabel(record?.state == .complete ? "Downloaded" :
                                record?.state == .failed ? "Retry download" : "Download episode")
                        }
                        .padding(10)
                        .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 14))
                    }
                }.padding(16)
            }
            .background(ThemeBackdrop())
            .navigationTitle(series.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .fullScreenCover(item: $playingEpisode) { episode in
                ImmersiveFeedView(posts: [episode], offline: false,
                                  activePostID: $activeEpisodeID,
                                  onClose: { playingEpisode = nil })
                    .environmentObject(store).ignoresSafeArea()
            }
        }
    }
}
