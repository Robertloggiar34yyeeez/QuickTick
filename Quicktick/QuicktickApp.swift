import SwiftUI
import AVKit
import WebKit

@main struct QuicktickApp: App {
    @StateObject private var app = AppState()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(app).preferredColorScheme(nil)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        TabView {
            FeedView().tabItem { Label("Home", systemImage: "house.fill") }
            ImmersiveView().tabItem { Label("Immersive", systemImage: "play.rectangle.fill") }
            SearchView().tabItem { Label("Search", systemImage: "magnifyingglass") }
            LikesView().tabItem { Label("Likes", systemImage: "heart.fill") }
            DownloadsView().tabItem { Label("Downloads", systemImage: "arrow.down.circle.fill") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .tint(.cyan)
        .sheet(isPresented: Binding(get: { !app.onboarded }, set: { if !$0 { app.onboarded = true } })) { OnboardingView().interactiveDismissDisabled() }
    }
}

struct OnboardingView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "sparkle.magnifyingglass").font(.system(size: 74)).foregroundStyle(.cyan)
                Text("Quicktick").font(.largeTitle.bold())
                Text("Browse media from the sources you choose. Your likes and viewing history stay on this device.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                VStack {
                    ForEach(SourceID.allCases) { source in
                        Toggle(source.rawValue, isOn: Binding(get: { app.enabledSources.contains(source) }, set: { if $0 { app.enabledSources.insert(source) } else { app.enabledSources.remove(source) } }))
                    }
                }.padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                Text("Some sources may include mature content. Configure exclusions in Settings.").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("Start browsing") { app.onboarded = true }.buttonStyle(.borderedProminent).controlSize(.large).disabled(app.enabledSources.isEmpty)
            }.padding().navigationTitle("Welcome")
        }
    }
}

struct SourcePicker: View {
    @EnvironmentObject var app: AppState
    @Binding var source: SourceID
    var body: some View {
        Picker("Source", selection: $source) {
            ForEach(SourceID.allCases.filter { app.enabledSources.contains($0) }) { source in Text(source.rawValue).tag(source) }
        }.pickerStyle(.segmented)
    }
}

struct SortPicker: View {
    @Binding var sort: FeedSort
    let source: SourceID
    var body: some View {
        Picker("Sort", selection: $sort) {
            ForEach((source == .redgifs ? RedGIFsProvider().supportedSorts : DanbooruProvider().supportedSorts)) { mode in Text(mode.rawValue).tag(mode) }
        }.pickerStyle(.menu)
    }
}

struct FeedView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var model = FeedModel()
    @State private var selected: Post?
    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                SourcePicker(source: $model.source).padding(.horizontal)
                HStack { Text(model.sort == .recommended ? "For you" : model.sort.rawValue).font(.title2.bold()); Spacer(); SortPicker(sort: $model.sort, source: model.source) }.padding(.horizontal)
                feedList
            }
            .navigationTitle("Quicktick")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $selected) { post in MediaViewer(post: post) }
            .task { model.reset(app: app) }
            .onChange(of: model.source) { _, _ in if model.source == .redgifs && model.sort == .score { model.sort = .popular }; model.reset(app: app) }
            .onChange(of: model.sort) { _, _ in model.reset(app: app) }
        }
    }
    private var feedList: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                ForEach(model.posts) { post in
                    PostCard(post: post) { selected = post }
                        .onAppear { if post.id == model.posts.last?.id { model.loadMore(app: app) } }
                }
                if model.loading { ProgressView().padding() }
                if let error = model.error { ErrorView(message: error) { model.loadMore(app: app) } }
                if model.posts.isEmpty && !model.loading && model.error == nil { ContentUnavailableView("No posts", systemImage: "photo.on.rectangle", description: Text("Try another source or search.")) }
            }.padding(.horizontal)
        }.refreshable { model.reset(app: app) }
    }
}

struct PostCard: View {
    @EnvironmentObject var app: AppState
    let post: Post
    let open: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(post.source.rawValue).font(.subheadline.bold()); Spacer(); Text(post.rating ?? "").font(.caption).foregroundStyle(.secondary) }
            Button(action: { app.record(post, weight: 1); open() }) {
                MediaPreview(post: post).frame(maxWidth: .infinity).frame(height: min(CGFloat(post.height) / CGFloat(max(post.width, 1)) * 360, 500)).clipped().background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain).accessibilityLabel("Open \(post.title)")
            Text(post.title.isEmpty ? "Post \(post.sourceID)" : post.title).font(.subheadline).lineLimit(2)
            HStack(spacing: 20) {
                Button { app.like(post) } label: { Label("\(post.score)", systemImage: app.isLiked(post) ? "heart.fill" : "heart") }.accessibilityLabel(app.isLiked(post) ? "Unlike" : "Like")
                Button { app.downloads.start(post) } label: { Image(systemName: "arrow.down.circle") }.accessibilityLabel("Download")
                ShareLink(item: post.pageURL) { Image(systemName: "square.and.arrow.up") }
                Spacer()
            }.buttonStyle(.plain).foregroundStyle(.secondary)
        }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

struct MediaPreview: View {
    let post: Post
    var body: some View {
        ZStack {
            AsyncImage(url: post.previewURL, transaction: Transaction(animation: .easeInOut)) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFit()
                case .failure: Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
                case .empty: ProgressView()
                @unknown default: EmptyView()
                }
            }
            if post.kind == .video { Image(systemName: "play.circle.fill").font(.system(size: 48)).foregroundStyle(.white).shadow(radius: 4) }
        }
    }
}

struct ErrorView: View {
    let message: String
    let retry: () -> Void
    var body: some View { VStack(spacing: 8) { Text(message).foregroundStyle(.secondary); Button("Retry", action: retry) }.multilineTextAlignment(.center).padding() }
}

struct MediaViewer: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let post: Post
    @State private var scale: CGFloat = 1
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Group {
                        if post.kind == .video { LoopingVideo(url: post.mediaURL, active: true) }
                        else if post.kind == .animation { AnimatedWebView(url: post.mediaURL) }
                        else { AsyncImage(url: post.mediaURL) { image in image.resizable().scaledToFit().scaleEffect(scale).gesture(MagnifyGesture().onChanged { scale = max(1, $0.magnification) }) } placeholder: { ProgressView() } }
                    }.frame(maxWidth: .infinity).frame(minHeight: 320).background(.black)
                    HStack { Text(post.source.rawValue).font(.headline); Spacer(); Text("Score \(post.score)").foregroundStyle(.secondary) }
                    if let rating = post.rating { Text("Rating: \(rating)").font(.subheadline) }
                    Text(post.tags.joined(separator: " · ").replacingOccurrences(of: "_", with: " ")).font(.subheadline).foregroundStyle(.secondary)
                    HStack {
                        Button { app.like(post) } label: { Label(app.isLiked(post) ? "Liked" : "Like", systemImage: app.isLiked(post) ? "heart.fill" : "heart") }
                        Button { app.downloads.start(post) } label: { Label("Download", systemImage: "arrow.down.circle") }
                        ShareLink(item: post.pageURL) { Label("Source", systemImage: "safari") }
                    }.buttonStyle(.bordered)
                }.padding()
            }.navigationTitle("Post \(post.sourceID)").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

struct AnimatedWebView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView { let view = WKWebView(); view.scrollView.isScrollEnabled = false; view.isOpaque = false; view.backgroundColor = .black; return view }
    func updateUIView(_ view: WKWebView, context: Context) { if view.url != url { view.load(URLRequest(url: url)) } }
}

struct LoopingVideo: View {
    let url: URL
    let active: Bool
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    var body: some View {
        Group { if let player { VideoPlayer(player: player) } else { ProgressView() } }
            .onAppear { setup() }
            .onDisappear { player?.pause(); player = nil; looper = nil }
            .onChange(of: active) { _, value in if value { player?.play() } else { player?.pause() } }
    }
    private func setup() {
        guard player == nil else { return }
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        looper = AVPlayerLooper(player: queue, templateItem: item)
        player = queue
        if active { queue.play() }
    }
}
