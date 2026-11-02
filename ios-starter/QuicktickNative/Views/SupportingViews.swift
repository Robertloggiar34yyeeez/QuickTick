import SwiftUI
import SafariServices

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
                                    candidates: suggestedTags, provider: store.selectedProvider)
                    artistPreferences
                    TasteTagSection(preferred: false, selected: $notInto, opposite: $into,
                                    candidates: suggestedTags, provider: store.selectedProvider)
                    Label("Suggestions use your liked posts, learned interests and matching source tags. Your history remains private on this device.",
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
            Text(preferred ? "Choose subjects, characters, styles or scenes." : "De-emphasize topics you dislike. Exact Rule34 tags can also be excluded.")
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
                                Text(tag.replacingOccurrences(of: "_", with: " "))
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
                Text(normalizedDraft.isEmpty ? "SUGGESTED FOR YOU" : "MATCHING TAGS")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.3).foregroundStyle(AppTheme.secondaryLabel)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 8)], spacing: 8) {
                    ForEach(matches, id: \.self) { tag in
                        Button { add(tag) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle.fill").foregroundStyle(hue)
                                Text(tag.replacingOccurrences(of: "_", with: " ")).lineLimit(1)
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

    static func rank(learned: [String], favorites: [Post], posts: [Post], provider: Provider) -> [String] {
        var weights: [String: Int] = [:]
        func add(_ words: [String], weight: Int) {
            for raw in Set(words) {
                let tag = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard isUseful(tag) else { continue }
                weights[tag, default: 0] += weight
            }
        }
        add(learned, weight: 15)
        for post in favorites { add(post.tags, weight: 5) }
        for post in posts { add(post.tags, weight: 1) }
        if provider == .rule34 {
            add(StarterTastePick.characters.flatMap(\.tags), weight: 2)
        } else {
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

/// Daily access is available in Settings; RootView celebrates the evolving
/// taste profile once per ISO calendar week when the app opens.
struct TasteWrappedView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var weekly = false
    let onClose: () -> Void
    @AppStorage("quicktick-birthday-display-name-v1") private var displayName = ""
    @State private var reveal = false
    @State private var page = 0
    @State private var sections: [TasteWrappedCategory] = []
    @State private var likedCount = 0
    @State private var showingWeeklyLikes = false

    var body: some View {
        ZStack {
            ThemeBackdrop()
            LinearGradient(colors: [AppTheme.accent.opacity(0.28), .clear, AppTheme.palette.secondary.opacity(0.12)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            TabView(selection: $page) {
                introduction.tag(0)
                ForEach(sections.indices, id: \.self) { index in
                    wrappedPage(sections[index]).tag(index + 1)
                }
                conclusion.tag(sections.count + 1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.83), value: page)
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
                    ForEach(0..<(sections.count + 2), id: \.self) { index in
                        Capsule()
                            .fill(index == page ? .white : .white.opacity(0.28))
                            .frame(height: 3)
                    }
                }
                HStack {
                    Text("\(page + 1) / \(sections.count + 2)")
                        .font(.caption2.monospacedDigit())
                    Spacer()
                    Button(page == sections.count + 1 ? "Finish" : "Next") {
                        if page == sections.count + 1 { onClose() }
                        else {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { page += 1 }
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
            reveal = true
            let recent = weekly ? store.wrappedWeeklyFavorites : []
            showingWeeklyLikes = weekly && !recent.isEmpty
            let favorites = showingWeeklyLikes ? recent : store.newestFavorites
            likedCount = favorites.count
            sections = TasteWrappedSummary.make(from: favorites)
        }
        .accessibilityIdentifier("taste-wrapped")
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: 65, weight: .light))
                .foregroundStyle(AppTheme.accent)
            Text(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Your taste.\nYour story." : "\(displayName.trimmingCharacters(in: .whitespacesAndNewlines))’s taste.\nYour story.")
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
            Text("\(sections.filter { !$0.moments.isEmpty }.count) taste dimensions explored")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.78))
        }
        .opacity(reveal ? 1 : 0)
        .offset(y: reveal ? 0 : 24)
        .animation(reduceMotion ? nil : .spring(response: 0.65, dampingFraction: 0.8), value: reveal)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 30)
    }

    private func wrappedPage(_ section: TasteWrappedCategory) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: section.symbol)
                .font(.system(size: 39, weight: .light))
                .foregroundStyle(AppTheme.accent)
            Text(section.heading)
                .font(.system(size: 36, weight: .bold, design: .rounded))
            Text("\(section.moments.reduce(0) { $0 + $1.appearances }) matching likes across your top \(section.moments.count) interests")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
                .tracking(-1.4)
            if section.moments.isEmpty {
                Text("Keep exploring. This category will fill in as you like posts with recognized tags.")
                    .font(.title3).foregroundStyle(.white.opacity(0.72))
            } else {
                ForEach(section.moments.indices, id: \.self) { index in
                    let moment = section.moments[index]
                    HStack(spacing: 14) {
                        CachedMediaImage(url: moment.sample.cardPreviewURL,
                                         alternatives: moment.sample.previewImageURLs,
                                         pixels: 240, fill: true, placeholderTitle: moment.label)
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
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
        .frame(maxWidth: 500, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 26)
    }

    private var conclusion: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "heart.circle.fill")
                .font(.system(size: 66)).foregroundStyle(AppTheme.accent)
            Text("More to discover.")
                .font(.system(size: 42, weight: .bold, design: .rounded))
            Text("Come back any day in Settings to see your updated tastes. A new full-screen Wrapped greets you once a week.")
                .font(.title3).foregroundStyle(.white.opacity(0.75))
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
