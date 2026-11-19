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

    /// The catalog's first-party poster is available synchronously. Display it
    /// immediately; the old flow held every card blank until a second API call.
    private var catalogCoverURL: String {
        guard let url = URL(string: post.thumbUrl),
              HanimeGeneratedAPI.permittedArtworkURL(url) else { return "" }
        return url.absoluteString
    }

    var body: some View {
        let displayedCover = coverURL.isEmpty ? catalogCoverURL : coverURL
        // Explicit geometry prevents AsyncImage content from spilling across
        // neighboring SwiftUI grid cells and overlapping title cards.
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(AppTheme.gradient)
                if !displayedCover.isEmpty {
                    CachedMediaImage(url: displayedCover,
                                     pixels: height >= 260 ? 768 : 512,
                                     fill: true, hanimeSlug: post.id)
                        .frame(width: geometry.size.width, height: height)
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
            .frame(width: geometry.size.width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1))
        }
        .frame(height: height)
        .task(id: post.id) {
            coverURL = ""
            guard catalogCoverURL.isEmpty else { return }
            let official = await HanimeArtworkCache.shared.posterURL(slug: post.id)
            guard !Task.isCancelled else { return }
            if let url = URL(string: official),
               HanimeGeneratedAPI.permittedArtworkURL(url) {
                coverURL = official
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
                HanimeTitleCover(post: series.poster, height: 350)
                LinearGradient(
                    stops: [.init(color: .black.opacity(0.10), location: 0),
                            .init(color: .black.opacity(0.06), location: 0.30),
                            .init(color: .black.opacity(0.87), location: 0.77),
                            .init(color: .black.opacity(0.96), location: 1)],
                    startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 7) {
                        Image(systemName: "sparkle")
                        Text("FEATURED PREMIERE")
                            .tracking(1.6)
                    }
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.94))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.42), in: Capsule())
                    Spacer(minLength: 0)
                    Text(series.title)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .tracking(-0.65)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .minimumScaleFactor(0.83)
                        .shadow(color: .black.opacity(0.6), radius: 10, y: 3)
                    HStack(spacing: 12) {
                        Label("View episodes", systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 15)
                            .frame(minHeight: 44)
                            .background(AppTheme.accent, in: Capsule())
                            .foregroundStyle(.white)
                        Spacer(minLength: 0)
                        Text(series.episodes.count == 1 ? "1 episode" : "\(series.episodes.count) episodes")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.82))
                    }
                }
                .padding(20)
            }
            .frame(height: 350)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 24))
        }
        .buttonStyle(QuicktickPressStyle())
        .accessibilityIdentifier("hanime-featured-show")
        .accessibilityLabel("Featured: \(series.title), view episodes")
    }
}

private struct HanimeShowPosterCard: View {
    let series: HanimeSeries
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            ZStack(alignment: .bottomLeading) {
                HanimeTitleCover(post: series.poster, height: 254)
                LinearGradient(colors: [.clear, .black.opacity(0.18), .black.opacity(0.88)],
                               startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 7) {
                    Spacer(minLength: 0)
                    Text(series.title)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Label(series.episodes.count == 1 ? "1 episode" : "\(series.episodes.count) episodes",
                          systemImage: "play.rectangle")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.84))
                }
                .padding(13)
            }
            .frame(height: 254)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.13), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(QuicktickPressStyle())
        .accessibilityIdentifier("hanime-show-\(series.id)")
        .accessibilityLabel("\(series.title), \(series.episodes.count) episodes")
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
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("HANIME COLLECTION")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(2.2)
                        .foregroundStyle(AppTheme.accent)
                    Text("Shows")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .tracking(-0.9)
                        .foregroundStyle(.white)
                }
                Spacer()
                Image(systemName: "film.stack")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 48, height: 48)
                    .background(AppTheme.elevatedSurface,
                                in: RoundedRectangle(cornerRadius: 15))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 11) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppTheme.secondaryLabel)
                TextField("Search shows or episodes", text: $search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { activeSearch = search.trimmingCharacters(in: .whitespacesAndNewlines) }
                if !search.isEmpty {
                    Button {
                        search = ""
                        activeSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(AppTheme.secondaryLabel)
                            .frame(width: 38, height: 42)
                    }
                    .accessibilityLabel("Clear show search")
                }
                Button {
                    activeSearch = search.trimmingCharacters(in: .whitespacesAndNewlines)
                } label: {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 13))
                }
                .accessibilityLabel("Search Hanime shows")
            }
            .padding(.leading, 16)
            .padding(.trailing, 5)
            .frame(minHeight: 54)
            .background(AppTheme.elevatedSurface,
                        in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(AppTheme.border))
            if let featured = shows.first {
                HanimeFeaturedShow(series: featured) { selectedSeries = featured }
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Explore the collection")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                Text("\(shows.count) titles")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.secondaryLabel)
            }
            .padding(.top, 4)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 152, maximum: 230), spacing: 14)],
                      alignment: .center, spacing: 14) {
                ForEach(shows.dropFirst()) { series in
                    HanimeShowPosterCard(series: series) { selectedSeries = series }
                }
            }
            if shows.isEmpty && !loading {
                ContentUnavailableView("No shows found", systemImage: "film.stack",
                    description: Text("Try a different title or discover more shows."))
            }
            if loading {
                ProgressView("Loading the collection")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(AppTheme.secondaryLabel)
            }
            if hasMore && !loading {
                Button {
                    Task { await loadNextPage() }
                } label: {
                    Label("Discover more shows", systemImage: "rectangle.stack.badge.plus")
                        .font(.subheadline.weight(.semibold))
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
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
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
            if nextPage == 1 {
                // Only prime a few immediately visible, real title posters.
                // This runs off the scrolling path using the shared image cache.
                let posters = Array(result.items.prefix(5)).compactMap { post -> String? in
                    guard let url = URL(string: post.thumbUrl),
                          HanimeGeneratedAPI.permittedArtworkURL(url) else { return nil }
                    return url.absoluteString
                }
                Task(priority: .utility) {
                    for poster in posters {
                        if Task.isCancelled { return }
                        _ = try? await MediaImagePipeline.shared.image(raw: poster, pixels: 512)
                    }
                }
            }
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
    @State private var additionalEpisodes: [Post] = []
    @State private var discovering = false
    @State private var playingEpisode: Post?
    @State private var playingOffline = false
    @State private var activeEpisodeID: String?

    /// Catalog pages can contain "Show 1" but not "Show 2". Once this sheet
    /// is actually opened, search the shared base title (not "Show 1") and
    /// merge matching releases into one episode list without fake episodes.
    private var currentSeries: HanimeSeries {
        HanimeSeries.group(series.episodes + additionalEpisodes).first {
            $0.episodes.contains(where: { $0.stableID == series.poster.stableID })
        } ?? series
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ZStack(alignment: .bottomLeading) {
                        HanimeTitleCover(post: currentSeries.poster, height: 240)
                        LinearGradient(colors: [.clear, .black.opacity(0.30),
                                                .black.opacity(0.93)],
                                       startPoint: .center, endPoint: .bottom)
                        VStack(alignment: .leading, spacing: 9) {
                            Spacer(minLength: 0)
                            Text(currentSeries.title)
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                                .lineLimit(3)
                                .foregroundStyle(.white)
                            HStack(spacing: 8) {
                                Label(currentSeries.episodes.count == 1
                                      ? "1 episode" : "\(currentSeries.episodes.count) episodes",
                                      systemImage: "play.rectangle")
                                if discovering { ProgressView().controlSize(.small) }
                            }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.86))
                        }
                        .padding(18)
                    }
                    .frame(height: 240)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowSeparator(.hidden)
                }
                .listRowBackground(Color.clear)
                Section {
                    ForEach(currentSeries.episodes.indices, id: \.self) { index in
                        episodeRow(currentSeries.episodes[index], number: index + 1)
                    }
                } header: {
                    Text("Episodes").textCase(nil)
                } footer: {
                    Text("Saved episodes play from this device without a network connection.")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
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
            .task(id: series.id) { await findRelatedEpisodes() }
        }
    }

    @MainActor private func findRelatedEpisodes() async {
        let title = HanimeSeries.lookupTitle(for: series.poster)
        guard title.count >= 3, !discovering else { return }
        discovering = true
        defer { discovering = false }
        var seen = Set(series.episodes.map(\.stableID))
        // Fetch only after opening a title, and cap lookup pages to protect
        // network time and the first-frame performance of Instant mode.
        for page in 1...4 {
            do {
                let response = try await store.api.posts(
                    provider: .hanime, query: QueryParser.parse(title),
                    page: page, sort: "popular")
                try Task.checkCancellation()
                for post in response.items where post.providerKey == .hanime {
                    if seen.insert(post.stableID).inserted { additionalEpisodes.append(post) }
                }
                guard response.hasMore == true, !response.items.isEmpty else { break }
            } catch is CancellationError {
                return
            } catch {
                // Keep already indexed episodes usable when the remote
                // provider refuses a wider search or page fetch.
                break
            }
        }
    }

    private func episodeRow(_ episode: Post, number: Int) -> some View {
        let record = downloads.records.first { $0.key == episode.stableID }
        let saved = record?.offlinePost
        let busy = record?.state == .downloading || record?.state == .queued
        let failure = record?.state == .failed ? record?.errorMessage : nil

        return VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 16) {
                HanimeTitleCover(post: episode, height: 105)
                    .frame(width: 82)
                VStack(alignment: .leading, spacing: 9) {
                    Text(HanimeSeries.episodeNumber(episode.caption ?? "").map {
                        "Episode \($0)"
                    } ?? "Episode \(number)")
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .tracking(1.3)
                        .foregroundStyle(AppTheme.accent)
                    Text(episode.displayTitle ?? currentSeries.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let record, busy {
                        ProgressView(value: max(0, min(1, record.progress)))
                            .tint(AppTheme.accent)
                            .accessibilityLabel("Downloading full video")
                    } else if saved != nil {
                        Label("Available offline", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AppTheme.accent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
            HStack(spacing: 12) {
                Button {
                    let target = saved ?? episode
                    playingOffline = saved != nil
                    activeEpisodeID = target.stableID
                    playingEpisode = target
                } label: {
                    Label(saved == nil ? "Play episode" : "Play offline",
                          systemImage: "play.fill")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                .accessibilityIdentifier("hanime-play-\(episode.id)")

                Button {
                    if let record, [.failed, .cancelled, .complete].contains(record.state) {
                        // Repair a legacy completion that has no actual offline video.
                        downloads.retry(record)
                    } else if !busy && saved == nil {
                        downloads.download(episode)
                    }
                } label: {
                    Label(saved != nil ? "Saved" :
                          busy ? "Saving…" :
                          record?.state == .complete ? "Repair download" :
                          record?.state == .failed ? "Retry save" : "Download",
                          systemImage: saved != nil ? "checkmark.circle.fill" :
                          busy ? "arrow.down.circle.dotted" : "arrow.down.to.line")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.bordered)
                .disabled(busy || saved != nil)
                .accessibilityIdentifier("hanime-download-\(episode.id)")
                .accessibilityLabel(saved != nil ? "Downloaded full episode" :
                                    busy ? "Downloading full video" : "Download full episode")
            }
            if let failure, !failure.isEmpty {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowBackground(AppTheme.elevatedSurface)
        .listRowSeparator(.hidden)
    }
}
