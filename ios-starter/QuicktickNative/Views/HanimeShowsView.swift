import SwiftUI

/// Normalize numbered releases into a single show, even when the provider
/// names them "Show Title 1", "Show Title 2" rather than "Episode 1/2".
/// An isolated numbered title is preserved verbatim instead of being assumed
/// to be part of an imaginary series.
struct HanimeSeries: Identifiable, Hashable {
    let id: String
    let title: String
    let episodes: [Post]
    let poster: Post

    private struct NumberedTitle {
        let base: String
        let number: Int
        let explicit: Bool
    }
    private struct Entry {
        let post: Post
        let name: String
        let numbered: NumberedTitle?
        let familyKey: String
    }
    private static let explicitEpisodePattern =
        #"(?i)(?:[\s:–—-]+|^)(?:episode|ep\.?|part|chapter)\s*#?\s*(\d{1,3})(?:\s*[-–:]\s*.*)?$"#
    private static let numberedSuffixPattern = #"^(.+?)[\s:–—-]+(\d{1,3})$"#

    private static func displayName(_ post: Post) -> String {
        let title = (post.caption ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? post.id.replacingOccurrences(of: "-", with: " ").capitalized : title
    }

    private static func numbered(_ raw: String) -> NumberedTitle? {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let expression = try? NSRegularExpression(pattern: explicitEpisodePattern),
           let match = expression.firstMatch(in: title,
               range: NSRange(title.startIndex..., in: title)),
           let episodeRange = Range(match.range(at: 1), in: title),
           let number = Int(title[episodeRange]) {
            let base = title.replacingOccurrences(of: explicitEpisodePattern, with: "",
                options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " -:–—"))
            if !base.isEmpty { return NumberedTitle(base: base, number: number, explicit: true) }
        }
        guard let expression = try? NSRegularExpression(pattern: numberedSuffixPattern),
              let match = expression.firstMatch(in: title,
                  range: NSRange(title.startIndex..., in: title)),
              let nameRange = Range(match.range(at: 1), in: title),
              let episodeRange = Range(match.range(at: 2), in: title),
              let episode = Int(title[episodeRange]) else { return nil }
        let base = String(title[nameRange]).trimmingCharacters(in: CharacterSet(charactersIn: " -:–—"))
        // Four-digit years and one-word numbers are not episode families.
        guard base.count >= 3, base.rangeOfCharacter(from: .letters) != nil else { return nil }
        return NumberedTitle(base: base, number: episode, explicit: false)
    }

    private static func familyKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: #"[\s_–—-]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func episodeNumber(_ title: String) -> Int? { numbered(title)?.number }

    /// Used for on-demand discovery when the current catalog contains only
    /// one of the numbered episodes. Never search the full unique title.
    static func lookupTitle(for post: Post) -> String {
        let name = displayName(post)
        return numbered(name)?.base ?? name
    }

    static func showTitle(_ post: Post) -> String {
        let name = displayName(post)
        let candidate = numbered(name)
        return candidate?.explicit == true ? candidate!.base : name
    }

    static func group(_ posts: [Post]) -> [HanimeSeries] {
        var seen = Set<String>()
        let entries = posts.compactMap { post -> Entry? in
            guard post.providerKey == .hanime, seen.insert(post.stableID).inserted else { return nil }
            let name = displayName(post)
            let parsed = numbered(name)
            let key = familyKey(parsed?.base ?? name)
            guard !key.isEmpty else { return nil }
            return Entry(post: post, name: name, numbered: parsed, familyKey: key)
        }
        var numbers: [String: Set<Int>] = [:]
        for entry in entries {
            if let parsed = entry.numbered {
                numbers[entry.familyKey, default: []].insert(parsed.number)
            }
        }
        var groups: [String: [Post]] = [:]
        var titles: [String: String] = [:]
        for entry in entries {
            let parsed = entry.numbered
            // A shared suffix (1, 2, ...) is meaningful only with at least
            // two distinct episode numbers; explicit "Episode" markers always
            // identify a series, including a single indexed episode.
            let grouped = parsed == nil || parsed?.explicit == true ||
                (numbers[entry.familyKey]?.count ?? 0) >= 2
            let key = grouped ? "series:" + entry.familyKey : "single:" + entry.post.stableID
            groups[key, default: []].append(entry.post)
            if titles[key] == nil {
                titles[key] = grouped ? (parsed?.base ?? entry.name) : entry.name
            }
        }
        return groups.compactMap { key, items -> HanimeSeries? in
            let poster = items.first {
                guard let url = URL(string: $0.thumbUrl) else { return false }
                return HanimeGeneratedAPI.permittedArtworkURL(url)
            } ?? items.first!
            let episodes = items.sorted { lhs, rhs in
                let left = numbered(displayName(lhs))?.number ?? Int.max
                let right = numbered(displayName(rhs))?.number ?? Int.max
                return left == right ? lhs.stableID < rhs.stableID : left < right
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
