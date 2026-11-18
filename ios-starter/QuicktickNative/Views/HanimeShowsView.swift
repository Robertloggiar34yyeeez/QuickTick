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

/// First-party title cover: never draw an embedded video preview as the
/// cover of a show. The visible title performs one coalesced metadata lookup.
private struct HanimeTitleCover: View {
    let post: Post
    var height: CGFloat = 220
    @State private var coverURL = ""

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(AppTheme.gradient)
            if !coverURL.isEmpty {
                CachedMediaImage(url: coverURL, pixels: 740, fill: true,
                                 hanimeSlug: post.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "play.rectangle.on.rectangle.fill")
                        .font(.system(size: 42, weight: .ultraLight))
                    Text("TITLE ARTWORK")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(2.1)
                }
                .foregroundStyle(.white.opacity(0.56))
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .task(id: post.id) {
            coverURL = ""
            let official = await HanimeArtworkCache.shared.posterURL(slug: post.id)
            guard !Task.isCancelled else { return }
            // Title detail poster is the authority. Never fall back to a
            // cardPreviewURL that might be the video player screenshot.
            if let url = URL(string: official),
               HanimeGeneratedAPI.permittedArtworkURL(url) {
                coverURL = official
            } else if let backup = URL(string: post.thumbUrl),
                      HanimeGeneratedAPI.permittedArtworkURL(backup),
                      backup.path.lowercased().contains("/images/") {
                // Catalog artwork is a fallback only when marked as artwork.
                coverURL = backup.absoluteString
            }
        }
    }
}

private struct HanimeFeaturedShow: View {
    let series: HanimeSeries
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            ZStack(alignment: .bottomLeading) {
                HanimeTitleCover(post: series.poster, height: 280)
                LinearGradient(colors: [.clear, .black.opacity(0.42), .black.opacity(0.95)],
                               startPoint: .center, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                VStack(alignment: .leading, spacing: 9) {
                    Text("FEATURED SHOW")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .tracking(2.2)
                        .foregroundStyle(.white.opacity(0.84))
                    Text(series.title)
                        .font(.system(size: 29, weight: .heavy, design: .rounded))
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(.white)
                    HStack(spacing: 10) {
                        Image(systemName: "play.fill")
                        Text("Explore episodes")
                        Spacer(minLength: 4)
                        Text("\(series.episodes.count) found")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                }
                .padding(22)
            }
            .frame(height: 280)
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(QuicktickPressStyle())
        .accessibilityIdentifier("hanime-featured-show")
    }
}

private struct HanimeShowPosterCard: View {
    let series: HanimeSeries
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                HanimeTitleCover(post: series.poster, height: 210)
                Text(series.title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .frame(height: 39, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    Image(systemName: "play.rectangle")
                    Text(series.episodes.count == 1 ? "1 episode" : "\(series.episodes.count) episodes")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.secondaryLabel)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(QuicktickPressStyle())
        .accessibilityIdentifier("hanime-show-\(series.id)")
    }
}

/// Two explicit experiences: Instant keeps QuickTick's existing feed,
/// Shows displays official title artwork and selectable episodes.
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
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("HANIME  /  SHOWS")
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .tracking(2.5).foregroundStyle(AppTheme.accent)
                Text("Explore stories")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Original title artwork. Choose an episode to watch or save.")
                    .font(.subheadline).foregroundStyle(AppTheme.secondaryLabel)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppTheme.secondaryLabel)
                TextField("Search titles and episodes", text: $search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { activeSearch = search.trimmingCharacters(in: .whitespacesAndNewlines) }
                Button {
                    activeSearch = search.trimmingCharacters(in: .whitespacesAndNewlines)
                } label: {
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(AppTheme.accent.opacity(0.28), in: RoundedRectangle(cornerRadius: 13))
                }
                .accessibilityLabel("Search Hanime shows")
            }
            .padding(.leading, 14)
            .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 16))
            if let featured = shows.first {
                HanimeFeaturedShow(series: featured) { selectedSeries = featured }
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Browse titles")
                    .font(.title3.weight(.bold)).foregroundStyle(.white)
                Spacer()
                Text("\(shows.count) available")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.secondaryLabel)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 14)],
                      alignment: .center, spacing: 20) {
                ForEach(shows.dropFirst()) { series in
                    HanimeShowPosterCard(series: series) { selectedSeries = series }
                }
            }
            if shows.isEmpty && !loading {
                ContentUnavailableView("No shows found", systemImage: "film.stack",
                    description: Text("Try a different title or load more of the catalog."))
            }
            if loading {
                ProgressView("Loading the catalog")
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
            }
            if let failure {
                Text(failure)
                    .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
            }
            if hasMore && !loading {
                Button {
                    Task { await loadNextPage() }
                } label: {
                    Label("Discover more shows", systemImage: "rectangle.stack.badge.plus")
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("hanime-shows-load-more")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            failure = "Couldn't load shows: \(error.localizedDescription)"
        }
    }
}

private struct HanimeEpisodePicker: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let series: HanimeSeries
    @ObservedObject var downloads: DownloadManager
    @State private var playingEpisode: Post?
    @State private var playingOffline = false
    @State private var activeEpisodeID: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    HanimeTitleCover(post: series.poster, height: 280)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(series.title)
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                        Text("Select an episode to play or download the full video.")
                            .font(.subheadline).foregroundStyle(AppTheme.secondaryLabel)
                        Label("\(series.episodes.count) episodes found",
                              systemImage: "play.rectangle.on.rectangle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.accent)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(series.episodes.indices, id: \.self) { index in
                        episodeRow(series.episodes[index], number: index + 1)
                    }
                }
                .padding(18)
                .frame(maxWidth: 700, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(ThemeBackdrop())
            .navigationTitle("Episodes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .fullScreenCover(item: $playingEpisode) { episode in
                ImmersiveFeedView(posts: [episode], offline: playingOffline,
                                  activePostID: $activeEpisodeID,
                                  onClose: { playingEpisode = nil })
                    .environmentObject(store)
                    .ignoresSafeArea()
            }
        }
    }

    private func episodeRow(_ episode: Post, number: Int) -> some View {
        let record = downloads.records.first { $0.key == episode.stableID }
        let saved = record?.offlinePost
        let busy = record?.state == .downloading || record?.state == .queued
        return HStack(alignment: .center, spacing: 12) {
            HanimeTitleCover(post: episode, height: 106)
                .frame(width: 94).clipped()
            VStack(alignment: .leading, spacing: 7) {
                Text(HanimeSeries.episodeNumber(episode.caption ?? "").map { "Episode \($0)" }
                     ?? "Episode \(number)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                Text(episode.displayTitle ?? series.title)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryLabel)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    let target = saved ?? episode
                    playingOffline = saved != nil
                    activeEpisodeID = target.stableID
                    playingEpisode = target
                } label: {
                    Label(saved == nil ? "Play" : "Play offline", systemImage: "play.fill")
                        .font(.caption.weight(.bold))
                        .frame(minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
            }
            Spacer(minLength: 0)
            Button {
                if let record, record.state == .failed || record.state == .cancelled {
                    downloads.retry(record)
                } else if !busy && saved == nil {
                    downloads.download(episode)
                }
            } label: {
                Image(systemName: saved != nil ? "checkmark.circle.fill" :
                      busy ? "arrow.down.circle.dotted" : "arrow.down.circle")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(saved != nil ? AppTheme.accent : .white)
                    .frame(width: 48, height: 48)
            }
            .disabled(busy || saved != nil)
            .accessibilityLabel(saved != nil ? "Downloaded video" :
                                busy ? "Downloading video" :
                                record?.state == .failed ? "Retry full video download" : "Download full episode")
        }
        .padding(11)
        .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(AppTheme.border))
    }
}
