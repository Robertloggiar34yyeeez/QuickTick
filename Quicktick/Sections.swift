import SwiftUI

struct ImmersiveView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var model = FeedModel(animatedOnly: true)
    @State private var current: String?
    @State private var showSearch = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SourcePicker(source: $model.source).padding(8)
                if model.posts.isEmpty {
                    Spacer()
                    if model.loading { ProgressView() }
                    else if let error = model.error { ErrorView(message: error) { model.loadMore(app: app) } }
                    else { ContentUnavailableView("No motion posts", systemImage: "play.rectangle") }
                    Spacer()
                } else {
                    GeometryReader { geometry in
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 0) {
                                ForEach(model.posts) { post in
                                    ZStack(alignment: .bottomLeading) {
                                        Color.black
                                        LoopingVideo(url: post.mediaURL, active: current == post.id && app.autoplay)
                                        VStack(alignment: .leading, spacing: 10) {
                                            Text(post.source.rawValue).font(.headline)
                                            Text(post.title).lineLimit(2)
                                            HStack {
                                                Button { app.like(post) } label: { Label("Like", systemImage: app.isLiked(post) ? "heart.fill" : "heart") }
                                                Button { app.downloads.start(post) } label: { Label("Save", systemImage: "arrow.down.circle") }
                                                Button { showSearch = true } label: { Label("Search", systemImage: "magnifyingglass") }
                                            }.buttonStyle(.bordered)
                                        }.foregroundStyle(.white).padding().background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12)).padding()
                                    }.frame(height: geometry.size.height).id(post.id)
                                        .onAppear { if current == nil { current = post.id }; if post.id == model.posts.last?.id { model.loadMore(app: app) } }
                                }
                            }.scrollTargetLayout()
                        }.scrollTargetBehavior(.paging).scrollPosition(id: $current)
                    }
                }
            }
            .navigationTitle("Immersive").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { SortPicker(sort: $model.sort, source: model.source) } }
            .sheet(isPresented: $showSearch) { SearchView() }
            .task { model.reset(app: app) }
            .onChange(of: model.source) { _, _ in if model.source == .redgifs && model.sort == .score { model.sort = .popular }; current = nil; model.reset(app: app) }
            .onChange(of: model.sort) { _, _ in current = nil; model.reset(app: app) }
            .onChange(of: current) { _, id in if let post = model.posts.first(where: { $0.id == id }) { app.record(post, weight: 0.3) } }
        }
    }
}

struct SearchView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var model = FeedModel()
    @State private var input = ""
    @State private var suggestions: [String] = []
    @State private var selected: Post?
    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                SourcePicker(source: $model.source).padding(.horizontal)
                HStack {
                    TextField("Tags separated by spaces or commas", text: $input).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search).onSubmit(search)
                    Button("Search", action: search).disabled(input.isEmpty)
                }.padding(.horizontal)
                if !suggestions.isEmpty {
                    ScrollView(.horizontal) { HStack { ForEach(suggestions, id: \.self) { tag in Button(tag) { input = tag; search() }.buttonStyle(.bordered) } }.padding(.horizontal) }
                }
                if model.posts.isEmpty && input.isEmpty {
                    List(app.recentSearches, id: \.self) { term in Button(term) { input = term; search() } }.overlay { if app.recentSearches.isEmpty { ContentUnavailableView("Search tags", systemImage: "magnifyingglass", description: Text("Combine tags to narrow results.")) } }
                } else {
                    ScrollView { LazyVStack(spacing: 16) {
                        ForEach(model.posts) { post in PostCard(post: post) { selected = post }.onAppear { if post.id == model.posts.last?.id { model.loadMore(app: app) } } }
                        if model.loading { ProgressView() }
                        if let error = model.error { ErrorView(message: error) { model.loadMore(app: app) } }
                    }.padding() }
                }
            }.navigationTitle("Search")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { SortPicker(sort: $model.sort, source: model.source) } }
            .sheet(item: $selected) { MediaViewer(post: $0) }
            .onChange(of: input) { _, value in
                let prefix = TagRules.terms(value).last ?? ""
                guard prefix.count >= 2 else { suggestions = []; return }
                Task { suggestions = (try? await app.provider(model.source).suggestions(for: prefix)) ?? [] }
            }
            .onChange(of: model.source) { _, _ in if model.source == .redgifs && model.sort == .score { model.sort = .popular }; if !model.search.isEmpty { model.reset(app: app) } }
            .onChange(of: model.sort) { _, _ in if !model.search.isEmpty { model.reset(app: app) } }
        }
    }
    private func search() { model.search = input; app.addSearch(input); suggestions = []; model.reset(app: app) }
}

struct LikesView: View {
    @EnvironmentObject var app: AppState
    @State private var selected: Post?
    var body: some View {
        NavigationStack {
            ScrollView { LazyVStack(spacing: 16) { ForEach(app.likes) { post in PostCard(post: post) { selected = post } } }.padding() }
                .overlay { if app.likes.isEmpty { ContentUnavailableView("No likes yet", systemImage: "heart", description: Text("Liked posts appear here.")) } }
                .navigationTitle("Likes").sheet(item: $selected) { MediaViewer(post: $0) }
        }
    }
}

struct DownloadsView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        DownloadList(manager: app.downloads)
    }
}

private struct DownloadList: View {
    @ObservedObject var manager: DownloadManager
    var body: some View {
        NavigationStack {
            List {
                ForEach(manager.items) { item in
                    HStack {
                        AsyncImage(url: item.post.previewURL) { image in image.resizable().scaledToFill() } placeholder: { Color.gray }.frame(width: 58, height: 58).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading) {
                            Text(item.post.title.isEmpty ? item.post.id : item.post.title).lineLimit(1)
                            Text(item.status.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                            if let error = item.error { Text(error).font(.caption).foregroundStyle(.red) }
                        }
                        Spacer()
                        if item.status == .active { Button("Cancel") { manager.cancel(item.id) } }
                        if item.status == .failed || item.status == .cancelled { Button("Retry") { manager.retry(item.id) } }
                        if item.status == .completed, let url = manager.fileURL(item) { ShareLink(item: url) { Image(systemName: "square.and.arrow.up") } }
                    }
                }
            }.overlay { if manager.items.isEmpty { ContentUnavailableView("No downloads", systemImage: "arrow.down.circle", description: Text("Saved media appears here.")) } }.navigationTitle("Downloads")
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        NavigationStack {
            Form {
                Section("Sources") { NavigationLink("Sources / Accounts") { AccountsView() } }
                Section("Preferences") {
                    NavigationLink("Excluded tags") { ExclusionsView() }
                    Toggle("Autoplay videos", isOn: $app.autoplay)
                    Toggle("Mute by default", isOn: $app.mute)
                }
                Section("Data") {
                    Button("Clear search history") { app.recentSearches = [] }
                    Button("Reset recommendations") { app.clearRecommendations() }
                    Button("Clear media cache") { app.clearCache() }
                }
                Section("About") { Text("Quicktick 1.0"); Text("Media belongs to its respective sources and creators.").font(.footnote).foregroundStyle(.secondary) }
            }.navigationTitle("Settings")
        }
    }
}

struct ExclusionsView: View {
    @EnvironmentObject var app: AppState
    @State private var input = ""
    var body: some View {
        Form {
            Section("Add tags") {
                HStack { TextField("tag_a, tag_b", text: $input).textInputAutocapitalization(.never); Button("Add") { add() } }.onSubmit(add)
            }
            Section("Excluded tags") {
                ForEach($app.excluded) { $tag in Toggle(tag.name, isOn: $tag.enabled) }
                    .onDelete { app.excluded.remove(atOffsets: $0) }
                if !app.excluded.isEmpty { Button("Clear all", role: .destructive) { app.excluded = [] } }
            }
        }.navigationTitle("Excluded tags")
    }
    private func add() {
        for tag in TagRules.terms(input) where !app.excluded.contains(where: { $0.name == tag }) { app.excluded.append(ExcludedTag(name: tag)) }
        input = ""
    }
}

struct AccountsView: View {
    @EnvironmentObject var app: AppState
    @State private var login = Keychain.get("danbooru.login") ?? ""
    @State private var apiKey = Keychain.get("danbooru.key") ?? ""
    @State private var status = ""
    var body: some View {
        Form {
            Section("Enabled sources") {
                ForEach(SourceID.allCases) { source in Toggle(source.rawValue, isOn: Binding(get: { app.enabledSources.contains(source) }, set: { if $0 { app.enabledSources.insert(source) } else { app.enabledSources.remove(source) } })) }
            }
            Section("Danbooru account") {
                Text("Optional: enter your Danbooru login and API key from account settings. Credentials are stored in this device's Keychain.").font(.footnote)
                TextField("Login", text: $login).textInputAutocapitalization(.never)
                SecureField("API key", text: $apiKey)
                Button("Save credentials") { saveCredentials() }
                Button("Remove account", role: .destructive) { Keychain.remove("danbooru.login"); Keychain.remove("danbooru.key"); login = ""; apiKey = ""; status = "Account removed" }
            }
            Section("RedGIFs") { Text("Uses a temporary guest token. Account login and remote favorites are not offered by the verified API integration.").font(.footnote) }
            Section("Connection") {
                Button("Test Danbooru") { Task { await test(.danbooru) } }
                Button("Test RedGIFs") { Task { await test(.redgifs) } }
                if !status.isEmpty { Text(status).font(.footnote) }
            }
        }.navigationTitle("Sources / Accounts")
    }
    private func saveCredentials() {
        do { try Keychain.set(login, for: "danbooru.login"); try Keychain.set(apiKey, for: "danbooru.key"); status = "Credentials saved" }
        catch { status = error.localizedDescription }
    }
    private func test(_ source: SourceID) async {
        do { try await app.provider(source).testConnection(); status = "\(source.rawValue) connected" }
        catch { status = "\(source.rawValue): \(error.localizedDescription)" }
    }
}
