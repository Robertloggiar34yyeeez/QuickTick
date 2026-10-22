import SwiftUI
import UniformTypeIdentifiers

struct ImageStudioView: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var renderStatus = StudioRenderProgress()
    @AppStorage("quicktick-studio-intro-v1") private var introCompleted = false
    @State private var showIntro = false
    @State private var showImport = false
    @State private var showToken = false
    @State private var prompt = ""
    @State private var negativePrompt = "low quality, blurry, distorted anatomy, watermark"
    @State private var stepCount = 20.0
    @State private var guidance = 7.0
    @State private var seed = UInt32.random(in: 1...UInt32.max)
    @State private var installedModels: [URL] = []
    @State private var selectedModel: URL?
    @State private var savedImages: [URL] = []
    @State private var downloadedAssets: [URL] = []
    @State private var checkpoints: [CivitaiStudioModel] = []
    @State private var loras: [CivitaiStudioModel] = []
    @State private var searchQuery = "Anima"
    @State private var tokenDraft = ""
    @State private var useRed = true
    @State private var busy = false
    @State private var catalogBusy = false
    @State private var downloadBusyID: Int?
    @State private var status: String?
    @State private var latestImage: URL?
    @State private var taxonomy: VisualTagTaxonomy?
    @State private var renderTask: Task<Void, Never>?

    private var favorites: [Post] { Array(store.favorites.values) }
    private var inspiration: StudioPromptSeed { StudioPromptSeed.build(favorites: favorites, taxonomy: taxonomy) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                introduction
                promptPanel
                modelPanel
                generationPanel
                if let latestImage { generatedImage(latestImage) }
                civitaiPanel
                if !downloadedAssets.isEmpty { downloadedAssetsPanel }
                if !savedImages.isEmpty { galleryPanel }
            }
            .frame(maxWidth: 650)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 34)
        }
        .background(AppTheme.canvas.ignoresSafeArea())
        .navigationTitle("Create")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showIntro = true } label: { Image(systemName: "questionmark.circle") }
                    .accessibilityLabel("Image studio guide")
            }
        }
        .sheet(isPresented: $showIntro) { introSheet }
        .sheet(isPresented: $showToken) { tokenSheet }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.zip, .folder]) { result in
            if case .success(let url) = result {
                perform("Importing Core ML model…") {
                    let imported = try await LocalImageStudio.shared.importModel(url)
                    await reloadModels()
                    selectedModel = imported
                    status = "Ready to generate on this device."
                }
            } else if case .failure(let error) = result { status = error.localizedDescription }
        }
        .task {
            await reloadModels()
            savedImages = await LocalImageStudio.shared.savedImages()
            downloadedAssets = await LocalImageStudio.shared.downloadedAssets()
            taxonomy = await store.visual.metadataTaxonomy()
            if !introCompleted { showIntro = true }
        }
        .onDisappear { renderTask?.cancel() }
        .preferredColorScheme(.dark)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.title2).foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your imagination, locally.")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                    Text("Private Core ML image generation")
                        .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
                }
            }
            Text("Make something inspired by your favorite characters, artists and styles. Generation runs on your device; downloading models is optional and explicit.")
                .font(.subheadline).foregroundStyle(.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var promptPanel: some View {
        StudioPanel(title: "The idea", icon: "wand.and.stars") {
            HStack(spacing: 8) {
                Button {
                    prompt = inspiration.prompt
                } label: { Label("Fill from my favorites", systemImage: "heart.text.square.fill") }
                    .disabled(favorites.isEmpty)
                    .accessibilityIdentifier("studio-prompt-from-favorites")
                Spacer(minLength: 0)
                Text("\(favorites.count) saved")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.bordered)
            if !inspiration.characters.isEmpty || !inspiration.artists.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    if !inspiration.characters.isEmpty { inspirationRow("Characters", values: inspiration.characters) }
                    if !inspiration.artists.isEmpty { inspirationRow("Artists", values: inspiration.artists) }
                    if !inspiration.attributes.isEmpty { inspirationRow("Attributes & actions", values: inspiration.attributes) }
                    if !inspiration.scenes.isEmpty { inspirationRow("Scenes", values: inspiration.scenes) }
                }
            }
            TextEditor(text: $prompt)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 112)
                .padding(10)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(AppTheme.border))
                .accessibilityLabel("Image prompt")
                .accessibilityIdentifier("studio-prompt")
            Text("Avoid in the image")
                .font(.caption.weight(.medium)).foregroundStyle(AppTheme.secondaryLabel)
            TextField("Negative prompt", text: $negativePrompt, axis: .vertical)
                .lineLimit(2...3).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("studio-negative-prompt")
        }
    }

    private func inspirationRow(_ title: String, values: [String]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title + ":").font(.caption.weight(.semibold)).foregroundStyle(AppTheme.accent)
            Text(values.prefix(4).map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.white.opacity(0.75))
        }
    }

    private var modelPanel: some View {
        StudioPanel(title: "On-device model", icon: "cpu.fill") {
            if installedModels.isEmpty {
                Text("No compatible model installed yet")
                    .font(.subheadline.weight(.semibold))
                Text("The starter model is Apple's quantized Stable Diffusion 1.5. It downloads once and remains on your device. Prefer Anima? You can keep its CivitAI checkpoint, but it needs Core ML conversion before generation.")
                    .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
            } else {
                Menu {
                    ForEach(installedModels, id: \.path) { url in
                        Button(url.deletingLastPathComponent().lastPathComponent) { selectedModel = url }
                    }
                } label: {
                    HStack {
                        Label("\(selectedModel?.deletingLastPathComponent().lastPathComponent ?? "Choose model")", systemImage: "checkmark.seal.fill")
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .padding(13).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            HStack(spacing: 10) {
                Button { perform("Downloading model — several GB…") {
                    let path = try await LocalImageStudio.shared.downloadStarter()
                    await reloadModels(); selectedModel = path; status = "Starter model installed. Ready to generate."
                } } label: { Label("Get starter model", systemImage: "arrow.down.circle") }
                Button { showImport = true } label: { Label("Import Core ML", systemImage: "folder") }
            }
            .buttonStyle(.bordered)
            .disabled(busy)
            Text("Only compiled Core ML model bundles run in the current engine. Raw CivitAI checkpoints and LoRAs are saved separately; downloading one does not silently change the active model.")
                .font(.caption).foregroundStyle(.orange.opacity(0.88))
        }
    }

    private var generationPanel: some View {
        StudioPanel(title: "Render", icon: "slider.horizontal.3") {
            HStack {
                Text("Steps").font(.subheadline)
                Slider(value: $stepCount, in: 4...40, step: 1)
                Text("\(Int(stepCount))").font(.caption.monospacedDigit()).frame(width: 26)
            }
            HStack {
                Text("Guidance").font(.subheadline)
                Slider(value: $guidance, in: 1...15, step: 0.5)
                Text(guidance.formatted(.number.precision(.fractionLength(1))))
                    .font(.caption.monospacedDigit()).frame(width: 30)
            }
            HStack {
                Label("Seed \(seed)", systemImage: "dice")
                    .font(.caption.monospacedDigit()).foregroundStyle(AppTheme.secondaryLabel)
                Spacer()
                Button { seed = UInt32.random(in: 1...UInt32.max) } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Random seed")
            }
            Button(action: render) {
                HStack(spacing: 10) {
                    if busy { ProgressView().tint(.white) }
                    Label(busy ? "Working…" : "Generate image", systemImage: "sparkles")
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(QuicktickPressStyle())
            .disabled(busy || selectedModel == nil || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("studio-generate")
            if renderTask != nil {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: renderStatus.fraction)
                        .tint(AppTheme.accent)
                        .accessibilityIdentifier("studio-render-progress")
                    HStack {
                        Text("Denoising · \(Int(renderStatus.fraction * 100))%")
                            .font(.caption.monospacedDigit())
                        Spacer()
                        Button("Cancel render") { renderTask?.cancel() }
                            .font(.caption.weight(.semibold))
                    }
                }
            }
            if let status {
                Text(status).font(.caption).foregroundStyle(status.contains("failed") || status.contains("could not") ? Color.orange : AppTheme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("studio-status")
            }
        }
    }

    private func generatedImage(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Latest creation").font(.headline)
            if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
            }
            ShareLink(item: url) { Label("Share or save image", systemImage: "square.and.arrow.up") }
                .buttonStyle(.bordered)
        }
    }

    private var civitaiPanel: some View {
        StudioPanel(title: "Discover models & LoRAs", icon: "square.stack.3d.up") {
            Text("Find Anima checkpoints and character or artist LoRAs matching your saved interests. CivitAI downloads are not compatible with the Core ML renderer until converted or adapted.")
                .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
            HStack {
                TextField("Model or character", text: $searchQuery)
                    .textInputAutocapitalization(.never).textFieldStyle(.roundedBorder)
                Button { searchCatalog() } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderedProminent)
                    .disabled(catalogBusy || searchQuery.isEmpty)
            }
            HStack {
                Toggle("Use civitai.red", isOn: $useRed).font(.caption)
                Spacer()
                Button("API key") { tokenDraft = KeychainStore.get(account: "civitai-api-key") ?? ""; showToken = true }
                    .font(.caption)
            }
            Text("Suggested for your taste")
                .font(.caption.weight(.semibold)).foregroundStyle(AppTheme.secondaryLabel)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button { searchQuery = "Anima"; searchCatalog() } label: {
                        Label("Anima model", systemImage: "sparkles")
                    }
                    ForEach(inspiration.characters.prefix(3), id: \.self) { character in
                        Button { searchQuery = character; searchCatalog(onlyLoRA: true) } label: {
                            Label(character.replacingOccurrences(of: "_", with: " "), systemImage: "heart")
                        }
                    }
                    ForEach(inspiration.artists.prefix(2), id: \.self) { artist in
                        Button { searchQuery = artist; searchCatalog(onlyLoRA: true) } label: {
                            Label(artist.replacingOccurrences(of: "_", with: " "), systemImage: "paintpalette")
                        }
                    }
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.bordered)
                .disabled(catalogBusy)
            }
            if catalogBusy { ProgressView("Finding matching models…") }
            if !checkpoints.isEmpty {
                Text("Checkpoints").font(.subheadline.weight(.semibold))
                ForEach(checkpoints) { model in modelRow(model) }
            }
            if !loras.isEmpty {
                Text("LoRAs").font(.subheadline.weight(.semibold))
                ForEach(loras) { model in modelRow(model) }
            }
            if !catalogBusy && checkpoints.isEmpty && loras.isEmpty {
                Text("Search to browse models and artist/character LoRAs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func modelRow(_ model: CivitaiStudioModel) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.name).font(.subheadline.weight(.medium)).lineLimit(2)
                Text([model.type, model.latest?.baseModel].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
                if let words = model.latest?.trainedWords, !words.isEmpty {
                    Text(words.prefix(2).joined(separator: ", ")).font(.caption2).foregroundStyle(AppTheme.accent)
                }
            }
            Spacer(minLength: 6)
            Button {
                guard let version = model.latest else { return }
                downloadBusyID = model.id
                Task {
                    do {
                        _ = try await LocalImageStudio.shared.downloadCivitaiAsset(version, type: model.type,
                            host: useRed ? "civitai.red" : "civitai.com",
                            token: KeychainStore.get(account: "civitai-api-key"))
                        downloadedAssets = await LocalImageStudio.shared.downloadedAssets()
                        status = "Downloaded \(model.name). Conversion is required before use in Core ML."
                    } catch { status = "Download failed: \(error.localizedDescription)" }
                    downloadBusyID = nil
                }
            } label: { Image(systemName: downloadBusyID == model.id ? "hourglass" : "arrow.down.circle.fill") }
                .buttonStyle(QuicktickPressStyle()).font(.title3)
                .disabled(downloadBusyID != nil)
                .accessibilityLabel("Download \(model.name)")
        }
        .padding(12)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private var downloadedAssetsPanel: some View {
        StudioPanel(title: "Downloaded CivitAI assets", icon: "externaldrive") {
            Text("Stored privately for transfer or conversion. These assets are not active in the Core ML pipeline.")
                .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
            ForEach(downloadedAssets, id: \.path) { file in
                HStack(spacing: 10) {
                    Image(systemName: "doc.zipper").foregroundStyle(AppTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.deletingPathExtension().lastPathComponent)
                            .font(.caption.weight(.medium)).lineLimit(1)
                        Text(file.pathExtension.uppercased())
                            .font(.caption2).foregroundStyle(AppTheme.secondaryLabel)
                    }
                    Spacer(minLength: 4)
                    ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Export \(file.lastPathComponent)")
                    Button(role: .destructive) {
                        Task {
                            do {
                                try await LocalImageStudio.shared.deleteDownloadedAsset(file)
                                downloadedAssets = await LocalImageStudio.shared.downloadedAssets()
                            } catch { status = "Could not remove asset: \(error.localizedDescription)" }
                        }
                    } label: { Image(systemName: "trash") }
                        .accessibilityLabel("Delete \(file.lastPathComponent)")
                }
                .buttonStyle(QuicktickPressStyle())
                .frame(minHeight: 44)
            }
        }
    }

    private var galleryPanel: some View {
        StudioPanel(title: "My creations", icon: "photo.on.rectangle.angled") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                ForEach(savedImages.prefix(18), id: \.path) { url in
                    if let image = UIImage(contentsOfFile: url.path) {
                        ShareLink(item: url) {
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(height: 112).frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
        }
    }

    private var introSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: 45)).foregroundStyle(AppTheme.accent)
            Text("Create with QuickTick")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            ForEach([
                ("1", "Start with your taste", "Use your favorites to build a prompt from the characters, artists, actions and scenes you like."),
                ("2", "Prepare a local model", "Download the free Core ML starter model or import a compatible converted model. This is a large one-time download."),
                ("3", "Make it yours", "Render privately on your device, save your images, and discover related CivitAI assets.")
            ], id: \.0) { item in
                HStack(alignment: .top, spacing: 12) {
                    Text(item.0).font(.headline).foregroundStyle(.white)
                        .frame(width: 36, height: 36).background(AppTheme.gradient, in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.1).font(.headline)
                        Text(item.2).font(.subheadline).foregroundStyle(AppTheme.secondaryLabel)
                    }
                }
            }
            Spacer(minLength: 4)
            Button("Let's create") { introCompleted = true; showIntro = false }
                .font(.headline).foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityIdentifier("studio-intro-complete")
        }
        .padding(26).frame(maxWidth: 560)
        .presentationDetents([.large])
        .presentationBackground(AppTheme.elevatedSurface)
    }

    private var tokenSheet: some View {
        NavigationStack {
            Form {
                SecureField("CivitAI API key", text: $tokenDraft)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                Text("Stored only in iOS Keychain. It is sent as a bearer header to the selected CivitAI host, never added to download links.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle("CivitAI access")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try KeychainStore.set(tokenDraft, account: "civitai-api-key"); showToken = false }
                        catch { status = error.localizedDescription }
                    }
                }
            }
        }.presentationDetents([.medium])
    }

    private func searchCatalog(onlyLoRA: Bool = false) {
        guard !catalogBusy else { return }
        catalogBusy = true
        Task {
            defer { catalogBusy = false }
            do {
                let catalog = CivitaiStudioCatalog()
                let key = KeychainStore.get(account: "civitai-api-key")
                let host = useRed ? "civitai.red" : "civitai.com"
                let query = searchQuery
                if onlyLoRA {
                    checkpoints = []
                    loras = try await catalog.search(query, type: "LORA", host: host, token: key)
                } else {
                    async let foundCheckpoints = catalog.search(query, type: "Checkpoint", host: host, token: key)
                    async let foundLoras = catalog.search(query, type: "LORA", host: host, token: key)
                    (checkpoints, loras) = try await (foundCheckpoints, foundLoras)
                }
            } catch { status = "Catalog failed: \(error.localizedDescription)" }
        }
    }

    private func render() {
        guard let model = selectedModel, !busy,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        busy = true
        status = "Rendering on device…"
        renderStatus.fraction = 0
        let inputPrompt = prompt, inputNegative = negativePrompt
        let steps = Int(stepCount), scale = Float(guidance), inputSeed = seed
        let progress = renderStatus
        renderTask = Task {
            defer { busy = false; renderTask = nil }
            do {
                let result = try await LocalImageStudio.shared.generate(prompt: inputPrompt,
                    negative: inputNegative, modelURL: model, steps: steps, guidance: scale,
                    seed: inputSeed, onProgress: { finished, total in
                        Task { @MainActor in progress.fraction = Double(finished) / Double(max(1, total)) }
                    })
                try Task.checkCancellation()
                latestImage = result
                savedImages = await LocalImageStudio.shared.savedImages()
                status = "Created entirely on this device."
            } catch is CancellationError {
                status = "Render cancelled."
            } catch { status = "Render failed: \(error.localizedDescription)" }
        }
    }

    private func reloadModels() async {
        installedModels = await LocalImageStudio.shared.installedModelDirectories()
        if let selectedModel, installedModels.contains(selectedModel) { return }
        selectedModel = installedModels.first
    }

    private func perform(_ label: String, action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; status = label
        Task {
            defer { busy = false }
            do { try await action() }
            catch { status = "Operation failed: \(error.localizedDescription)" }
        }
    }
}

@MainActor private final class StudioRenderProgress: ObservableObject {
    @Published var fraction = 0.0
}

private struct StudioPanel<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content
    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.system(.headline, design: .rounded, weight: .bold))
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(14)
                .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(AppTheme.border))
        }
        .tint(AppTheme.accent)
    }
}
