import SwiftUI
import SafariServices
import AVFoundation

struct CommentsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let post: Post
    @State private var page: CommentPage?
    @State private var error: String?
    @State private var writeInApp = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 35, height: 35)
                        .background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Comments")
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                        if let page, page.available {
                            Text("\(page.items.count) replies")
                                .font(.caption)
                                .foregroundStyle(AppTheme.secondaryLabel)
                        }
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppTheme.secondaryLabel)
                            .frame(width: 32, height: 32)
                            .background(AppTheme.elevatedSurface, in: Circle())
                    }
                    .accessibilityLabel("Close comments")
                }
                .padding(.horizontal, 19)
                .padding(.top, 21)
                .padding(.bottom, 12)

                Rectangle().fill(AppTheme.border).frame(height: 1)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if let error {
                            statusView(icon: "wifi.exclamationmark", title: "Comments unavailable", detail: error)
                        } else if let page {
                            if !page.available {
                                statusView(icon: "bubble.left", title: "Comments unavailable",
                                           detail: page.message ?? "This source does not provide comments.")
                            } else if page.items.isEmpty {
                                statusView(icon: "bubble.left", title: "No comments yet",
                                           detail: "There are no comments to show.")
                            }
                            ForEach(page.items) { comment in
                                HStack(alignment: .top, spacing: 11) {
                                    Text(String(comment.author.prefix(1)).uppercased())
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                        .foregroundStyle(AppTheme.accent)
                                        .frame(width: 35, height: 35)
                                        .background(AppTheme.accent.opacity(0.12), in: Circle())
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                                            Text(comment.author.isEmpty ? "Anonymous" : comment.author)
                                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                                .lineLimit(1)
                                            Spacer(minLength: 5)
                                            Text(comment.createdAt)
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundStyle(AppTheme.secondaryLabel)
                                                .lineLimit(1)
                                        }
                                        Text(comment.body)
                                            .font(.system(size: 14))
                                            .foregroundStyle(.white.opacity(0.9))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(13)
                                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 17).stroke(AppTheme.border, lineWidth: 1))
                            }
                        } else {
                            HStack(spacing: 12) {
                                ProgressView().tint(AppTheme.accent)
                                Text("Loading comments…")
                                    .font(.subheadline)
                                    .foregroundStyle(AppTheme.secondaryLabel)
                            }
                            .frame(maxWidth: .infinity, minHeight: 130)
                        }
                    }
                    .frame(maxWidth: 650)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                }
                .scrollIndicators(.hidden)
                // Only Rule34 comments are intended as public source-site
                // replies. Its documented DAPI offers read-only comments;
                // publishing still requires Rule34's authenticated form.
                if post.providerKey == .rule34,
                   let source = URL(string: post.pageUrl), source.scheme == "https",
                   Provider.identifyPage(post.pageUrl) == .rule34 {
                    Button { writeInApp = true } label: {
                        Label("Write a public Rule34 comment", systemImage: "square.and.pencil")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                    Text("Uses Rule34's own sign-in and posting form inside QuickTick. The public comments API does not support submitting replies.")
                        .font(.caption2).foregroundStyle(AppTheme.secondaryLabel)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)
                    .sheet(isPresented: $writeInApp) { SourceWebsiteView(url: source).ignoresSafeArea() }
                }
            }
            .background(ThemeBackdrop())
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.fraction(0.38), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .presentationBackground(AppTheme.canvas)
        .task {
            do { page = try await store.api.comments(post) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func statusView(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 25, weight: .light))
                .foregroundStyle(AppTheme.accent)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(AppTheme.secondaryLabel)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .padding(22)
    }
}

/// The provider handles its own sign-in and comment submission. Safari's
/// in-app controller supports the provider's real web forms and cookie flows;
/// QuickTick does not store passwords or synthesize successful submissions.
struct SourceWebsiteView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let settings = SFSafariViewController.Configuration()
        settings.entersReaderIfAvailable = false
        let browser = SFSafariViewController(url: url, configuration: settings)
        browser.dismissButtonStyle = .close
        return browser
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) { }
}

struct TasteOnboardingView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var into = Set<String>()
    @State private var notInto = Set<String>()
    @State private var suggestedTags: [String] = []
    @State private var wdSuggestedTags = Set<String>()
    @State private var artistDraft = ""
    @State private var creditedArtists: [String] = []
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .center, spacing: 15) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 23, weight: .semibold))
                            .frame(width: 58, height: 58)
                            .background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: 19))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Make QuickTick yours")
                                .font(.system(size: 27, weight: .bold, design: .rounded))
                            Text("Fine-tune what you love, without resetting what QuickTick has learned.")
                                .font(.subheadline).foregroundStyle(AppTheme.secondaryLabel)
                        }
                    }
                    .padding(.bottom, 4)
                    Label("Tuning \(store.selectedProvider.displayName)", systemImage: "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(AppTheme.accent.opacity(0.13), in: Capsule())
                    TasteTagSection(preferred: true, selected: $into, opposite: $notInto,
                                    candidates: suggestedTags, provider: store.selectedProvider,
                                    wdCandidates: wdSuggestedTags)
                    artistPreferences
                    TasteTagSection(preferred: false, selected: $notInto, opposite: $into,
                                    candidates: suggestedTags, provider: store.selectedProvider,
                                    wdCandidates: wdSuggestedTags)
                    Label("Suggestions come from this source's own catalog and on-device visual learning. Your history remains private on this device.",
                          systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
                        .padding(.horizontal, 4)
                }
                .frame(maxWidth: 740).frame(maxWidth: .infinity)
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(ThemeBackdrop())
            .navigationTitle("Your interests")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.setTaste(into: into.sorted(), notInto: notInto.sorted(), artists: creditedArtists)
                        dismiss()
                    }
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("save-taste")
                }
            }
        }
        .presentationBackground(AppTheme.canvas)
        .onAppear {
            let taste = store.tasteChoice(for: store.selectedProvider)
            into = Set(taste.into); notInto = Set(taste.notInto)
            creditedArtists = taste.artists
            suggestedTags = TasteTagSuggestions.rank(learned: store.learnedInterests,
                favorites: Array(store.favorites.values.prefix(250)), posts: Array(store.posts.prefix(80)),
                provider: store.selectedProvider)
        }
        .task(id: store.selectedProvider) { await loadProviderInterests() }
    }

    @MainActor private func loadProviderInterests() async {
        let provider = store.selectedProvider
        let visualTags = await store.visual.discoveryTerms(provider: provider)
        let catalogPosts: [Post]
        if provider == .hanime {
            // Immersive may currently be empty even though the first-party
            // Hanime catalog contains usable categories and genres.
            let page = try? await store.api.posts(provider: .hanime,
                query: ParsedQuery(included: [], excluded: []),
                page: 1, sort: "popular")
            catalogPosts = page?.items ?? []
        } else { catalogPosts = [] }
        let niches: [RedgifsNiche]
        if provider == .redgifs {
            niches = (try? await store.api.redgifsNiches(limit: 24)) ?? []
        } else { niches = [] }
        guard !Task.isCancelled, store.selectedProvider == provider else { return }
        wdSuggestedTags = provider == .hanime ? Set(visualTags) : []
        suggestedTags = TasteTagSuggestions.rank(
            learned: store.learnedInterests,
            favorites: Array(store.favorites.values.prefix(250)),
            posts: Array(store.posts.prefix(80)) + catalogPosts, provider: provider,
            visual: visualTags, niches: niches)
    }

    private var artistPreferences: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("Artists & creators", systemImage: "paintbrush.pointed.fill")
                .font(.headline)
            Text("Enter credited artists you like. QuickTick compares their saved posts for recurring poses, actions and styles, while still exploring new creators.")
                .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
            HStack(spacing: 8) {
                TextField("Artist or creator name", text: $artistDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(addArtist)
                    .accessibilityIdentifier("taste-artist-input")
                Button("Add", action: addArtist)
                    .disabled(artistDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .buttonStyle(.borderedProminent)
            }
            if !creditedArtists.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(creditedArtists, id: \.self) { artist in
                            Button { creditedArtists.removeAll { $0 == artist } } label: {
                                Label(artist.replacingOccurrences(of: "_", with: " "), systemImage: "xmark.circle.fill")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 11).padding(.vertical, 9)
                                    .background(AppTheme.accent.opacity(0.16), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove artist \(artist)")
                        }
                    }
                }
                Text(artistInsight)
                    .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
            }
        }
        .padding(14)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private func addArtist() {
        let name = TasteConcepts.canonical(artistDraft)
        guard !name.isEmpty, name.count <= 80, !creditedArtists.contains(name) else { return }
        creditedArtists.append(name)
        artistDraft = ""
    }

    private var artistInsight: String {
        let selected = Set(creditedArtists)
        let matches = store.favorites.values.filter { post in
            post.providerKey == store.selectedProvider &&
            !Set(ArtistAttribution.credited(in: post)).isDisjoint(with: selected)
        }
        guard !matches.isEmpty else {
            return "No saved likes from these credited artists yet. Their posts will help QuickTick learn the overlap."
        }
        var counts: [String: Int] = [:]
        for post in matches.prefix(180) {
            for facet in ActionSemantics.facets(post) { counts[facet, default: 0] += 1 }
            if let features = VisualFeatures.metadata(post) {
                for feature in features.attributes.keys where ["pose:", "style:", "clothing:", "setting:", "appearance:"].contains(where: feature.hasPrefix) {
                    counts[feature, default: 0] += 1
                }
            }
        }
        let common = counts.keys.sorted {
            counts[$0, default: 0] == counts[$1, default: 0] ? $0 < $1 : counts[$0, default: 0] > counts[$1, default: 0]
        }.prefix(3)
        return "\(matches.count) liked posts match. Common tagged traits: \(common.isEmpty ? "still learning" : common.joined(separator: ", "))."
    }
}

private struct TasteTagSection: View {
    @EnvironmentObject private var store: AppStore
    let preferred: Bool
    @Binding var selected: Set<String>
    @Binding var opposite: Set<String>
    let candidates: [String]
    let provider: Provider
    let wdCandidates: Set<String>
    @State private var draft = ""
    @State private var remote: [TagSuggestion] = []
    private var hue: Color { preferred ? AppTheme.accent : Color.orange }
    private var normalizedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "_")
    }
    private var matches: [String] {
        let pool = remote.map(\.value) + candidates
        var seen = Set<String>()
        let available = pool.filter { value in
            let tag = value.lowercased()
            guard !selected.contains(tag), !opposite.contains(tag), seen.insert(tag).inserted else { return false }
            return normalizedDraft.isEmpty || tag.contains(normalizedDraft)
        }
        if normalizedDraft.isEmpty { return Array(available.prefix(12)) }
        let starts = available.filter { $0.lowercased().hasPrefix(normalizedDraft) }
        let contains = available.filter { !$0.lowercased().hasPrefix(normalizedDraft) }
        return Array((starts + contains).prefix(12))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(preferred ? "More like this" : "See less of this", systemImage: preferred ? "heart.fill" : "hand.thumbsdown.fill")
                .font(.headline).foregroundStyle(hue)
            Text(provider == .hanime
                 ? "Hanime catalog categories and WD Tagger visual attributes."
                 : provider == .redgifs
                 ? "RedGIFs communities (niches), clip tags and visual attributes."
                 : preferred ? "Choose subjects, characters, styles or scenes."
                 : "De-emphasize topics you dislike. Exact Rule34 tags can also be excluded.")
                .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(AppTheme.secondaryLabel)
                TextField(preferred ? "Find an interest or tag" : "Find an unwanted tag", text: $draft)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.done).onSubmit(addTyped)
                    .accessibilityIdentifier(preferred ? "positive-interest-input" : "negative-interest-input")
                Button(action: addTyped) {
                    Image(systemName: "plus").font(.subheadline.weight(.bold))
                        .frame(width: 38, height: 38)
                        .background(hue.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(preferred ? "Add interest" : "Add exclusion")
            }
            .padding(.horizontal, 12).frame(minHeight: 54)
            .background(AppTheme.canvas, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(AppTheme.border))

            if !selected.isEmpty {
                Text("YOUR \(preferred ? "INTERESTS" : "EXCLUSIONS")")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.3).foregroundStyle(AppTheme.secondaryLabel)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 8)], spacing: 8) {
                    ForEach(selected.sorted(), id: \.self) { tag in
                        Button { selected.remove(tag) } label: {
                            HStack(spacing: 6) {
                                Text(label(for: tag))
                                    .lineLimit(1)
                                Image(systemName: "xmark.circle.fill")
                            }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(hue)
                            .frame(maxWidth: .infinity, minHeight: 37)
                            .padding(.horizontal, 8)
                            .background(hue.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain).accessibilityLabel("Remove \(tag)")
                    }
                }
            }
            if !matches.isEmpty {
                Text(normalizedDraft.isEmpty
                     ? (provider == .redgifs ? "NICHES & ATTRIBUTES" : provider == .hanime ? "HANIME TOPICS & WD TAGS" : "SUGGESTED FOR YOU")
                     : "MATCHING TAGS")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.3).foregroundStyle(AppTheme.secondaryLabel)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 8)], spacing: 8) {
                    ForEach(matches, id: \.self) { tag in
                        Button { add(tag) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle.fill").foregroundStyle(hue)
                                Text(label(for: tag)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 11)
                            .frame(minHeight: 39)
                            .background(AppTheme.canvas, in: Capsule())
                            .overlay(Capsule().stroke(AppTheme.border))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("taste-suggestion-\(tag)")
                    }
                }
            }
        }
        .padding(16)
        .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(AppTheme.border))
        .task(id: "\(provider.rawValue):\(draft)") {
            remote = []
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return }
            #endif
            guard provider == .rule34, normalizedDraft.count >= 2 else { return }
            do {
                try await Task.sleep(for: .milliseconds(260))
                let values = try await store.api.suggestions(provider: provider, query: normalizedDraft)
                guard !Task.isCancelled else { return }
                remote = values
            } catch { if !Task.isCancelled { remote = [] } }
        }
    }
    private func addTyped() {
        let words = draft.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
        for tag in TasteChoice.normalized(words) {
            add(provider == .rule34 ? tag.replacingOccurrences(of: " ", with: "_") : tag)
        }
        draft = ""
    }
    private func add(_ tag: String) {
        guard let normal = TasteChoice.normalized([tag]).first else { return }
        opposite.remove(normal)
        if selected.count < 40 { selected.insert(normal) }
    }
    private func label(for tag: String) -> String {
        if provider == .redgifs, let id = NativeProviderAPI.redgifsNicheID(tag) {
            return "Niche · " + id.replacingOccurrences(of: "-", with: " ").capitalized
        }
        let label = tag.replacingOccurrences(of: "_", with: " ")
        return provider == .hanime && wdCandidates.contains(tag)
            ? "WD · " + label : label
    }
}

enum TasteTagSuggestions {
    private static let lowSignal: Set<String> = [
        "1girl", "1girls", "2girls", "1boy", "2boys", "solo", "solo_focus", "multiple_girls",
        "highres", "absurdres", "score", "rating", "image", "video", "commentary_request",
        "artist_request", "tagme", "translation_request", "uncensored", "large_breasts",
        "breasts", "looking_at_viewer", "smile", "open_mouth", "simple_background",
        "white_background", "black_background", "blush", "long_hair", "short_hair",
        "16:9", "9:16", "1:1", "4:3", "2d", "3d", "animated_gif", "hires"
    ]

    static func isUseful(_ raw: String) -> Bool {
        let tag = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return tag.count >= 3 && tag.count <= 80 && !lowSignal.contains(tag)
            && !tag.hasPrefix("rating:") && !tag.hasPrefix("score:")
    }

    static func rank(learned: [String], favorites: [Post], posts: [Post], provider: Provider,
                     visual: [String] = [], niches: [RedgifsNiche] = []) -> [String] {
        var weights: [String: Int] = [:]
        func add(_ words: [String], weight: Int) {
            for raw in Set(words) {
                let tag = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard isUseful(tag) else { continue }
                weights[tag, default: 0] += weight
            }
        }
        add(learned, weight: 15)
        add(visual, weight: 12)
        for post in favorites where post.providerKey == provider {
            add(post.tags, weight: 5)
            if provider == .redgifs, let niche = post.category,
               let id = NativeProviderAPI.redgifsNicheID("niche:" + niche) {
                add(["niche:" + id], weight: 10)
            }
        }
        for post in posts where post.providerKey == provider {
            add(post.tags, weight: 1)
            if provider == .redgifs, let niche = post.category,
               let id = NativeProviderAPI.redgifsNicheID("niche:" + niche) {
                add(["niche:" + id], weight: 3)
            }
        }
        if provider == .redgifs { add(niches.map { "niche:" + $0.id }, weight: 8) }
        if provider == .rule34 {
            add(StarterTastePick.characters.flatMap(\.tags), weight: 2)
        } else if provider != .hanime && provider != .redgifs {
            add(StarterTastePick.keywords.flatMap(\.tags), weight: 2)
        }
        return weights.keys.sorted { lhs, rhs in
            weights[lhs] == weights[rhs] ? lhs < rhs : weights[lhs, default: 0] > weights[rhs, default: 0]
        }.prefix(120).map { $0 }
    }
}


/// A one-time native welcome flow. Credential secrets go to Keychain through
/// AppStore; only the non-secret completion flag goes to UserDefaults.

// Curated identities, not fabricated live-trending statistics. Image-backed
// cards use real matching provider previews, fetched in small bounded batches.
struct StarterTastePick: Identifiable, Sendable {
    let id: String
    let title: String
    let context: String
    let query: String
    let tags: [String]
    let symbol: String
    var suggestedAttributes: [String] = []
    static let characters: [Self] = [
        .init(id: "mario", title: "Mario", context: "Super Mario", query: "mario_(mario)", tags: ["mario_(mario)", "super_mario_bros"], symbol: "gamecontroller"),
        .init(id: "sonic", title: "Sonic", context: "Sonic", query: "sonic_the_hedgehog", tags: ["sonic_the_hedgehog"], symbol: "hare"),
        .init(id: "link", title: "Link", context: "Zelda", query: "link_(zelda)", tags: ["link_(zelda)", "the_legend_of_zelda"], symbol: "shield"),
        .init(id: "tifa", title: "Tifa Lockhart", context: "Final Fantasy", query: "tifa_lockhart", tags: ["tifa_lockhart", "final_fantasy"], symbol: "star.circle"),
        .init(id: "aerith", title: "Aerith Gainsborough", context: "Final Fantasy", query: "aerith_gainsborough", tags: ["aerith_gainsborough", "final_fantasy"], symbol: "star.circle"),
        .init(id: "rouge", title: "Rouge the Bat", context: "Sonic", query: "rouge_the_bat", tags: ["rouge_the_bat", "sonic_the_hedgehog"], symbol: "gamecontroller", suggestedAttributes: ["furry", "wings", "bodysuit"]),
        .init(id: "samus", title: "Samus Aran", context: "Metroid", query: "samus_aran", tags: ["samus_aran", "metroid"], symbol: "shield.lefthalf.filled"),
        .init(id: "bayonetta", title: "Bayonetta", context: "Bayonetta", query: "bayonetta", tags: ["bayonetta"], symbol: "crown"),
        .init(id: "lara", title: "Lara Croft", context: "Tomb Raider", query: "lara_croft", tags: ["lara_croft", "tomb_raider"], symbol: "mountain.2"),
        .init(id: "peach", title: "Princess Peach", context: "Super Mario", query: "princess_peach", tags: ["princess_peach", "super_mario_bros"], symbol: "crown"),
        .init(id: "shelly", title: "Shelly", context: "Brawl Stars", query: "shelly_brawl_stars", tags: ["shelly_brawl_stars", "brawl_stars"], symbol: "bolt"),
        .init(id: "colette", title: "Colette", context: "Brawl Stars", query: "colette_brawl_stars", tags: ["colette_brawl_stars", "brawl_stars"], symbol: "heart"),
        .init(id: "fishstick", title: "Fishstick", context: "Fortnite", query: "fishstick_fortnite", tags: ["fishstick_fortnite", "fortnite"], symbol: "fish"),
        .init(id: "knuckles", title: "Knuckles", context: "Sonic", query: "knuckles_the_echidna", tags: ["knuckles_the_echidna", "sonic_the_hedgehog"], symbol: "hare"),
        .init(id: "shadow", title: "Shadow", context: "Sonic", query: "shadow_the_hedgehog", tags: ["shadow_the_hedgehog", "sonic_the_hedgehog"], symbol: "moon.stars"),
        .init(id: "kratos", title: "Kratos", context: "God of War", query: "kratos", tags: ["kratos", "god_of_war"], symbol: "shield", suggestedAttributes: ["muscular_male", "beard", "armor"]),
        .init(id: "bowser", title: "Bowser", context: "Super Mario", query: "bowser", tags: ["bowser", "super_mario_bros"], symbol: "flame")
    ]
    // Suggestions are *options*, never personality assumptions derived from a
    // character's name. Only manually selected pairs influence rankings.
    static let dynamics: [(label: String, tag: String)] = [
        ("Femdom", "femdom"), ("Male dom", "male_dom"), ("Mommy", "mommy_dom"),
        ("Daddy", "daddy_dom"), ("Praise", "praise_kink"),
        ("Gentle femdom", "gentle_femdom"),
        ("Male sub", "male_submissive"), ("Female sub", "female_submissive")
    ]
    static let presentations: [(label: String, tag: String)] = [
        ("2D art", "2d"), ("3D", "3d"), ("Cosplay", "cosplay"),
        ("Animation", "animation"), ("Sketch", "sketch"), ("Pixel art", "pixel_art")
    ]
    static let keywords: [Self] = [
        .init(id: "cosplay", title: "Cosplay", context: "Characters and costumes", query: "cosplay", tags: ["cosplay"], symbol: "theatermasks"),
        .init(id: "animation", title: "Animation", context: "Animated videos", query: "animation", tags: ["animation"], symbol: "film"),
        .init(id: "dance", title: "Dance", context: "Dance videos", query: "dance", tags: ["dance"], symbol: "figure.dance"),
        .init(id: "roleplay", title: "Roleplay", context: "Themed scenes", query: "roleplay", tags: ["roleplay"], symbol: "sparkles.tv"),
        .init(id: "fitness", title: "Fitness", context: "Sports and movement", query: "fitness", tags: ["fitness"], symbol: "figure.strengthtraining.traditional"),
        .init(id: "lingerie", title: "Lingerie", context: "Style and outfits", query: "lingerie", tags: ["lingerie"], symbol: "hanger"),
        .init(id: "gaming", title: "Gaming", context: "Game-related clips", query: "gaming", tags: ["gaming"], symbol: "gamecontroller"),
        .init(id: "art", title: "Art", context: "Visual styles", query: "art", tags: ["art"], symbol: "paintpalette")
    ]
}

struct FirstRunSetupView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("quicktick-first-run-completed-v2") private var completed = false
    @State private var step = 0
    @State private var provider: Provider = .rule34
    @State private var rule34User = ""
    @State private var rule34Key = ""
    @State private var characters = ""
    @State private var artists = ""
    @State private var attributes = ""
    @State private var interests = ""
    @State private var avoid = ""
    @State private var saving = false
    @State private var setupMode: SetupMode = .simple
    @State private var selectedPicks: Set<String> = []
    @State private var selectedAttributes: Set<String> = []
    @State private var characterPairings: [String: Set<String>] = [:]
    @State private var cardExamples: [String: Post] = [:]
    @State private var focusedPick: String?
    @State private var examplePost: Post?
    @State private var examplePickID: String?
    @State private var exampleLoading = false
    @State private var exampleError: String?
    private enum SetupMode: String, CaseIterable, Hashable, Sendable { case simple = "Simple", advanced = "Advanced" }
    private var suggestions: [StarterTastePick] {
        isRule34 ? StarterTastePick.characters : StarterTastePick.keywords
    }
    private var previewPick: StarterTastePick? {
        suggestions.first(where: { $0.id == focusedPick })
    }

    private var isRule34: Bool { provider == .rule34 }
    private let steps = 4
    private let spring = Animation.spring(response: 0.38, dampingFraction: 0.84)

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack {
                    Label("QuickTick", systemImage: "sparkles")
                        .font(.system(.headline, design: .rounded, weight: .bold))
                    Spacer()
                    Text("\(step + 1) / \(steps)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }.padding(.horizontal, 24).padding(.top, 20)
                HStack(spacing: 6) {
                    ForEach(0..<steps, id: \.self) { index in
                        Capsule()
                            .fill(index <= step ? AnyShapeStyle(AppTheme.gradient) : AnyShapeStyle(Color.white.opacity(0.14)))
                            .frame(height: 4)
                    }
                }.padding(.horizontal, 24).padding(.top, 14)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Group {
                            switch step {
                            case 0: welcome
                            case 1: access
                            case 2:
                                if setupMode == .simple { simpleInterests }
                                else { interestsPage }
                            default: finishPage
                            }
                        }
                        .id(step)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)))
                    }
                    .frame(maxWidth: 560, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.top, 28)
                    .padding(.bottom, 28)
                }
                HStack(spacing: 12) {
                    if step > 0 {
                        Button("Back") { navigate(step - 1) }
                            .frame(minWidth: 88, minHeight: 52)
                            .buttonStyle(.bordered)
                    }
                    Button {
                        if step < steps - 1 {
                            if step == 1 && isRule34 && !rule34User.isEmpty && !rule34Key.isEmpty {
                                Task {
                                    saving = true
                                    await store.saveCredentials(user: rule34User, key: rule34Key,
                                                                session: "", remember: true)
                                    saving = false
                                    navigate(step + 1)
                                }
                            } else { navigate(step + 1) }
                        } else { Task { await finish() } }
                    } label: {
                        HStack(spacing: 8) {
                            if saving { ProgressView().tint(.white) }
                            Text(step == steps - 1 ? "Start QuickTick" : "Continue")
                            Image(systemName: step == steps - 1 ? "checkmark" : "arrow.right")
                        }
                        .font(.system(.headline, design: .rounded))
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .foregroundStyle(.white)
                        .background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                    .disabled(saving)
                    .accessibilityIdentifier("first-run-continue")
                }.padding(.horizontal, 24).padding(.vertical, 14)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(AppTheme.canvas.ignoresSafeArea())
        }
        .interactiveDismissDisabled()
        .preferredColorScheme(.dark)
        .onAppear { provider = store.selectedProvider }
    }

    private func navigate(_ next: Int) {
        withAnimation(reduceMotion ? nil : spring) { step = next }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "sparkles.tv")
                .font(.system(size: 58, weight: .light))
                .foregroundStyle(.white)
                .frame(width: 104, height: 104)
                .background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: 28))
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                .accessibilityHidden(true)
            Text("Your feed.\nYour taste.")
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .tracking(-1.4)
            Text("A fast, private way to discover, watch, and save content from the sources you choose.")
                .foregroundStyle(.secondary)
            featureRow("sparkles", title: "Recommended", detail: "Learns characters, artist credits, style and what you avoid.")
            featureRow("play.rectangle.on.rectangle", title: "Immersive", detail: "Swipe through videos with previews and playback controls.")
            featureRow("heart.square", title: "Favorites", detail: "Save posts and shuffle your likes whenever you want.")
            featureRow("hand.draw", title: "Your controls", detail: "Tap videos to expand. Swipe down to close standard full screen; Immersive keeps vertical paging.")
            Text("Choose how to start")
                .font(.headline)
                .padding(.top, 4)
            Picker("Setup mode", selection: $setupMode) {
                ForEach(SetupMode.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("first-run-mode")
            Text(setupMode == .simple
                ? "Simple: choose examples you like. See the important tags behind each pick."
                : "Advanced: enter characters, artists, attributes, interests and exclusions yourself.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func featureRow(_ icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title3)
                .frame(width: 44, height: 44)
                .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Choose your source")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text("Each source uses its own search format. You can change this later.")
                .foregroundStyle(.secondary)
            Picker("Source", selection: $provider) {
                ForEach(Provider.allCases) { source in
                    Text(source.displayName).tag(source)
                }
            }
            .pickerStyle(.menu)
            .tint(AppTheme.accent)
            .padding(12)
            .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 16))
            if isRule34 {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Rule34 access", systemImage: "key.horizontal").font(.headline)
                    TextField("Rule34 user ID", text: $rule34User)
                        .textContentType(.username).textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("first-run-rule34-user")
                    SecureField("Rule34 API key", text: $rule34Key)
                        .textContentType(.password)
                        .accessibilityIdentifier("first-run-rule34-key")
                    Text("Stored in iOS Keychain. Sent directly to Rule34 for API access, not to QuickTick recommendations.")
                        .font(.caption).foregroundStyle(.secondary)
                    if rule34User.isEmpty || rule34Key.isEmpty {
                        Label("You can continue without a key, but Rule34 posts will not load until you add credentials in Settings.", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .padding(16)
                .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 20))
            } else {
                Label("This source uses keyword and title search. Rule34 credentials are not needed.", systemImage: "text.magnifyingglass")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var simpleInterests: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text(isRule34 ? "Which characters do you like?" : "Which topics interest you?")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text(isRule34
                ? "Pick from different worlds. Previews come from matching source posts. Then choose the traits you want with each character."
                : "Choose starter keywords for this source, or add your own words below.")
                .foregroundStyle(.secondary)
            if let focused = previewPick {
                simpleExample(focused)
                    .task(id: "\(provider.rawValue):\(focused.id)") {
                        await loadExample(for: focused)
                    }
                if isRule34, selectedPicks.contains(focused.id) {
                    characterPairingSection(for: focused)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
                ForEach(suggestions) { pick in
                    Button {
                        if selectedPicks.contains(pick.id) { selectedPicks.remove(pick.id) }
                        else { selectedPicks.insert(pick.id) }
                        focusedPick = pick.id
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            ZStack(alignment: .topTrailing) {
                                RoundedRectangle(cornerRadius: 13).fill(AppTheme.gradient).opacity(0.38)
                                if let post = cardExamples[pick.id] {
                                    PosterView(url: post.thumbUrl.isEmpty ? post.cardPreviewURL : post.thumbUrl)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 104)
                                        .clipped()
                                } else {
                                    Image(systemName: pick.symbol)
                                        .font(.system(size: 32, weight: .light))
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 104)
                                }
                                Image(systemName: selectedPicks.contains(pick.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 21))
                                    .foregroundStyle(selectedPicks.contains(pick.id) ? AppTheme.accent : .white)
                                    .padding(8)
                                    .background(.black.opacity(0.35), in: Circle())
                                    .padding(6)
                            }
                            .frame(height: 104)
                            .clipShape(RoundedRectangle(cornerRadius: 13))
                            Text(pick.title).font(.headline).lineLimit(2)
                            Text(pick.context).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 161, alignment: .top)
                        .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18)
                            .stroke(selectedPicks.contains(pick.id) ? AppTheme.accent : AppTheme.border, lineWidth: 1.5))
                    }
                    .buttonStyle(QuicktickPressStyle())
                    .accessibilityIdentifier("simple-pick-\(pick.id)")
                }
            }
            .task(id: "\(provider.rawValue):\(setupMode.rawValue)") {
                await loadCardExamples()
            }
            if isRule34 {
                if !selectedPicks.isEmpty {
                    Text("Related characters from the same franchises")
                        .font(.headline)
                    let selectedContexts = Set(suggestions.filter { selectedPicks.contains($0.id) }.map(\.context))
                    let related = suggestions.filter {
                        selectedContexts.contains($0.context) && !selectedPicks.contains($0.id)
                    }
                    if related.isEmpty {
                        Text("Choose more examples to see related characters.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)], spacing: 8) {
                            ForEach(related) { pick in
                                Button("+ " + pick.title) {
                                    selectedPicks.insert(pick.id)
                                    focusedPick = pick.id
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
                Text("Styles and attributes").font(.headline)
                Text("Choose only styles you actually prefer.")
                    .font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)], spacing: 8) {
                    ForEach(["2d", "3d", "sketch", "pixel_art", "cosplay", "qipao", "3d_animation"], id: \.self) { tag in
                        Button {
                            if selectedAttributes.contains(tag) { selectedAttributes.remove(tag) }
                            else { selectedAttributes.insert(tag) }
                        } label: {
                            Label(tag.replacingOccurrences(of: "_", with: " "),
                                  systemImage: selectedAttributes.contains(tag) ? "checkmark.circle.fill" : "circle")
                        }
                        .buttonStyle(.bordered)
                        .tint(selectedAttributes.contains(tag) ? AppTheme.accent : .gray)
                    }
                }
            }
            input("Your own " + (isRule34 ? "tags and interests" : "keywords"),
                  subtitle: "Comma-separated; you can always change these later.",
                  placeholder: isRule34 ? "artist:your_favorite, character, attribute" : "Additional keywords or phrases",
                  text: $interests)
            input("Not into", subtitle: "Always exclude these tags or keywords from Recommended.",
                  placeholder: "Things to avoid", text: $avoid)
        }
    }

    private func characterPairingSection(for pick: StarterTastePick) -> some View {
        let looks = pick.suggestedAttributes.map { tag in
            (label: tag.replacingOccurrences(of: "_", with: " ").capitalized, tag: tag)
        }
        return VStack(alignment: .leading, spacing: 12) {
            Text("Pair tags with \(pick.title)").font(.headline)
            Text("Optional preferences for this character only. Dynamics such as femdom, mommy or praise aren't assumed from identity.")
                .font(.caption).foregroundStyle(.secondary)
            pairingChips(for: pick, title: "Dynamics", options: StarterTastePick.dynamics)
            pairingChips(for: pick, title: "Presentation", options: StarterTastePick.presentations)
            if !looks.isEmpty { pairingChips(for: pick, title: "Character-related attributes", options: looks) }
        }
        .padding(14)
        .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityIdentifier("simple-character-pairings")
    }

    private func pairingChips(for pick: StarterTastePick, title: String,
                              options: [(label: String, tag: String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 7)], spacing: 7) {
                ForEach(options.indices, id: \.self) { index in
                    let option = options[index]
                    let isSelected = characterPairings[pick.query]?.contains(option.tag) == true
                    Button {
                        var selected = characterPairings[pick.query] ?? []
                        if isSelected { selected.remove(option.tag) }
                        else {
                            // Don't let one character request contradictory
                            // power directions or personas simultaneously.
                            if let facet = ActionSemantics.facet(option.tag),
                               ["power", "persona"].contains(ActionSemantics.axis(facet)) {
                                selected = selected.filter { tag in
                                    guard let other = ActionSemantics.facet(tag) else { return true }
                                    return ActionSemantics.axis(other) != ActionSemantics.axis(facet)
                                        || other == facet
                                }
                            }
                            selected.insert(option.tag)
                        }
                        characterPairings[pick.query] = selected
                    } label: {
                        Label(option.label, systemImage: isSelected ? "checkmark.circle.fill" : "plus.circle")
                            .font(.caption.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.bordered)
                    .tint(isSelected ? AppTheme.accent : .gray)
                    .accessibilityIdentifier("simple-pair-\(pick.id)-\(option.tag)")
                }
            }
        }
    }

    private func simpleExample(_ pick: StarterTastePick) -> some View {
        let preview = cardExamples[pick.id] ?? (examplePickID == pick.id ? examplePost : nil)
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Example post", systemImage: "rectangle.stack")
                    .font(.headline)
                Spacer()
                if exampleLoading { ProgressView().tint(AppTheme.accent) }
            }
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 17).fill(AppTheme.gradient).opacity(0.30)
                if let preview,
                   let url = URL(string: preview.thumbUrl.isEmpty
                        ? preview.cardPreviewURL : preview.thumbUrl) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure:
                            Image(systemName: pick.symbol).resizable().scaledToFit()
                                .padding(55).foregroundStyle(.white.opacity(0.65))
                        default:
                            Image(systemName: pick.symbol).resizable().scaledToFit()
                                .padding(55).foregroundStyle(.white.opacity(0.65))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 190)
                    .clipped()
                } else {
                    Image(systemName: pick.symbol)
                        .font(.system(size: 66, weight: .ultraLight))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                LinearGradient(colors: [.clear, .black.opacity(0.8)],
                               startPoint: .center, endPoint: .bottom)
                Text(pick.title).font(.headline).padding(14)
            }
            .frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 17))
            if let exampleError {
                Text(exampleError).font(.caption).foregroundStyle(.secondary)
            }
            Text("Important tags").font(.subheadline.weight(.semibold))
            let observed = (preview?.tags ?? []).filter {
                !["solo", "video", "highres", "2d_art", "3d_art"].contains($0)
            }
            let highlighted = Array(NSOrderedSet(array: pick.tags + Array(observed.prefix(6))).compactMap { $0 as? String })
            Text(highlighted.prefix(8).map { "#"+$0 }.joined(separator: "  "))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Selecting this example teaches QuickTick its identity and franchise or keyword. Extra image attributes are learned from your actual likes, not assumed from this preview.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("simple-example-post")
    }

    /// An image is evidence of the exact selected identity, not a generic
    /// character illustration. Keep at most three live API requests at once
    /// and cancel when onboarding leaves this page.
    private func loadCardExamples() async {
        guard isRule34 else { return }
        let source = provider
        let api = store.api
        let choices = suggestions
        for start in stride(from: 0, to: choices.count, by: 3) {
            guard !Task.isCancelled else { return }
            let end = min(start + 3, choices.count)
            let batch = choices[start..<end].filter { cardExamples[$0.id] == nil }
            await withTaskGroup(of: (String, Post?).self) { group in
                for pick in batch {
                    group.addTask {
                        guard !Task.isCancelled else { return (pick.id, nil) }
                        let page = try? await api.posts(provider: source,
                            query: ParsedQuery(included: [pick.query], excluded: []),
                            page: 1, sort: "popular")
                        let match = page?.items.first { post in
                            (!post.thumbUrl.isEmpty || !post.cardPreviewURL.isEmpty)
                                && post.tags.map(RecommendationTagRules.canonical)
                                    .contains(RecommendationTagRules.canonical(pick.query))
                        }
                        return (pick.id, match)
                    }
                }
                for await (id, preview) in group {
                    guard !Task.isCancelled else { return }
                    if let preview { cardExamples[id] = preview }
                }
            }
        }
    }

    private func loadExample(for pick: StarterTastePick) async {
        examplePost = nil
        examplePickID = pick.id
        exampleError = nil
        if let cached = cardExamples[pick.id] {
            examplePost = cached
            exampleLoading = false
            return
        }
        exampleLoading = true
        defer { exampleLoading = false }
        do {
            let result = try await store.api.posts(provider: provider,
                query: ParsedQuery(included: [pick.query], excluded: []),
                page: 1, sort: "popular")
            guard !Task.isCancelled, focusedPick == pick.id else { return }
            examplePost = result.items.first(where: {
                (!$0.thumbUrl.isEmpty || !$0.cardPreviewURL.isEmpty)
                    && $0.tags.map(RecommendationTagRules.canonical)
                        .contains(RecommendationTagRules.canonical(pick.query))
            })
            if examplePost == nil { exampleError = "No live example available. The suggested tags can still be selected." }
        } catch {
            guard !Task.isCancelled, focusedPick == pick.id else { return }
            exampleError = isRule34 && (rule34User.isEmpty || rule34Key.isEmpty)
                ? "Add Rule34 credentials to see real post previews."
                : "Preview unavailable. Your choices will still be saved."
        }
    }

    private var interestsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Teach QuickTick your taste")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text("Separate entries with commas. You can edit everything in Settings later.")
                .foregroundStyle(.secondary)
            if isRule34 {
                input("Characters", subtitle: "The fictional identities you like, not their animal names",
                    placeholder: "mario_(mario), sonic_the_hedgehog", text: $characters)
                input("Artists", subtitle: "Especially artists you trust for 3D",
                    placeholder: "artist_one, artist_two", text: $artists)
                input("Attributes", subtitle: "Visual styles and details",
                    placeholder: "2d, qipao, sketch", text: $attributes)
            }
            input("Interests and kinks", subtitle: isRule34 ? "Tag-based interests" : "Keywords, scenes and topics",
                placeholder: isRule34 ? "Your preferred tags" : "Your preferred keywords or phrases", text: $interests)
            input("Not into", subtitle: "Things you don't want recommended",
                placeholder: "Unwanted tags or keywords", text: $avoid)
        }
    }

    private func input(_ title: String, subtitle: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: text, axis: .vertical)
                .lineLimit(2...4)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var finishPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64)).foregroundStyle(AppTheme.accent)
                .symbolEffect(.bounce, value: step)
            Text("You're ready")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text("QuickTick starts with the interests you entered and learns from your likes, explicit dislikes, and browsing. Visual analysis runs in the background while the device is idle.")
                .foregroundStyle(.secondary)
            featureRow("hand.point.up.left", title: "Find something new", detail: "Search tags on Rule34; search words and titles on other providers.")
            featureRow("slider.horizontal.3", title: "Fine-tune", detail: "Change your interests, exclusions and provider access in Settings.")
            featureRow("square.and.arrow.up", title: "Bring your taste along", detail: "On your old device, open Settings → Transfer recommendations → Share / AirDrop profile, or export a .quicktickprofile file. On your new device, open the file with QuickTick or choose Import in Settings, then confirm.")
            featureRow("lock.shield", title: "Private by default", detail: "Your interests stay on this device until you deliberately share a profile file. Logins, downloads and browsing history are not included.")
        }
    }

    private func values(_ input: String) -> [String] {
        TasteChoice.normalized(input.components(separatedBy: CharacterSet(charactersIn: ",;\n")))
    }

    private func finish() async {
        guard !saving else { return }
        saving = true
        store.selectedProvider = provider
        if isRule34 && !rule34User.isEmpty && !rule34Key.isEmpty {
            await store.saveCredentials(user: rule34User, key: rule34Key,
                                        session: "", remember: true)
        }
        // A chosen character is an explicit character preference, not consent
        // to recommend every item from its franchise. Keep the parent tags
        // solely as contextual previews and optional related suggestions.
        let picks = suggestions.filter { selectedPicks.contains($0.id) }.map(\.query)
        let advanced = isRule34 ? values(characters) + values(artists) + values(attributes) : []
        let positive = setupMode == .simple
            ? (picks + (isRule34 ? Array(selectedAttributes) : []) + values(interests))
            : (advanced + values(interests))
        let selectedContexts = Dictionary(uniqueKeysWithValues: suggestions.compactMap { pick -> (String, [String])? in
            guard selectedPicks.contains(pick.id), let paired = characterPairings[pick.query], !paired.isEmpty else { return nil }
            return (pick.query, paired.sorted())
        })
        store.setTaste(into: Array(NSOrderedSet(array: positive).compactMap { $0 as? String }),
                       notInto: values(avoid), characterTags: selectedContexts)
        completed = true
        saving = false
    }
}

/// Coalesce collection geometry notifications without invalidating the list
/// at display refresh frequency. The cached timestamps are deliberately not
/// observable SwiftUI state.
private final class CollectionScrollSampling {
    var lastAnalysis = Date.distantPast
    var lastMotion = Date.distantPast
}

struct FavoritesView: View {
    @EnvironmentObject private var store: AppStore
    var scrollToTopRevision = 0
    var onImmersiveChange: (Bool) -> Void = { _ in }
    @State private var immersive = false
    @State private var rhythm = false
    @State private var activeID: String?
    @State private var shuffleLikes = false
    @State private var selectedProviderID: String?
    @State private var sortByProvider = false
    @State private var randomizedIDs: [String] = []
    @State private var searchText = ""
    @State private var orderedLikes: [Post] = []
    @State private var saved: [Post] = []
    @State private var matchingLikes: [Post] = []
    @State private var searching = false
    @State private var searchRevision = 0
    @State private var searchTask: Task<Void, Never>?
    @State private var scrollSampling = CollectionScrollSampling()
    private var availableProviders: [String] {
        CollectionProviderOrder.available(orderedLikes.map(\.provider))
    }
    private var collectionSubtitle: String {
        if searching { return "Searching your likes…" }
        if searchText.isEmpty && selectedProviderID == nil { return "\(saved.count) posts you love" }
        return "\(matchingLikes.count) of \(saved.count) liked posts"
    }
    private func refreshSavedLikes() {
        orderedLikes = store.newestFavorites
        let providerLikes = selectedProviderID.map { providerID in
            orderedLikes.filter { CollectionProviderOrder.key($0.provider) == providerID }
        } ?? orderedLikes
        if shuffleLikes {
            let byID = Dictionary(uniqueKeysWithValues: providerLikes.map { ($0.stableID, $0) })
            let alreadyShuffled = Set(randomizedIDs)
            saved = randomizedIDs.compactMap { byID[$0] }
                + providerLikes.filter { !alreadyShuffled.contains($0.stableID) }
        } else if sortByProvider {
            saved = providerLikes.enumerated().sorted { lhs, rhs in
                let a = CollectionProviderOrder.name(CollectionProviderOrder.key(lhs.element.provider))
                let b = CollectionProviderOrder.name(CollectionProviderOrder.key(rhs.element.provider))
                let comparison = a.localizedStandardCompare(b)
                return comparison == .orderedSame ? lhs.offset < rhs.offset : comparison == .orderedAscending
            }.map { $0.element }
        } else { saved = providerLikes }
        scheduleSearch()
    }
    private func scheduleSearch() {
        searchTask?.cancel()
        searchRevision &+= 1
        let revision = searchRevision
        let query = searchText
        let snapshot = saved
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searching = false
            matchingLikes = snapshot
            return
        }
        searching = true
        searchTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(90)) } catch { return }
            let result = await Task.detached(priority: .userInitiated) {
                CollectionSearch.filter(snapshot, query: query)
            }.value
            guard !Task.isCancelled, revision == searchRevision else { return }
            matchingLikes = result
            searching = false
        }
    }
    private func shuffleFavorites() {
        randomizedIDs = orderedLikes.map(\.stableID).shuffled()
        shuffleLikes = true
        sortByProvider = false
        activeID = nil
        refreshSavedLikes()
    }
    var body: some View {
        ZStack {
                GeometryReader { geometry in
                    ScrollViewReader { scrollProxy in
                    ScrollView {
                        LazyVStack(spacing: 18) {
                            if AppTheme.premium {
                                PremiumPageHeader(title: "Your favorites", eyebrow: "QUICKTICK / LIBRARY",
                                                  subtitle: collectionSubtitle, icon: "heart.fill")
                                    .padding(.horizontal, 16)
                                    .padding(.top, 16)
                                    .id("favorites-feed-top")
                            } else {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Your collection")
                                        .font(.system(size: 30, weight: .bold, design: .rounded))
                                        .tracking(-1)
                                    Text(collectionSubtitle)
                                        .font(.subheadline).foregroundStyle(AppTheme.secondaryLabel)
                                }
                                Spacer()
                                Image(systemName: "heart.text.square.fill")
                                    .font(.system(size: 23))
                                    .foregroundStyle(.white)
                                    .frame(width: 48, height: 48)
                                    .background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: 16))
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                            .id("favorites-feed-top")
                            }
                            CollectionSearchField(text: $searchText, placeholder: "Search likes",
                                                  identifier: "favorites-search", isSearching: searching)
                                .padding(.horizontal, 16)
                            HStack(spacing: 10) {
                                Menu {
                                    Button("All providers", systemImage: selectedProviderID == nil ? "checkmark" : "square.grid.2x2") {
                                        selectedProviderID = nil
                                        activeID = nil
                                        refreshSavedLikes()
                                    }
                                    ForEach(availableProviders, id: \.self) { id in
                                        Button(CollectionProviderOrder.name(id),
                                               systemImage: selectedProviderID == id ? "checkmark" : "square.grid.2x2") {
                                            selectedProviderID = id
                                            activeID = nil
                                            refreshSavedLikes()
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
                                .accessibilityIdentifier("favorites-provider-filter")
                                Spacer()
                                if sortByProvider {
                                    Text("Provider A–Z").font(.caption).foregroundStyle(AppTheme.secondaryLabel)
                                }
                            }
                            .padding(.horizontal, 16)
                            if orderedLikes.isEmpty {
                                ContentUnavailableView("Save what you love", systemImage: "heart", description:
                                    Text("Your liked posts will stay here and help personalize Recommended and Create."))
                            } else if matchingLikes.isEmpty && !searching {
                                ContentUnavailableView("No matching likes", systemImage: "magnifyingglass", description:
                                    Text("Try a different title, artist, tag, or provider."))
                            }
                            ForEach(matchingLikes, id: \.stableID) { post in
                                FavoriteCachedCardRow(post: post,
                                    available: CGSize(width: min(680, geometry.size.width), height: geometry.size.height))
                                    .equatable()
                            }
                        }.frame(maxWidth: .infinity).padding(.bottom, 18)
                    }.coordinateSpace(name: "home-viewport")
                        .onPreferenceChange(HomeVisibleFrames.self) { frames in
                            guard store.activeTab == 2, store.isForeground, !immersive else { return }
                            let now = Date()
                            guard now.timeIntervalSince(scrollSampling.lastAnalysis) >= 0.10 else { return }
                            scrollSampling.lastAnalysis = now
                            if now.timeIntervalSince(scrollSampling.lastMotion) >= 0.3 {
                                scrollSampling.lastMotion = now
                                store.noteFeedMotion()
                            }
                            let bounds = CGRect(origin: .zero, size: geometry.size)
                            for (id, frame) in frames {
                                if let post = store.favorites[id], frame.height > 0,
                                   frame.intersection(bounds).height >= min(frame.height * 0.5, bounds.height * 0.5) {
                                    store.recordImpression(post)
                                }
                            }
                            if store.fullScreenPlaybackID == nil {
                                let playable = Set(frames.keys.filter { store.favorites[$0]?.isImmersiveMedia == true })
                                let key = VisiblePostSelector.select(frames: frames, viewport: bounds, current: store.inlinePlaybackID, eligible: playable)
                                if key != store.inlinePlaybackID { store.inlinePlaybackID = key }
                            }
                        }
                        .onChange(of: scrollToTopRevision) { _, _ in
                            immersive = false
                            activeID = nil
                            withAnimation(.easeOut(duration: 0.22)) {
                                scrollProxy.scrollTo("favorites-feed-top", anchor: .top)
                            }
                        }
                    }
                }
                .opacity(immersive ? 0 : 1)
                .allowsHitTesting(!immersive)
            if immersive {
                ImmersiveFeedView(posts: matchingLikes, offline: false, activePostID: $activeID,
                                  onClose: { immersive = false }, collectionTab: 2)
                    .transition(.move(edge: .trailing))
            }
        }
        .scrollContentBackground(.hidden)
        .background(ThemeBackdrop())
        .navigationTitle("Favorites")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { rhythm = true } label: { Label("Rhythm", systemImage: "waveform.path") }
                    .disabled(!matchingLikes.contains(where: { $0.providerKey == .rule34 }))
                    .accessibilityIdentifier("favorites-rhythm")
                Menu {
                    Button("Shuffle likes", systemImage: "shuffle") { shuffleFavorites() }
                    Button("Original order", systemImage: "list.bullet") {
                        shuffleLikes = false
                        sortByProvider = false
                        activeID = nil
                        refreshSavedLikes()
                    }
                    .disabled(!shuffleLikes && !sortByProvider)
                    Button("Provider A–Z", systemImage: "square.grid.2x2") {
                        shuffleLikes = false
                        sortByProvider = true
                        activeID = nil
                        refreshSavedLikes()
                    }
                    .disabled(sortByProvider)
                } label: {
                    Image(systemName: sortByProvider ? "line.3.horizontal.decrease.circle.fill" :
                                            (shuffleLikes ? "shuffle.circle.fill" : "shuffle"))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(orderedLikes.isEmpty)
                .accessibilityLabel("Browse likes randomly")
                .accessibilityIdentifier("favorites-shuffle")
                Button(immersive ? "Feed" : "Immersive") {
                    activeID = nil
                    immersive.toggle()
                }
                .disabled(matchingLikes.isEmpty)
                .accessibilityIdentifier("favorites-immersive")
            }
        }
        .fullScreenCover(isPresented: $rhythm) {
            RhythmSessionView(posts: matchingLikes.filter { $0.providerKey == .rule34 }, offline: false)
        }
        .onAppear {
            refreshSavedLikes()
            onImmersiveChange(immersive)
        }
        .onReceive(store.$favorites) { _ in
            // @Published delivers its new value before didSet completes.
            // Advance one main-actor turn so newestFavorites reads the new
            // saved order and updated like timestamps.
            Task { @MainActor in
                await Task.yield()
                refreshSavedLikes()
            }
        }
        .onChange(of: immersive) { _, value in onImmersiveChange(value) }
        .onChange(of: searchText) { _, _ in activeID = nil; scheduleSearch() }
        .onDisappear { searchTask?.cancel(); onImmersiveChange(false) }
    }
}

/// A keyboard search or a scroll-impression update must not recreate every
/// unchanged favorite's decoded image and video surface.
private struct FavoriteCachedCardRow: View, Equatable {
    let post: Post
    let available: CGSize

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.post == rhs.post && lhs.available == rhs.available
    }

    var body: some View {
        PostCardView(post: post, available: available, playbackTab: 2)
    }
}

/// A local, reproducible snapshot of explicit favorite metadata. Never infer
/// a person's identity, a fictional character or a power dynamic from pixels.
struct TasteWrappedMoment: Identifiable {
    let id: String
    let label: String
    let appearances: Int
    let sample: Post
}

struct TasteWrappedCategory: Identifiable {
    let id: String
    let heading: String
    let symbol: String
    let moments: [TasteWrappedMoment]
}

enum TasteWrappedSummary {
    static func make(from favorites: [Post]) -> [TasteWrappedCategory] {
        let posts = Array(favorites.prefix(1_000))
        let sections: [(id: String, title: String, symbol: String)] = [
            ("source", "Your favorite providers", "square.stack.3d.up"),
            ("creator", "Favorite creators", "person.crop.circle"),
            ("character", "Favorite characters", "person.crop.square"),
            ("franchise", "Favorite worlds", "globe.europe.africa"),
            ("artist", "Favorite artists", "paintbrush.pointed"),
            ("performer", "Tagged performers", "person.crop.rectangle"),
            ("theme", "Favorite scenes & styles", "photo.on.rectangle"),
            ("power", "Favorite dynamics", "bolt.heart"),
            ("action", "Favorite actions & poses", "figure.dance")
        ]
        var count: [String: Int] = [:]
        var sample: [String: Post] = [:]
        for post in posts {
            let features = VisualFeatures.metadata(post)
            let facets = ActionSemantics.facets(post)
            let attributes = features?.attributes.keys.map { $0 } ?? []
            let creditedCreator = post.creator?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let recognized: [String: [String]] = [
                "source": [post.providerKey?.rawValue ?? post.provider],
                "creator": creditedCreator.isEmpty || creditedCreator.count > 80 ? [] : [creditedCreator],
                "character": (features?.subjects ?? []).filter { !$0.hasPrefix("performer:") },
                "franchise": features?.franchises ?? [],
                "artist": features?.artists ?? [],
                "performer": (features?.subjects ?? []).filter { $0.hasPrefix("performer:") },
                "theme": Array(Set(attributes.filter {
                    term in ["scene:", "camera:", "style:", "setting:", "interest:", "clothing:"]
                        .contains { term.hasPrefix($0) }
                } + (post.category.map { ["category:" + $0] } ?? []))),
                "power": facets.filter { $0.hasPrefix("power:") || $0.hasPrefix("role:") },
                "action": Array(Set(attributes.filter {
                    $0.hasPrefix("pose:") || $0.hasPrefix("act:") || $0.hasPrefix("scene:")
                }))
            ]
            for (section, terms) in recognized {
                for raw in Set(terms) {
                    let term = TasteConcepts.canonical(raw)
                    guard !term.isEmpty, term.count < 65 else { continue }
                    let key = section + "|" + term
                    count[key, default: 0] += 1
                    if sample[key] == nil ||
                        (sample[key]?.previewImageURLs.isEmpty == true && !post.previewImageURLs.isEmpty) {
                        sample[key] = post
                    }
                }
            }
        }
        return sections.compactMap { section -> TasteWrappedCategory? in
            let moments = count.compactMap { key, appearances -> TasteWrappedMoment? in
                let prefix = section.id + "|"
                guard key.hasPrefix(prefix), let post = sample[key] else { return nil }
                let raw = String(key.dropFirst(prefix.count))
                let display: String
                if section.id == "source", let provider = Provider.identify(raw) {
                    display = provider.displayName
                } else {
                    display = (raw.split(separator: ":").last.map(String.init) ?? raw)
                        .replacingOccurrences(of: "_", with: " ").capitalized
                }
                return TasteWrappedMoment(id: key,
                                          label: display,
                                          appearances: appearances, sample: post)
            }.sorted {
                $0.appearances == $1.appearances ? $0.label < $1.label : $0.appearances > $1.appearances
            }
            guard !moments.isEmpty else { return nil }
            return TasteWrappedCategory(id: section.id, heading: section.title,
                                        symbol: section.symbol, moments: Array(moments.prefix(3)))
        }
    }
}

struct TasteWrappedSpotlight: Identifiable {
    let id: String
    let eyebrow: String
    let headline: String
    let detail: String
    let post: Post
}

enum TasteWrappedSpotlights {
    static func make(from favorites: [Post], sections: [TasteWrappedCategory]) -> [TasteWrappedSpotlight] {
        var items: [TasteWrappedSpotlight] = []
        var seen = Set<String>()
        func add(_ post: Post, eyebrow: String, headline: String, detail: String) {
            guard seen.insert(post.stableID).inserted else { return }
            items.append(TasteWrappedSpotlight(id: post.stableID, eyebrow: eyebrow,
                headline: headline, detail: detail, post: post))
        }
        if let source = sections.first(where: { $0.id == "source" })?.moments.first {
            add(source.sample, eyebrow: "YOUR #1 SOURCE", headline: "You love \(source.label).",
                detail: "\(source.appearances) of your liked posts came from here.")
        }
        if let recent = favorites.first {
            add(recent, eyebrow: "YOUR LATEST LOVE", headline: "This one caught your eye.",
                detail: "One of the posts you chose to keep.")
        }
        if let theme = sections.first(where: { $0.id == "character" || $0.id == "theme" || $0.id == "action" })?.moments.first {
            add(theme.sample, eyebrow: "THE PATTERN", headline: "You keep coming back to \(theme.label).",
                detail: "\(theme.appearances) liked posts share this detail.")
        }
        for post in favorites where items.count < 3 {
            add(post, eyebrow: "SAVED IN YOUR STORY", headline: "This made your favorites.",
                detail: post.displayTitle ?? "One of your personal highlights.")
        }
        return Array(items.prefix(3))
    }
}

/// Recap metrics come from locally recorded playback and download events.
/// Profile stats are split by provider, so each event is summed once. Unlike
/// liked-post spotlights these totals describe all-time activity even in the
/// weekly recap; no inferred viewing counts are fabricated from favorites.
struct TasteWrappedActivity: Equatable {
    let watchSeconds: Int
    let replays: Int
    let completed: Int
    let downloads: Int

    static func make(from state: RecommendationState) -> Self {
        let values = state.profiles.values.map(\.stats)
        return TasteWrappedActivity(
            watchSeconds: Int(values.reduce(0.0) { $0 + max(0, $1.watchSeconds) }),
            replays: values.reduce(0) { $0 + max(0, $1.replays) },
            completed: values.reduce(0) { $0 + max(0, $1.completions) },
            downloads: values.reduce(0) { $0 + max(0, $1.downloads) })
    }

    var watchTime: String {
        if watchSeconds >= 3_600 { return "\(watchSeconds / 3_600) hr \((watchSeconds % 3_600) / 60) min" }
        if watchSeconds >= 60 { return "\(watchSeconds / 60) min" }
        return "\(watchSeconds) sec"
    }
}

/// Cinematic layer shared by *every* New UI Wrapped chapter. Actual saved
/// favorites drift through the frame; at most two native players run, and
/// nothing from this private layer is included in the share card.
enum WrappedMotionSelection {
    static func select(_ posts: [Post], chapter: Int, limit: Int = 6) -> [Post] {
        var seen = Set<String>()
        let unique = posts.filter { seen.insert($0.stableID).inserted }
        guard !unique.isEmpty, limit > 0 else { return [] }
        let videos = unique.filter { $0.type.lowercased() == "video" }
        let images = unique.filter { $0.type.lowercased() != "video" }
        var chosen: [Post] = []
        func take(_ pool: [Post], start: Int, count: Int) {
            guard !pool.isEmpty, count > 0 else { return }
            for offset in 0..<min(count, pool.count) {
                let post = pool[(start + offset) % pool.count]
                if !chosen.contains(where: { $0.stableID == post.stableID }) {
                    chosen.append(post)
                }
            }
        }
        let page = max(0, chapter)
        take(videos, start: (page * 2) % max(1, videos.count), count: 2)
        take(images, start: (page * 4) % max(1, images.count), count: limit - chosen.count)
        if chosen.count < limit {
            take(unique, start: (page * limit) % unique.count, count: unique.count)
        }
        return Array(chosen.prefix(limit))
    }
}

private struct WrappedMotionBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let posts: [Post]
    let active: Bool
    let chapter: Int
    @State private var drifting = false

    var body: some View {
        GeometryReader { geometry in
            let items = WrappedMotionSelection.select(posts, chapter: chapter)
            let width = max(120, min(225, geometry.size.width * 0.49))
            let height = max(175, min(330, geometry.size.height * 0.38))
            ZStack {
                ForEach(items.indices, id: \.self) { index in
                    let post = items[index]
                    Group {
                        if index < 2 && post.type.lowercased() == "video" {
                            WrappedVideoStage(post: post, active: active)
                        } else {
                            PosterView(post: post)
                        }
                    }
                    .frame(width: width, height: height)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 19))
                    .overlay(RoundedRectangle(cornerRadius: 19)
                        .strokeBorder(.white.opacity(0.28), lineWidth: 1))
                    .rotationEffect(.degrees(Double((index % 3) - 1) * 7))
                    .position(x: geometry.size.width * ([0.24, 0.76, 0.51, 0.20, 0.79, 0.50][index]),
                              y: geometry.size.height * ([0.22, 0.31, 0.50, 0.68, 0.76, 0.96][index]))
                    .offset(x: reduceMotion ? 0 : (drifting ? CGFloat(18 + index * 7) : CGFloat(-28 - index * 4)),
                            y: reduceMotion ? 0 : (drifting ? -15 : 18))
                    .animation(reduceMotion ? nil :
                        .easeInOut(duration: Double(7 + index)).repeatForever(autoreverses: true),
                        value: drifting)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .onAppear { drifting = active }
        .onChange(of: active) { _, value in drifting = value }
    }
}

private struct WrappedActivityPage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let activity: TasteWrappedActivity
    let active: Bool
    let mediaPosts: [Post]
    let chapter: Int
    @State private var drifting = false

    var body: some View {
        GeometryReader { geometry in
        ZStack(alignment: .topLeading) {
            WrappedMotionBackdrop(posts: mediaPosts, active: active, chapter: chapter)
                .opacity(mediaPosts.isEmpty ? 0 : 0.38)
                .allowsHitTesting(false)
            LinearGradient(colors: [AppTheme.background.opacity(0.45), AppTheme.accent.opacity(0.33),
                                    AppTheme.background.opacity(0.92)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .allowsHitTesting(false)
            if !reduceMotion {
                Text("PLAY  •  REPLAY  •  REMEMBER  •  YOUR STORY  •")
                    .font(.system(size: 16, weight: .black, design: .rounded))
                    .tracking(3)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(.white.opacity(0.23))
                    .offset(x: drifting ? -480 : 120)
                    .frame(width: geometry.size.width, alignment: .leading)
                    .clipped()
                    .padding(.top, 106)
                    .animation(.linear(duration: 12).repeatForever(autoreverses: false), value: drifting)
                    .allowsHitTesting(false)
            }
            VStack(alignment: .leading, spacing: 22) {
                Text("YOUR ACTIVITY / ALL TIME")
                    .font(.system(size: 12, weight: .black, design: .rounded))
                    .tracking(2.6)
                    .foregroundStyle(AppTheme.accent)
                Text("Every replay\ntells a story.")
                    .font(.system(size: 38, weight: .black, design: .rounded))
                    .tracking(-1.7)
                    .lineLimit(2)
                    .minimumScaleFactor(0.76)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Your real playback and save history, tracked privately on this device.")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.74))
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        metric(activity.watchTime, label: "Time watched", icon: "clock.arrow.circlepath", order: 0)
                        metric("\(activity.replays)", label: "Replays", icon: "repeat", order: 1)
                    }
                    HStack(spacing: 12) {
                        metric("\(activity.completed)", label: "Completed views", icon: "checkmark.circle.fill", order: 2)
                        metric("\(activity.downloads)", label: "Save events", icon: "arrow.down.circle.fill", order: 3)
                    }
                }
                Text("Numbers are recorded activity, not estimates of your entire watching history.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 25)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        .clipped()
        }
        .onAppear { drifting = active }
        .onChange(of: active) { _, now in drifting = now }
        .accessibilityIdentifier("wrapped-activity")
    }

    private func metric(_ value: String, label: String, icon: String, order: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
            Text(value)
                .font(.system(size: 29, weight: .black, design: .rounded))
                .minimumScaleFactor(0.65)
                .lineLimit(1)
                .contentTransition(.numericText())
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.67))
        }
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .leading)
        .padding(16)
        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.14)))
        .opacity(active ? 1 : 0.25)
        .offset(y: active ? 0 : CGFloat(20 + order * 9))
        .animation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.82)
            .delay(Double(order) * 0.10), value: active)
    }
}

/// Play only the currently visible Wrapped highlight. When a signed stream is
/// unavailable, its actual saved poster stays on screen; no preview image is
/// ever misrepresented as video playback.
private struct WrappedVideoStage: View {
    @EnvironmentObject private var store: AppStore
    let post: Post
    let active: Bool
    @State private var player: AVPlayer?
    @State private var ready = false
    @State private var muted = true

    var body: some View {
        ZStack {
            PosterView(post: post)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let player {
                NativePlayerSurface(player: player, fill: true, ready: $ready,
                                    accessibilityID: "wrapped-video-\(post.stableID)")
                    .opacity(ready ? 1 : 0)
                    .allowsHitTesting(false)
            }
        }
        .clipped()
        .overlay(alignment: .bottomTrailing) {
            if player != nil {
                Button {
                    muted.toggle(); player?.isMuted = muted
                } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(.black.opacity(0.50), in: Circle())
                }
                .accessibilityLabel(muted ? "Unmute Wrapped video" : "Mute Wrapped video")
                .padding(22)
            }
        }
        .task(id: "\(post.stableID):\(active)") {
            guard active else { player?.pause(); player = nil; ready = false; return }
            guard post.type.lowercased() == "video" else { return }
            let videoURL: URL
            if let local = URL(string: post.mediaUrl), local.isFileURL {
                videoURL = local
            } else {
                guard let resolved = try? await store.resolver.resolve(post),
                      let source = URL(string: resolved.mediaUrl), source.scheme == "https",
                      !["jpg", "jpeg", "png", "webp", "gif", "avif"].contains(source.pathExtension.lowercased())
                else { return }
                videoURL = source
            }
            guard !Task.isCancelled && active else { return }
            let headers = HanimeGeneratedAPI.mediaHeaders(for: videoURL)
            let asset = headers.isEmpty ? AVURLAsset(url: videoURL)
                : AVURLAsset(url: videoURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            let next = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            next.isMuted = muted
            next.actionAtItemEnd = .pause
            player = next
            next.play()
        }
        .onDisappear { player?.pause(); player = nil; ready = false }
    }
}

private struct WrappedSpotlightPage: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let spotlight: TasteWrappedSpotlight
    let active: Bool
    @State private var revealed = false
    @State private var drifting = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                WrappedVideoStage(post: spotlight.post, active: active)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                LinearGradient(colors: [.clear, .black.opacity(0.16), .black.opacity(0.93)],
                               startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
                if !reduceMotion {
                    Text("✦ YOUR TASTE  •  YOUR STORY  •  YOUR FAVORITES ✦")
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .tracking(3)
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize()
                        .offset(x: drifting ? -250 : 80)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.top, 125)
                        .clipped()
                        .animation(.linear(duration: 11).repeatForever(autoreverses: false), value: drifting)
                        .allowsHitTesting(false)
                }
                VStack(alignment: .leading, spacing: 13) {
                    Text(spotlight.eyebrow)
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .tracking(2.6)
                        .foregroundStyle(AppTheme.accent)
                    Text(spotlight.headline)
                        .font(.system(size: 38, weight: .black, design: .rounded))
                        .tracking(-1.5)
                        .lineLimit(3)
                        .minimumScaleFactor(0.75)
                    Text(spotlight.detail)
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.83))
                        .lineLimit(3)
                    Text(spotlight.post.provider.uppercased())
                        .font(.caption2.weight(.black)).tracking(1.8)
                        .padding(.horizontal, 13).padding(.vertical, 8)
                        .background(.white.opacity(0.14), in: Capsule())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 30)
                .padding(.bottom, 132)
                .opacity(revealed ? 1 : 0)
                .offset(y: revealed ? 0 : 42)
                .animation(reduceMotion ? nil : .spring(response: 0.75, dampingFraction: 0.85), value: revealed)
            }
        }
        .onAppear { revealed = true; drifting = true }
        .onDisappear { revealed = false; drifting = false }
        .accessibilityIdentifier("wrapped-spotlight-\(spotlight.post.stableID)")
    }
}

/// Exported only when the user deliberately shares it. Avoid titles, tags,
/// artwork, URLs, account IDs and source history on the recap card: those can
/// be sensitive even when the underlying favorites are local to the device.
private struct WrappedRecapCard: View {
    let year: Int
    let period: String
    let likes: Int
    let videos: Int
    let sources: Int
    let activity: TasteWrappedActivity

    var body: some View {
        ZStack {
            Color(red: 0.038, green: 0.047, blue: 0.059)
            Circle()
                .strokeBorder(AppTheme.accent.opacity(0.33), lineWidth: 2)
                .frame(width: 560, height: 560)
                .offset(x: 260, y: -320)
            Circle()
                .strokeBorder(.white.opacity(0.10), lineWidth: 2)
                .frame(width: 480, height: 480)
                .offset(x: 260, y: -320)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 11) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 26, weight: .black))
                        .foregroundStyle(AppTheme.accent)
                    Text("QUICKTICK")
                        .font(.system(size: 18, weight: .black, design: .default))
                        .tracking(4)
                    Spacer()
                    Text("\(year)")
                        .font(.system(size: 19, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.58))
                }
                Spacer()
                Text("YOUR\nTASTE.\nYOUR STORY.")
                    .font(.system(size: 66, weight: .black, design: .default))
                    .tracking(-3)
                    .lineSpacing(-7)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
                RoundedRectangle(cornerRadius: 2)
                    .fill(AppTheme.accent)
                    .frame(width: 90, height: 5)
                    .padding(.top, 28)
                Text(period)
                    .font(.system(size: 14, weight: .bold, design: .default))
                    .tracking(3.5)
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.top, 30)
                HStack(alignment: .top, spacing: 19) {
                    recapStat("\(likes)", "LIKED POSTS")
                    recapStat("\(videos)", "VIDEOS")
                    recapStat("\(sources)", "SOURCES")
                }
                .padding(.top, 22)
                RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.16))
                    .frame(height: 1).padding(.vertical, 26)
                HStack {
                    Label(activity.watchTime + " watched (all-time)", systemImage: "play.circle.fill")
                    Spacer()
                    Text("MADE FOR ME")
                        .tracking(1.3)
                }
                .font(.system(size: 13, weight: .bold, design: .default))
                .foregroundStyle(.white.opacity(0.70))
                .padding(.bottom, 18)
            }
            .padding(49)
            .foregroundStyle(.white)
        }
        .frame(width: 540, height: 960)
        .clipped()
    }

    private func recapStat(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.system(size: 43, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.65)
                .lineLimit(1)
            Text(caption)
                .font(.system(size: 10, weight: .bold, design: .default))
                .tracking(1.3)
                .foregroundStyle(AppTheme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Daily access is available in Settings; RootView celebrates the evolving
/// taste profile once per ISO calendar week when the app opens.
struct TasteWrappedView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var weekly = false
    let onClose: () -> Void
    @State private var page = 0
    @State private var sections: [TasteWrappedCategory] = []
    @State private var spotlights: [TasteWrappedSpotlight] = []
    @State private var motionPosts: [Post] = []
    @State private var likedCount = 0
    @State private var videoCount = 0
    @State private var providerCount = 0
    @State private var activity = TasteWrappedActivity(watchSeconds: 0, replays: 0, completed: 0, downloads: 0)
    @State private var showingWeeklyLikes = false
    @State private var animated = false
    @State private var shareImage: Image?
    private var totalPages: Int { spotlights.count + sections.count + 3 }

    var body: some View {
        ZStack {
            ThemeBackdrop()
            LinearGradient(colors: [AppTheme.accent.opacity(0.28), .clear, AppTheme.palette.secondary.opacity(0.12)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            if !reduceMotion && !AppTheme.premium {
                Circle().fill(AppTheme.accent.opacity(0.20))
                    .frame(width: 280, height: 280).blur(radius: 65)
                    .offset(x: animated ? 145 : -130, y: animated ? -240 : 250)
                    .animation(.easeInOut(duration: 6).repeatForever(autoreverses: true), value: animated)
                    .allowsHitTesting(false)
            }
            TabView(selection: $page) {
                introduction.tag(0)
                ForEach(spotlights.indices, id: \.self) { index in
                    WrappedSpotlightPage(spotlight: spotlights[index], active: page == index + 1)
                        .tag(index + 1)
                }
                WrappedActivityPage(activity: activity, active: page == spotlights.count + 1,
                                    mediaPosts: motionPosts, chapter: spotlights.count + 1)
                    .tag(spotlights.count + 1)
                ForEach(sections.indices, id: \.self) { index in
                    wrappedPage(sections[index], pageIndex: spotlights.count + index + 2)
                        .tag(spotlights.count + index + 2)
                }
                conclusion.tag(totalPages - 1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .sensoryFeedback(.selection, trigger: page)
            VStack {
                HStack {
                    Text("QUICKTICK / WRAPPED")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(2)
                        .foregroundStyle(.white.opacity(0.86))
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 42, height: 42)
                            .background(.black.opacity(0.48), in: Circle())
                    }
                    .accessibilityLabel("Close Wrapped")
                }
                Spacer()
                HStack(spacing: 5) {
                    ForEach(0..<totalPages, id: \.self) { index in
                        Capsule()
                            .fill(index <= page ? .white : .white.opacity(0.28))
                            .frame(height: 3)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: page)
                    }
                }
                HStack {
                    Text("\(page + 1) / \(totalPages)")
                        .font(.caption2.monospacedDigit())
                    Spacer()
                    Button(page == totalPages - 1 ? "Finish" : "Next") {
                        if page == totalPages - 1 { onClose() }
                        else {
                            withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.83)) { page += 1 }
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                }
                .padding(.top, 12)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 18)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            let recent = weekly ? store.wrappedWeeklyFavorites : []
            showingWeeklyLikes = weekly && !recent.isEmpty
            let favorites = showingWeeklyLikes ? recent : store.newestFavorites
            likedCount = favorites.count
            sections = TasteWrappedSummary.make(from: favorites)
            spotlights = TasteWrappedSpotlights.make(from: favorites, sections: sections)
            motionPosts = favorites.shuffled()
            videoCount = favorites.filter { $0.type.lowercased() == "video" }.count
            providerCount = Set(favorites.map { $0.providerKey?.rawValue ?? $0.provider }).count
            animated = true
        }
        .task {
            let history = await store.recommendations.snapshot()
            activity = TasteWrappedActivity.make(from: history)
        }
        .task(id: "\(page):\(likedCount):\(activity.watchSeconds)") {
            guard page == totalPages - 1 else { return }
            // Rendering a share image only when the final story becomes
            // visible avoids allocating a 1080×1920 bitmap during feed scroll.
            let renderer = ImageRenderer(content: WrappedRecapCard(
                year: Calendar.current.component(.year, from: .now),
                period: showingWeeklyLikes ? "THIS WEEK'S LIKES" : "ALL-TIME PROFILE",
                likes: likedCount, videos: videoCount, sources: providerCount,
                activity: activity))
            renderer.scale = 2
            if let rendered = renderer.uiImage { shareImage = Image(uiImage: rendered) }
        }
        .accessibilityIdentifier("taste-wrapped")
    }

    @ViewBuilder private var introduction: some View {
        if AppTheme.premium {
            premiumIntroduction
        } else {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: 65, weight: .light))
                .foregroundStyle(AppTheme.accent)
            Text("Your taste.\nYour story.")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .tracking(-2)
            Text(showingWeeklyLikes
                 ? "Your new likes from this week, with the characters, creators and details that stood out."
                 : "Your all-time taste profile, with the characters, creators and details you gravitate toward.")
                .font(.title3).foregroundStyle(.white.opacity(0.8))
            Text("\(likedCount) liked posts" + (showingWeeklyLikes ? " this week" : ""))
                .font(.headline.monospacedDigit())
                .padding(.horizontal, 17).padding(.vertical, 10)
                .background(AppTheme.elevatedSurface, in: Capsule())
            HStack(spacing: 10) {
                Label("\(videoCount) videos", systemImage: "play.rectangle.fill")
                Label("\(providerCount) sources", systemImage: "square.stack.3d.up.fill")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.78))
            Text("Swipe through your actual favorites →")
                .font(.subheadline.weight(.bold)).foregroundStyle(AppTheme.accent)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 30)
        }
    }

    private var premiumIntroduction: some View {
        ZStack(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 0) {
                Text("QUICKTICK  /  \(Calendar.current.component(.year, from: .now))")
                    .font(.system(size: 12, weight: .black, design: .default))
                    .tracking(3)
                    .foregroundStyle(AppTheme.accent)
                    .padding(.bottom, 26)
                Text("THIS IS\nYOUR\nSTORY.")
                    .font(.system(size: 57, weight: .black, design: .default))
                    .tracking(-2.8)
                    .lineSpacing(-3)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(page == 0 ? 1 : 0.3)
                    .offset(y: page == 0 ? 0 : 28)
                    .animation(reduceMotion ? nil : .spring(response: 0.8, dampingFraction: 0.85), value: page)
                RoundedRectangle(cornerRadius: 2)
                    .fill(AppTheme.accent)
                    .frame(width: 92, height: 5)
                    .padding(.vertical, 32)
                Text("\(likedCount)")
                    .font(.system(size: 90, weight: .black, design: .rounded))
                    .tracking(-5)
                    .contentTransition(.numericText())
                    .foregroundStyle(.white)
                Text(showingWeeklyLikes ? "POSTS YOU LOVED THIS WEEK" : "POSTS YOU CHOSE TO KEEP")
                    .font(.system(size: 13, weight: .bold, design: .default))
                    .tracking(2.1)
                    .foregroundStyle(AppTheme.accent)
                Text("Real favorites. Real patterns. A story nobody else could make.")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
                    .padding(.top, 26)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 140)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }

    private func wrappedPage(_ section: TasteWrappedCategory, pageIndex: Int) -> some View {
        Group {
        if AppTheme.premium {
            GeometryReader { geometry in
                ZStack(alignment: .bottomLeading) {
                    WrappedMotionBackdrop(posts: motionPosts, active: page == pageIndex, chapter: pageIndex)
                        .opacity(0.72).allowsHitTesting(false)
                    LinearGradient(colors: [.black.opacity(0.06), AppTheme.background.opacity(0.55),
                                            AppTheme.background.opacity(0.97)],
                                   startPoint: .top, endPoint: .bottom)
                        .allowsHitTesting(false)
                    VStack(alignment: .leading, spacing: 11) {
                        HStack(spacing: 8) {
                            Image(systemName: section.symbol)
                            Text("CHAPTER \(pageIndex - spotlights.count - 1) / \(sections.count)")
                                .tracking(1.6)
                            Spacer(minLength: 8)
                            Text("YOUR FAVORITES")
                                .tracking(1.2)
                                .foregroundStyle(.white.opacity(0.64))
                        }
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(AppTheme.accent)
                        Text(section.heading)
                            .font(.system(size: 35, weight: .black, design: .rounded))
                            .tracking(-1.2)
                            .lineLimit(2)
                            .minimumScaleFactor(0.72)
                        if let top = section.moments.first {
                            HStack(spacing: 13) {
                                PosterView(post: top.sample)
                                    .frame(width: 75, height: 92)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("MOST LIKED")
                                        .font(.system(size: 10, weight: .black))
                                        .tracking(1.5)
                                        .foregroundStyle(AppTheme.accent)
                                    Text(top.label)
                                        .font(.system(size: 23, weight: .bold, design: .rounded))
                                        .lineLimit(2)
                                        .minimumScaleFactor(0.8)
                                    Text("\(top.appearances) liked posts")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.white.opacity(0.75))
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(10)
                            .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 17))
                            ForEach(0..<min(3, section.moments.count), id: \.self) { index in
                                let moment = section.moments[index]
                                HStack(spacing: 12) {
                                    Text(String(format: "%02d", index + 1))
                                        .font(.caption.monospacedDigit().weight(.black))
                                        .foregroundStyle(AppTheme.accent)
                                    Text(moment.label).lineLimit(1)
                                        .font(.subheadline.weight(.semibold))
                                    Spacer(minLength: 5)
                                    Text("\(moment.appearances)")
                                        .font(.subheadline.monospacedDigit().weight(.bold))
                                }
                                .padding(.vertical, 5)
                            }
                        } else {
                            Text("Keep liking posts to unlock this chapter.")
                                .font(.subheadline.weight(.medium))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 105)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }
        } else {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: section.symbol)
                .font(.system(size: 39, weight: .light))
                .foregroundStyle(AppTheme.accent)
            Text(section.heading)
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .tracking(-1.4)
            if section.moments.isEmpty {
                Text("Keep exploring. This category will fill in as you like posts with recognized tags.")
                    .font(.title3).foregroundStyle(.white.opacity(0.72))
            } else {
                ForEach(section.moments.indices, id: \.self) { index in
                    let moment = section.moments[index]
                    HStack(spacing: 14) {
                        PosterView(post: moment.sample)
                            .frame(width: 84, height: 108)
                            .clipShape(RoundedRectangle(cornerRadius: 15))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("#\(index + 1)").font(.caption.weight(.bold)).foregroundStyle(AppTheme.accent)
                            Text(moment.label).font(.system(size: 20, weight: .bold, design: .rounded))
                                .lineLimit(2)
                            Text("\(moment.appearances) liked posts")
                                .font(.caption).foregroundStyle(.white.opacity(0.64))
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 20))
                    .opacity(page == pageIndex ? 1 : 0.48)
                    .offset(y: page == pageIndex ? 0 : CGFloat((index + 1) * 14))
                    .animation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.85)
                        .delay(Double(index) * 0.10), value: page)
                }
            }
        }
        .frame(maxWidth: 500, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 26)
        }
        }
    }

    private var conclusion: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "heart.circle.fill")
                .font(.system(size: 66)).foregroundStyle(AppTheme.accent)
            Text("This is so you.")
                .font(.system(size: 42, weight: .bold, design: .rounded))
            Text("\(likedCount) posts. \(videoCount) videos. \(providerCount) sources. A story made only from what you actually liked.")
                .font(.title3).foregroundStyle(.white.opacity(0.75))
            if !spotlights.isEmpty {
                HStack(spacing: -16) {
                    ForEach(spotlights.indices, id: \.self) { index in
                        let item = spotlights[index]
                        PosterView(post: item.post)
                            .frame(width: 96, height: 133)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.25)))
                            .rotationEffect(.degrees(Double(index - 1) * 8))
                            .offset(y: page == totalPages - 1 ? 0 : 40)
                            .animation(reduceMotion ? nil : .spring(response: 0.7, dampingFraction: 0.75)
                                .delay(Double(index) * 0.12), value: page)
                    }
                }
                .padding(.vertical, 20)
            }
            Text("Come back in Settings for your evolving Wrapped. A new weekly recap appears when your likes tell a new story.")
                .font(.subheadline).foregroundStyle(.white.opacity(0.69))
            if let shareImage {
                ShareLink(item: shareImage,
                          preview: SharePreview("My QuickTick Wrapped", image: shareImage)) {
                    Label("Share a recap card", systemImage: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .foregroundStyle(.white)
                        .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 14))
                }
                .accessibilityIdentifier("wrapped-share-recap")
            } else {
                ProgressView("Preparing your recap card…")
                    .tint(AppTheme.accent)
            }
            Text("Sharing is optional. The card uses counts only, never private posts, titles or account details.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 30)
    }
}

enum BirthdayProfile {
    static let nameKey = "quicktick-birthday-display-name-v1"
    static let birthdateKey = "quicktick-birthday-date-v1"
    static let promptedKey = "quicktick-birthday-prompted-v1"
    static let greetedYearKey = "quicktick-birthday-greeted-year-v1"

    static func isBirthday(_ timestamp: Double, on date: Date = .now,
                           calendar: Calendar = .current) -> Bool {
        guard timestamp > 0, timestamp.isFinite else { return false }
        let birthday = Date(timeIntervalSince1970: timestamp)
        let birth = calendar.dateComponents([.month, .day], from: birthday)
        let today = calendar.dateComponents([.month, .day], from: date)
        return birth.month == today.month && birth.day == today.day
    }
}

/// Optional and device-local: no name or date is sent to a provider, synced
/// with favorites, included in exported profiles, or used for ad targeting.
struct BirthdayProfileEditor: View {
    @AppStorage(BirthdayProfile.nameKey) private var name = ""
    @AppStorage(BirthdayProfile.birthdateKey) private var birthdate = 0.0
    @State private var dateEnabled = false

    private var birthdaySelection: Binding<Date> {
        Binding(get: {
            birthdate > 0 ? Date(timeIntervalSince1970: birthdate) :
                Calendar.current.date(from: DateComponents(year: 2000, month: 1, day: 1)) ?? .now
        }, set: { birthdate = $0.timeIntervalSince1970 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("How should QuickTick address you?", text: $name)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .padding(12)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("birthday-name")
                .onChange(of: name) { _, value in
                    if value.count > 40 { name = String(value.prefix(40)) }
                }
            Toggle("Wish me a happy birthday", isOn: $dateEnabled)
                .padding(12)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                .onChange(of: dateEnabled) { _, enabled in
                    if !enabled { birthdate = 0 }
                }
            if dateEnabled {
                DatePicker("Birthdate", selection: birthdaySelection,
                           in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .padding(12)
                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("birthday-date")
                if birthdate <= 0 {
                    Text("Choose your actual birthdate to enable the greeting.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.secondaryLabel)
                }
            }
            Text("Optional. Your name and birthday stay on this device. You can change or remove them here anytime.")
                .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
        }
        .onAppear { dateEnabled = birthdate > 0 }
    }
}

struct BirthdayCelebrationView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let name: String
    let onClose: () -> Void
    @State private var animated = false

    var body: some View {
        ZStack {
            ThemeBackdrop()
            LinearGradient(colors: [AppTheme.accent.opacity(0.37), .clear,
                                    AppTheme.palette.secondary.opacity(0.25)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            if !reduceMotion {
                GeometryReader { geometry in
                    ForEach(0..<26, id: \.self) { index in
                        let horizontal = CGFloat((index * 37 + 13) % 100) / 100
                        Image(systemName: index.isMultiple(of: 3) ? "sparkle" : "circle.fill")
                            .font(.system(size: CGFloat(9 + index % 9), weight: .semibold))
                            .foregroundStyle(index.isMultiple(of: 2)
                                ? AppTheme.accent : AppTheme.palette.secondary)
                            .position(x: geometry.size.width * horizontal,
                                      y: animated ? geometry.size.height + 30 : -30)
                            .animation(.linear(duration: Double(2.5 + Double(index % 8) * 0.3))
                                .repeatForever(autoreverses: false)
                                .delay(Double(index % 11) * 0.19), value: animated)
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            VStack(spacing: 23) {
                Text("🎂").font(.system(size: 94))
                    .scaleEffect(animated && !reduceMotion ? 1.08 : 1)
                    .animation(.spring(response: 0.55, dampingFraction: 0.55)
                        .repeatCount(3, autoreverses: true), value: animated)
                Text("Happy Birthday\(name.isEmpty ? "!" : ",\n\(name)!")")
                    .font(.system(size: 43, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
                Text("Here's to another year of finding what you love.")
                    .font(.title3).foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                Button(action: onClose) {
                    Text("Let's celebrate")
                        .font(.headline.weight(.semibold))
                        .frame(maxWidth: 300, minHeight: 53)
                        .background(AppTheme.gradient, in: Capsule())
                }
                .buttonStyle(QuicktickPressStyle())
                .padding(.top, 10)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
        }
        .onAppear { animated = true }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("birthday-celebration")
    }
}
