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
                        HStack { Text(term); Spacer(); Button("Remove") { into.remove(term) } }
                    }
                }
                Section("What would you rather avoid?") {
                    Text("Reduces unwanted recommendations while keeping your other learned interests. Exact unwanted tags are excluded.").font(.caption).foregroundStyle(.secondary)
                    TextField("Unwanted topics or keywords", text: $negativeDraft).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Add exclusions") { addDraft(positive: false) }.disabled(negativeDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    ForEach(notInto.sorted(), id: \.self) { term in
                        HStack { Text(term); Spacer(); Button("Remove") { notInto.remove(term) } }
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


/// A one-time native welcome flow. Credential secrets go to Keychain through
/// AppStore; only the non-secret completion flag goes to UserDefaults.
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
                            .fill(index <= step ? AnyShapeStyle(AppTheme.gradient) : AnyShapeStyle(.white.opacity(0.14)))
                            .frame(height: 4)
                    }
                }.padding(.horizontal, 24).padding(.top, 14)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Group {
                            switch step {
                            case 0: welcome
                            case 1: access
                            case 2: interestsPage
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
                        if step < steps - 1 { navigate(step + 1) }
                        else { Task { await finish() } }
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
            featureRow("hand.draw", title: "Your controls", detail: "Tap videos to expand. Use Less for strong dislikes; fast skips are reversible.")
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
            .tint(.white)
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
        let positive = (isRule34 ? values(characters) + values(artists) + values(attributes) : []) + values(interests)
        store.setTaste(into: positive, notInto: values(avoid))
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
