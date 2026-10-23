import SwiftUI

struct CommentsView: View {
    @EnvironmentObject private var store: AppStore
    let post: Post
    @State private var page: CommentPage?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.orange) }
                else if let page {
                    if !page.available { Text(page.message ?? "Comments are unavailable for this provider.") }
                    ForEach(page.items) { comment in
                        VStack(alignment: .leading) { Text(comment.author).font(.headline); Text(comment.body); Text(comment.createdAt).font(.caption).foregroundStyle(.secondary) }
                    }
                    if page.available && page.items.isEmpty { Text("No comments.") }
                } else { ProgressView() }
            }.scrollContentBackground(.hidden).background(AppTheme.canvas).navigationTitle("Comments")
        }.task {
            do { page = try await store.api.comments(post) } catch { self.error = error.localizedDescription }
        }
    }
}

struct TasteOnboardingView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var into = Set<String>()
    @State private var notInto = Set<String>()
    @State private var positiveDraft = ""
    @State private var negativeDraft = ""
    var body: some View {
        NavigationStack {
            List {
                Section("What would you like more of?") {
                    Text("Guide your existing learned profile with topics, tags or phrases. Separate interests with commas. Your history is kept.").font(.caption).foregroundStyle(.secondary)
                    TextField("Topics or keywords", text: $positiveDraft)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("positive-interest-input")
                    Button("Add interests") { addDraft(positive: true) }.disabled(positiveDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    ForEach(into.sorted(), id: \.self) { term in
                        TasteChipRow(tag: term, preferred: true) { into.remove(term) }
                    }
                }
                Section("What would you rather avoid?") {
                    Text("Reduces unwanted recommendations while keeping your other learned interests. Exact unwanted tags are excluded.").font(.caption).foregroundStyle(.secondary)
                    TextField("Unwanted topics or keywords", text: $negativeDraft).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Add exclusions") { addDraft(positive: false) }.disabled(negativeDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    ForEach(notInto.sorted(), id: \.self) { term in
                        TasteChipRow(tag: term, preferred: false) { notInto.remove(term) }
                    }
                }
                Section("Which of these appeal to you?") {
                ForEach(Array(Set(store.posts.flatMap { $0.tags.prefix(6) })).sorted().prefix(24), id: \.self) { tag in
                    HStack {
                        if let post = store.posts.first(where: { $0.tags.contains(tag) }) {
                            PosterView(url: post.thumbUrl).frame(width: 72, height: 72).clipped()
                        }
                        Text(tag)
                        Spacer()
                        Button(into.contains(tag) ? "✓ Into" : "Into") { notInto.remove(tag); if !into.insert(tag).inserted { into.remove(tag) } }
                        Button(notInto.contains(tag) ? "✓ Not Into" : "Not Into") { into.remove(tag); if !notInto.insert(tag).inserted { notInto.remove(tag) } }
                    }.buttonStyle(.bordered)
                }
                }
            }.scrollContentBackground(.hidden).background(AppTheme.canvas).navigationTitle("Your interests")
                .toolbar { Button("Done") { addDraft(positive: true); addDraft(positive: false); store.setTaste(into: into.sorted(), notInto: notInto.sorted()); dismiss() } }
        }.interactiveDismissDisabled()
            .onAppear { let taste = store.tasteChoice(for: store.selectedProvider); into = Set(taste.into); notInto = Set(taste.notInto) }
    }
    private func addDraft(positive: Bool) {
        let draft = positive ? positiveDraft : negativeDraft
        let terms = TasteChoice.normalized(draft.components(separatedBy: CharacterSet(charactersIn: ",\n;")))
        for term in terms {
            if positive { notInto.remove(term); into.insert(term) }
            else { into.remove(term); notInto.insert(term) }
        }
        if positive { positiveDraft = "" } else { negativeDraft = "" }
    }
}

private struct TasteChipRow: View {
    let tag: String
    let preferred: Bool
    let onRemove: () -> Void
    private var hue: Color { preferred ? AppTheme.accent : .orange }
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: preferred ? "heart.fill" : "nosign")
                .font(.caption)
            Text(tag.replacingOccurrences(of: "_", with: " "))
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 0)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(QuicktickPressStyle())
            .accessibilityLabel("Remove \(tag)")
        }
        .foregroundStyle(hue)
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .background(hue.opacity(0.13), in: Capsule())
        .overlay(Capsule().stroke(hue.opacity(0.4)))
    }
}


/// A one-time native welcome flow. Credential secrets go to Keychain through
/// AppStore; only the non-secret completion flag goes to UserDefaults.

// Curated starter suggestions, not fabricated live-trending statistics.
// One representative provider post is fetched only after the user focuses a
// suggestion, so onboarding never launches a grid of network/image requests.
struct StarterTastePick: Identifiable, Sendable {
    let id: String
    let title: String
    let context: String
    let query: String
    let tags: [String]
    let symbol: String
    static let characters: [Self] = [
        .init(id: "chun_li", title: "Chun-Li", context: "Street Fighter", query: "chun_li", tags: ["chun_li", "street_fighter"], symbol: "figure.martial.arts"),
        .init(id: "cammy", title: "Cammy", context: "Street Fighter", query: "cammy_white", tags: ["cammy_white", "street_fighter"], symbol: "figure.martial.arts"),
        .init(id: "juri", title: "Juri", context: "Street Fighter", query: "juri_han", tags: ["juri_han", "street_fighter"], symbol: "figure.martial.arts"),
        .init(id: "tifa", title: "Tifa Lockhart", context: "Final Fantasy", query: "tifa_lockhart", tags: ["tifa_lockhart", "final_fantasy"], symbol: "star.circle"),
        .init(id: "aerith", title: "Aerith Gainsborough", context: "Final Fantasy", query: "aerith_gainsborough", tags: ["aerith_gainsborough", "final_fantasy"], symbol: "star.circle"),
        .init(id: "rouge", title: "Rouge the Bat", context: "Sonic", query: "rouge_the_bat", tags: ["rouge_the_bat", "sonic_the_hedgehog"], symbol: "gamecontroller"),
        .init(id: "samus", title: "Samus Aran", context: "Metroid", query: "samus_aran", tags: ["samus_aran", "metroid"], symbol: "shield.lefthalf.filled"),
        .init(id: "bayonetta", title: "Bayonetta", context: "Bayonetta", query: "bayonetta", tags: ["bayonetta"], symbol: "crown"),
        .init(id: "lara", title: "Lara Croft", context: "Tomb Raider", query: "lara_croft", tags: ["lara_croft", "tomb_raider"], symbol: "mountain.2")
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
    @State private var focusedPick: String?
    @State private var examplePost: Post?
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
                ? "Choose familiar characters. Their franchise helps discover related characters; styles and artists stay separate so one liked character doesn't imply liking every 3D artist."
                : "Choose starter keywords for this source, or add your own words below.")
                .foregroundStyle(.secondary)
            if let focused = previewPick {
                simpleExample(focused)
                    .task(id: "\(provider.rawValue):\(focused.id)") {
                        await loadExample(for: focused)
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
                            HStack {
                                Image(systemName: pick.symbol)
                                    .font(.title)
                                    .frame(width: 46, height: 46)
                                    .background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: 14))
                                Spacer()
                                Image(systemName: selectedPicks.contains(pick.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedPicks.contains(pick.id) ? AppTheme.accent : Color.white.opacity(0.55))
                            }
                            Text(pick.title).font(.headline).lineLimit(2)
                            Text(pick.context).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 126, alignment: .top)
                        .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18)
                            .stroke(selectedPicks.contains(pick.id) ? AppTheme.accent : AppTheme.border, lineWidth: 1.5))
                    }
                    .buttonStyle(QuicktickPressStyle())
                    .accessibilityIdentifier("simple-pick-\(pick.id)")
                }
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

    private func simpleExample(_ pick: StarterTastePick) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Example post", systemImage: "rectangle.stack")
                    .font(.headline)
                Spacer()
                if exampleLoading { ProgressView().tint(AppTheme.accent) }
            }
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 17).fill(AppTheme.gradient).opacity(0.30)
                if let examplePost,
                   let url = URL(string: examplePost.thumbUrl.isEmpty
                        ? examplePost.cardPreviewURL : examplePost.thumbUrl) {
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
            let observed = (examplePost?.tags ?? []).filter {
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

    private func loadExample(for pick: StarterTastePick) async {
        examplePost = nil
        exampleError = nil
        exampleLoading = true
        defer { exampleLoading = false }
        do {
            let result = try await store.api.posts(provider: provider,
                query: ParsedQuery(included: [pick.query], excluded: []),
                page: 1, sort: "popular")
            guard !Task.isCancelled, focusedPick == pick.id else { return }
            examplePost = result.items.first(where: {
                !$0.thumbUrl.isEmpty || !$0.cardPreviewURL.isEmpty
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
                    placeholder: "chun_li, rouge_the_bat", text: $characters)
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
            featureRow("lock.shield", title: "Private by default", detail: "Your taste model stays on this device unless you enable optional Sync.")
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
        store.setTaste(into: Array(NSOrderedSet(array: positive).compactMap { $0 as? String }), notInto: values(avoid))
        completed = true
        saving = false
    }
}

struct FavoritesView: View {
    @EnvironmentObject private var store: AppStore
    @State private var immersive = false
    @State private var activeID: String?
    @State private var shuffleLikes = false
    @State private var randomizedIDs: [String] = []
    private var orderedLikes: [Post] { store.favorites.values.sorted { $0.stableID < $1.stableID } }
    private var saved: [Post] {
        guard shuffleLikes else { return orderedLikes }
        let byID = Dictionary(uniqueKeysWithValues: orderedLikes.map { ($0.stableID, $0) })
        let shuffled = randomizedIDs.compactMap { byID[$0] }
        let inserted = orderedLikes.filter { !randomizedIDs.contains($0.stableID) }
        return shuffled + inserted
    }
    private func shuffleFavorites() {
        randomizedIDs = orderedLikes.map(\.stableID).shuffled()
        shuffleLikes = true
        activeID = nil
    }
    var body: some View {
        Group {
            if immersive {
                ImmersiveFeedView(posts: saved, offline: false, activePostID: $activeID,
                                  onClose: { immersive = false }, collectionTab: 2)
            } else {
                GeometryReader { geometry in
                    ScrollView {
                        LazyVStack(spacing: 18) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Your collection")
                                        .font(.system(size: 30, weight: .bold, design: .rounded))
                                        .tracking(-1)
                                    Text("\(saved.count) posts you love")
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
                            if saved.isEmpty {
                                ContentUnavailableView("Save what you love", systemImage: "heart", description:
                                    Text("Your liked posts will stay here and help personalize Recommended and Create."))
                            }
                            ForEach(saved, id: \.stableID) { post in
                                PostCardView(post: post, available: CGSize(width: min(680, geometry.size.width), height: geometry.size.height), playbackTab: 2)
                            }
                        }.frame(maxWidth: .infinity).padding(.bottom, 18)
                    }.coordinateSpace(name: "home-viewport")
                        .onPreferenceChange(HomeVisibleFrames.self) { frames in
                            guard store.activeTab == 2, store.isForeground, !immersive else { return }
                            store.noteFeedMotion()
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
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.canvas)
        .navigationTitle("Favorites")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button("Shuffle likes", systemImage: "shuffle") { shuffleFavorites() }
                    Button("Original order", systemImage: "list.bullet") {
                        shuffleLikes = false
                        activeID = nil
                    }
                    .disabled(!shuffleLikes)
                } label: {
                    Image(systemName: shuffleLikes ? "shuffle.circle.fill" : "shuffle")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(orderedLikes.isEmpty)
                .accessibilityLabel("Browse likes randomly")
                .accessibilityIdentifier("favorites-shuffle")
                Button(immersive ? "Feed" : "Immersive") {
                    activeID = nil
                    immersive.toggle()
                }
                .disabled(saved.isEmpty)
                .accessibilityIdentifier("favorites-immersive")
            }
        }
    }
}
