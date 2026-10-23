import SwiftUI
import UniformTypeIdentifiers
import ImageIO

struct ImageStudioView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var renderStatus = StudioRenderProgress()
    @StateObject private var transferStatus = StudioTransferProgress()
    @AppStorage("quicktick-studio-intro-v1") private var introCompleted = false
    @State private var showIntro = false
    @State private var showImport = false
    @State private var showToken = false
    @State private var showCatalog = false
    @State private var showAdvanced = false
    @State private var glowActive = false
    @State private var prompt = ""
    @State private var negativePrompt = "low quality, blurry, distorted anatomy, watermark"
    @State private var stepCount = 20.0
    @State private var guidance = 7.0
    @State private var aspect: StudioAspectRatio = .square
    @State private var scheduler: StudioScheduler = .dpm
    @State private var highResolution = false
    @State private var animeUpscalerReady = false
    @State private var seed = UInt32.random(in: 1...UInt32.max)
    @State private var installedModels: [URL] = []
    @State private var selectedModel: URL?
    @State private var savedImages: [URL] = []
    @State private var downloadedAssets: [URL] = []
    @State private var checkpoints: [CivitaiStudioModel] = []
    @State private var loras: [CivitaiStudioModel] = []
    @State private var searchQuery = ""
    @State private var tokenDraft = ""
    @State private var useRed = true
    @State private var busy = false
    @State private var catalogBusy = false
    @State private var downloadBusyID: Int?
    @State private var catalogKind: StudioCatalogKind = .lora
    @State private var status: String?
    @State private var latestImage: URL?
    @State private var taxonomy: VisualTagTaxonomy?
    @State private var inspiration = StudioPromptSeed(characters: [], artists: [], attributes: [], scenes: [])
    @FocusState private var promptFocused: Bool
    @State private var renderTask: Task<Void, Never>?
    @State private var downloadTask: Task<Void, Never>?

    private var favorites: [Post] { Array(store.favorites.values) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                studioHero
                if let latestImage { generatedImage(latestImage) }
                modelPanel
                libraryLauncher
                if !savedImages.isEmpty { galleryPanel }
            }
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 34)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(StudioAuroraBackground().ignoresSafeArea())
        .navigationTitle("Create")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showIntro = true } label: { Image(systemName: "questionmark.circle") }
                    .accessibilityLabel("Image studio guide")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { promptFocused = false }
            }
        }
        .sheet(isPresented: $showIntro) { introSheet }
        .sheet(isPresented: $showToken) { tokenSheet }
        .sheet(isPresented: $showCatalog) { catalogSheet }
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
            animeUpscalerReady = await LocalImageStudio.shared.hasAnimeUpscaler()
            taxonomy = await store.visual.metadataTaxonomy()
            inspiration = StudioPromptSeed.build(favorites: favorites, taxonomy: taxonomy)
            if !introCompleted { showIntro = true }
        }
        .onChange(of: store.favorites) { _, newFavorites in
            inspiration = StudioPromptSeed.build(favorites: Array(newFavorites.values), taxonomy: taxonomy)
        }
        .onDisappear {
            renderTask?.cancel()
            downloadTask?.cancel()
        }
        .preferredColorScheme(.dark)
    }

    private var studioHero: some View {
        VStack(spacing: 18) {
            HStack {
                Label("QUICKTICK STUDIO", systemImage: "sparkles")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Label("ON DEVICE", systemImage: "lock.shield.fill")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.67))
            }
            Spacer(minLength: 8)
            VStack(spacing: 5) {
                Text("Imagine anything.")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .tracking(-0.8)
                Text("Made by you. Created privately.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.65))
            }
            .frame(maxWidth: .infinity)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 20).fill(.black.opacity(0.36))
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.20)))
                if prompt.isEmpty {
                    Text("A beautiful scene with your favorite character…")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.43))
                        .padding(.horizontal, 19).padding(.top, 20)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $prompt)
                    .focused($promptFocused)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .padding(12)
                    .frame(height: 130)
                    .accessibilityLabel("Image prompt")
                    .accessibilityIdentifier("studio-prompt")
            }
            .frame(height: 130)
            Button(action: generateFromFavorites) {
                HStack(spacing: 8) {
                    Image(systemName: "heart.text.square.fill")
                    Text("Generate something I'd love")
                }
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(.white.opacity(0.13), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.20)))
            }
            .buttonStyle(QuicktickPressStyle())
            .disabled(busy)
            .accessibilityIdentifier("studio-generate-from-favorites")
            Button { render() } label: {
                HStack(spacing: 10) {
                    if busy { ProgressView().tint(.white) }
                    Image(systemName: "sparkles")
                        .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion && !busy)
                    Text(busy ? "Creating…" : "Generate")
                }
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 58)
                .background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: 21))
                .overlay(RoundedRectangle(cornerRadius: 21).stroke(.white.opacity(0.45)))
                .shadow(color: AppTheme.accent.opacity(glowActive ? 0.85 : 0.32), radius: glowActive ? 27 : 12, y: 3)
                .scaleEffect(glowActive && !reduceMotion ? 1.012 : 1)
            }
            .buttonStyle(QuicktickPressStyle())
            .disabled(busy)
            .accessibilityIdentifier("studio-generate")
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true)) { glowActive = true }
            }
            if renderTask != nil {
                ProgressView(value: renderStatus.fraction)
                    .tint(.white)
                    .accessibilityIdentifier("studio-render-progress")
                HStack {
                    Text("Rendering · \(Int(renderStatus.fraction * 100))%")
                    Spacer()
                    Button("Stop render") { renderTask?.cancel() }
                }
                .font(.caption)
            }
            if let status {
                Text(status).font(.caption).foregroundStyle(.white.opacity(0.80))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityIdentifier("studio-status")
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minHeight: 448)
        .background {
            RoundedRectangle(cornerRadius: 30).fill(Color(red: 0.08, green: 0.06, blue: 0.17).opacity(0.87))
                .overlay(StudioAuroraBackground().clipShape(RoundedRectangle(cornerRadius: 30)).opacity(0.85))
        }
        .overlay(RoundedRectangle(cornerRadius: 30).stroke(.white.opacity(0.15)))
    }

    private func inspirationRow(_ title: String, values: [String]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title + ":").font(.caption.weight(.semibold)).foregroundStyle(AppTheme.accent)
            Text(values.prefix(4).map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.white.opacity(0.75))
        }
    }

    private var modelPanel: some View {
        StudioPanel(title: "On-device engine", icon: "cpu.fill") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    Button {
                        if installedModels.isEmpty { beginStarterDownload() }
                        else { status = "Apple Core ML is the active generation engine." }
                    } label: {
                        engineChip("Apple SD 1.5", detail: installedModels.isEmpty ? "1.57 GB · Get" : "Ready to create",
                                   icon: "cpu.fill", active: !installedModels.isEmpty)
                    }
                    Button {
                        showCatalog = true
                        catalogKind = .checkpoint
                        searchQuery = "Anima"
                        status = "Anima checkpoint files are stored, but need an Anima-compatible Metal engine plus text encoder and VAE. Apple Core ML cannot load them."
                    } label: {
                        engineChip("Anima", detail: downloadedAssets.contains { $0.lastPathComponent.hasPrefix("checkpoint-") } ? "Raw file stored" : "Explore model",
                                   icon: "sparkle.magnifyingglass", active: false)
                    }
                    Button {
                        if !animeUpscalerReady { beginAnimeUpscalerDownload() }
                        else { highResolution = true }
                    } label: {
                        engineChip("Real-ESRGAN 4×", detail: animeUpscalerReady ? "Ready · Anime" : "8.5 MB · Get",
                                   icon: "arrow.up.left.and.arrow.down.right", active: animeUpscalerReady)
                    }
                }
                .buttonStyle(QuicktickPressStyle())
            }
            Text("Core ML runs compatible converted models. Downloaded Anima safetensors and LoRAs cannot run in this engine yet.")
                .font(.caption2).foregroundStyle(AppTheme.secondaryLabel)
            if !installedModels.isEmpty {
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
                    .padding(12).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            HStack(spacing: 10) {
                Button(action: beginStarterDownload) {
                    Label(installedModels.isEmpty ? "Get Core ML" : "Add Core ML", systemImage: "arrow.down.circle")
                }
                Button { showImport = true } label: { Label("Import Core ML", systemImage: "folder") }
            }
            .buttonStyle(.bordered)
            .disabled(busy || transferStatus.isActive)
            if transferStatus.isActive { downloadProgressPanel }
            outputControls
            DisclosureGroup(isExpanded: $showAdvanced) {
                generationPanel
                    .padding(.top, 8)
            } label: {
                Label("Advanced render settings", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.medium))
            }
            .tint(AppTheme.accent)
        }
    }

    private func engineChip(_ title: String, detail: String, icon: String, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(active ? .green : AppTheme.accent)
                Text(title).font(.caption.weight(.bold))
                if active { Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green) }
            }
            Text(detail).font(.caption2).foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(active ? AppTheme.accent.opacity(0.22) : AppTheme.surface,
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(active ? AppTheme.accent.opacity(0.65) : AppTheme.border))
    }

    private var outputControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Aspect ratio").font(.caption.weight(.semibold))
            HStack(spacing: 7) {
                ForEach(StudioAspectRatio.allCases) { ratio in
                    Button { aspect = ratio } label: {
                        Text(ratio.label).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(StudioOptionChipStyle(isSelected: aspect == ratio))
                    .accessibilityIdentifier("studio-aspect-\(ratio.rawValue)")
                }
            }
            Text("Output resolution").font(.caption.weight(.semibold))
            HStack(spacing: 7) {
                Button { highResolution = false } label: {
                    Label("Native", systemImage: "photo")
                }
                .buttonStyle(StudioOptionChipStyle(isSelected: !highResolution))
                Button {
                    if animeUpscalerReady { highResolution = true }
                    else { beginAnimeUpscalerDownload() }
                } label: {
                    Label(animeUpscalerReady ? "Anime 4×" : "Get Anime 4×", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(StudioOptionChipStyle(isSelected: highResolution))
                .accessibilityIdentifier("studio-anime-upscaler")
            }
            Text("Core ML renders at its native size. Other aspect ratios center-crop the output; Anime 4× enlarges it with Real-ESRGAN.")
                .font(.caption2).foregroundStyle(AppTheme.secondaryLabel)
        }
    }

    private var downloadProgressPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(transferStatus.name)
                    .font(.caption.weight(.semibold)).lineLimit(1)
                Spacer()
                Text(transferStatus.progressLabel)
                    .font(.caption.monospacedDigit()).foregroundStyle(AppTheme.accent)
            }
            if let fraction = transferStatus.fraction {
                ProgressView(value: fraction)
                    .tint(AppTheme.accent)
                    .accessibilityIdentifier("studio-download-progress")
            } else {
                ProgressView().tint(AppTheme.accent)
                    .accessibilityIdentifier("studio-download-progress")
            }
            Text(transferStatus.sizeLabel)
                .font(.caption2).foregroundStyle(AppTheme.secondaryLabel)
            HStack(spacing: 12) {
                if transferStatus.phase == .running || transferStatus.phase == .paused {
                    Button {
                        Task {
                            if transferStatus.phase == .running {
                                await LocalImageStudio.shared.pauseActiveDownload()
                                transferStatus.phase = .paused
                            } else {
                                await LocalImageStudio.shared.resumeActiveDownload()
                                transferStatus.phase = .running
                            }
                        }
                    } label: {
                        Label(transferStatus.phase == .paused ? "Resume" : "Pause",
                              systemImage: transferStatus.phase == .paused ? "play.fill" : "pause.fill")
                    }
                    .disabled(transferStatus.phase == .running && transferStatus.received == 0)
                    .accessibilityIdentifier("studio-download-pause-resume")
                    Button(role: .destructive) { stopDownload() } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .accessibilityIdentifier("studio-download-stop")
                } else {
                    Text("Preparing downloaded model…").font(.caption)
                }
            }
            .buttonStyle(.bordered)
            .font(.caption.weight(.semibold))
        }
        .padding(12)
        .background(AppTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
    }

    private var libraryLauncher: some View {
        Button { showCatalog = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.title3).foregroundStyle(AppTheme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Explore LoRAs & models").font(.subheadline.weight(.semibold))
                    Text("Discover Anima, characters and artists")
                        .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.5))
            }
            .foregroundStyle(.white)
            .padding(16)
            .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(AppTheme.border))
        }
        .buttonStyle(QuicktickPressStyle())
        .accessibilityIdentifier("studio-open-lora-menu")
    }

    private var generationPanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("Scheduler").font(.caption.weight(.semibold))
                Spacer()
                ForEach(StudioScheduler.allCases) { candidate in
                    Button(candidate.label) { scheduler = candidate }
                        .buttonStyle(StudioOptionChipStyle(isSelected: scheduler == candidate))
                }
            }
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
            TextField("Avoid: blurry, distorted anatomy…", text: $negativePrompt, axis: .vertical)
                .lineLimit(1...2).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("studio-negative-prompt")
        }
    }

    private func generatedImage(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Latest creation").font(.headline)
            StudioImageThumbnail(url: url, maxPixelDimension: 1200, fill: false)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 20))
            ShareLink(item: url) { Label("Share or save image", systemImage: "square.and.arrow.up") }
                .buttonStyle(.bordered)
        }
    }

    private var catalogSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Explore", selection: $catalogKind) {
                        ForEach(StudioCatalogKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("studio-catalog-kind")
                    HStack {
                        TextField("Search \(catalogKind.title.lowercased())", text: $searchQuery)
                            .textInputAutocapitalization(.never)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.search)
                            .onSubmit { searchCatalog() }
                            .accessibilityIdentifier("studio-catalog-search")
                        Button { searchCatalog() } label: { Image(systemName: "magnifyingglass") }
                            .buttonStyle(.borderedProminent)
                            .disabled(catalogBusy || searchQuery.isEmpty)
                    }
                    HStack {
                        Toggle("civitai.red", isOn: $useRed).font(.caption)
                        Spacer()
                        Button("API key") {
                            tokenDraft = KeychainStore.get(account: "civitai-api-key") ?? ""
                            showToken = true
                        }.font(.caption)
                    }
                    Text("Suggested from your favorites")
                        .font(.subheadline.weight(.semibold))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Button { catalogKind = .checkpoint; searchQuery = "Anima"; searchCatalog() } label: {
                                Label("Anima", systemImage: "sparkles")
                            }
                            ForEach(inspiration.characters.prefix(3), id: \.self) { character in
                                Button { catalogKind = .lora; searchQuery = character; searchCatalog() } label: {
                                    Label(character.replacingOccurrences(of: "_", with: " "), systemImage: "heart")
                                }
                            }
                            ForEach(inspiration.artists.prefix(2), id: \.self) { artist in
                                Button { catalogKind = .lora; searchQuery = artist; searchCatalog() } label: {
                                    Label(artist.replacingOccurrences(of: "_", with: " "), systemImage: "paintpalette")
                                }
                            }
                        }
                        .font(.caption.weight(.medium))
                        .buttonStyle(.bordered)
                        .disabled(catalogBusy)
                    }
                    if transferStatus.isActive { downloadProgressPanel }
                    if catalogBusy { ProgressView("Finding \(catalogKind.title.lowercased())…") }
                    ForEach(catalogKind == .lora ? loras : checkpoints) { model in modelRow(model) }
                    if !catalogBusy && (catalogKind == .lora ? loras : checkpoints).isEmpty {
                        Text("Search for a character, artist or model to see available downloads.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("CivitAI checkpoints and LoRAs are saved locally. Raw files need conversion to run with Core ML.")
                        .font(.caption).foregroundStyle(.orange.opacity(0.9))
                    if let status { Text(status).font(.caption).foregroundStyle(AppTheme.secondaryLabel) }
                    if !downloadedAssets.isEmpty { downloadedAssetsPanel }
                }
                .padding(16)
            }
            .background(StudioAuroraBackground().ignoresSafeArea())
            .navigationTitle("Model library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { showCatalog = false } }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func modelRow(_ model: CivitaiStudioModel) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.name).font(.subheadline.weight(.medium)).lineLimit(2)
                Text([model.type, model.latest?.baseModel].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
                if let size = model.latest?.displaySize {
                    Text(size).font(.caption2).foregroundStyle(.white.opacity(0.60))
                }
                if let words = model.latest?.trainedWords, !words.isEmpty {
                    Text(words.prefix(2).joined(separator: ", ")).font(.caption2).foregroundStyle(AppTheme.accent)
                }
            }
            Spacer(minLength: 6)
            Button { beginAssetDownload(model) } label: {
                Image(systemName: downloadBusyID == model.id ? "hourglass" : "arrow.down.circle.fill")
            }
                .buttonStyle(QuicktickPressStyle()).font(.title3)
                .disabled(transferStatus.isActive || downloadBusyID != nil)
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
                    ShareLink(item: url) {
                        StudioImageThumbnail(url: url, maxPixelDimension: 240, fill: true)
                            .frame(height: 112).frame(maxWidth: .infinity)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 12))
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

    private func searchCatalog() {
        guard !catalogBusy else { return }
        catalogBusy = true
        Task {
            defer { catalogBusy = false }
            do {
                let catalog = CivitaiStudioCatalog()
                let key = KeychainStore.get(account: "civitai-api-key")
                let host = useRed ? "civitai.red" : "civitai.com"
                let query = searchQuery
                if catalogKind == .lora {
                    checkpoints = []
                    loras = try await catalog.search(query, type: "LORA", host: host, token: key)
                } else {
                    loras = []
                    checkpoints = try await catalog.search(query, type: "Checkpoint", host: host, token: key)
                }
            } catch { status = "Catalog failed: \(error.localizedDescription)" }
        }
    }

    private func generateFromFavorites() {
        promptFocused = false
        guard !favorites.isEmpty else {
            status = "Like a few characters, artists or scenes in your feed first. I'll turn your favorites into an image idea."
            return
        }
        let lovedPrompt = inspiration.prompt
        prompt = lovedPrompt
        if selectedModel != nil { render(promptOverride: lovedPrompt) }
        else { status = "Your idea is ready. Download or import a Core ML model to generate it." }
    }

    private func beginStarterDownload() {
        guard !transferStatus.isActive, !busy else { return }
        let identity = transferStatus.begin("Apple SD 1.5 · 6-bit", estimatedBytes: 1_570_000_000)
        let progress = transferStatus
        status = "Downloading the private on-device model…"
        downloadTask = Task {
            defer { progress.finish(identity); downloadTask = nil }
            do {
                let model = try await LocalImageStudio.shared.downloadStarter(onProgress: { received, total in
                    Task { @MainActor in progress.update(identity, received: received, expected: total) }
                })
                try Task.checkCancellation()
                await reloadModels()
                selectedModel = model
                status = "Model installed. Ready to create offline."
            } catch is CancellationError {
                status = "Download stopped."
            } catch let error as URLError where error.code == .cancelled {
                status = "Download stopped."
            } catch { status = "Model download failed: \(error.localizedDescription)" }
        }
    }

    private func beginAnimeUpscalerDownload() {
        guard !animeUpscalerReady, !transferStatus.isActive, !busy else { return }
        let identity = transferStatus.begin(StudioAnimeUpscaler.name, estimatedBytes: StudioAnimeUpscaler.estimatedBytes)
        let progress = transferStatus
        status = "Downloading the Anime 4× on-device upscaler…"
        downloadTask = Task {
            defer { progress.finish(identity); downloadTask = nil }
            do {
                try await LocalImageStudio.shared.downloadAnimeUpscaler(onProgress: { received, total in
                    Task { @MainActor in progress.update(identity, received: received, expected: total) }
                })
                try Task.checkCancellation()
                animeUpscalerReady = await LocalImageStudio.shared.hasAnimeUpscaler()
                if animeUpscalerReady {
                    highResolution = true
                    status = "Anime 4× installed. Your next creation can be upscaled offline."
                }
            } catch is CancellationError {
                status = "Upscaler download stopped."
            } catch let error as URLError where error.code == .cancelled {
                status = "Upscaler download stopped."
            } catch { status = "Upscaler install failed: \(error.localizedDescription)" }
        }
    }

    private func beginAssetDownload(_ model: CivitaiStudioModel) {
        guard let version = model.latest, !transferStatus.isActive else { return }
        let identity = transferStatus.begin(model.name, estimatedBytes: 0)
        let progress = transferStatus
        downloadBusyID = model.id
        downloadTask = Task {
            defer { progress.finish(identity); downloadBusyID = nil; downloadTask = nil }
            do {
                _ = try await LocalImageStudio.shared.downloadCivitaiAsset(version, type: model.type,
                    host: useRed ? "civitai.red" : "civitai.com",
                    token: KeychainStore.get(account: "civitai-api-key"),
                    onProgress: { received, total in
                        Task { @MainActor in progress.update(identity, received: received, expected: total) }
                    })
                try Task.checkCancellation()
                downloadedAssets = await LocalImageStudio.shared.downloadedAssets()
                status = "Saved \(model.name). Convert it before using it in Core ML."
            } catch is CancellationError {
                status = "Download stopped."
            } catch let error as URLError where error.code == .cancelled {
                status = "Download stopped."
            } catch { status = "Download failed: \(error.localizedDescription)" }
        }
    }

    private func stopDownload() {
        guard transferStatus.isActive else { return }
        transferStatus.phase = .stopping
        downloadTask?.cancel()
        Task { await LocalImageStudio.shared.stopActiveDownload() }
    }

    private func render(promptOverride: String? = nil) {
        promptFocused = false
        guard !busy else { return }
        guard let model = selectedModel else {
            status = "Download the local model below or import a compatible Core ML model first."
            return
        }
        guard !(promptOverride ?? prompt).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "Describe your idea in the prompt, or use your favorites for inspiration."
            return
        }
        guard !highResolution || animeUpscalerReady else {
            status = "Download Real-ESRGAN X4+ Anime before selecting 4× resolution."
            return
        }
        busy = true
        status = "Rendering on device…"
        renderStatus.fraction = 0
        let inputPrompt = promptOverride ?? prompt, inputNegative = negativePrompt
        let steps = Int(stepCount), scale = Float(guidance), inputSeed = seed
        let selectedAspect = aspect, selectedScheduler = scheduler, shouldUpscale = highResolution
        let progress = renderStatus
        renderTask = Task {
            defer { busy = false; renderTask = nil }
            do {
                let result = try await LocalImageStudio.shared.generate(prompt: inputPrompt,
                    negative: inputNegative, modelURL: model, steps: steps, guidance: scale,
                    seed: inputSeed, aspect: selectedAspect, scheduler: selectedScheduler,
                    upscale: shouldUpscale, onProgress: { finished, total in
                        Task { @MainActor in
                            progress.fraction = Double(finished) / Double(max(1, total))
                            if shouldUpscale && finished >= total {
                                status = "Diffusion finished · applying Anime 4× enhancement…"
                            }
                        }
                    })
                try Task.checkCancellation()
                latestImage = result
                savedImages = await LocalImageStudio.shared.savedImages()
                status = shouldUpscale ? "Created and enhanced 4× entirely on this device." : "Created entirely on this device."
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

private struct StudioOptionChipStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(isSelected ? .white : .white.opacity(0.8))
            .padding(.horizontal, 11).padding(.vertical, 10)
            .background(isSelected ? AppTheme.accent.opacity(0.48) : AppTheme.surface,
                        in: Capsule())
            .overlay(Capsule().stroke(isSelected ? AppTheme.accent : AppTheme.border))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

/// Decode small previews only when the gallery row is first displayed. In
/// particular, a download progress update must never re-decode 18 full PNGs.
private struct StudioImageThumbnail: View {
    let url: URL
    let maxPixelDimension: Int
    let fill: Bool
    @State private var preview: UIImage?

    var body: some View {
        Group {
            if let preview {
                if fill { Image(uiImage: preview).resizable().scaledToFill() }
                else { Image(uiImage: preview).resizable().scaledToFit() }
            } else {
                RoundedRectangle(cornerRadius: 12).fill(AppTheme.surface)
                    .overlay(ProgressView().tint(AppTheme.accent))
            }
        }
        .task(id: url) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
                kCGImageSourceShouldCacheImmediately: true
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                preview = UIImage(cgImage: image)
            }
        }
    }
}

@MainActor private final class StudioRenderProgress: ObservableObject {
    @Published var fraction = 0.0
}

private enum StudioCatalogKind: String, CaseIterable, Identifiable {
    case lora, checkpoint
    var id: String { rawValue }
    var title: String { self == .lora ? "LoRAs" : "Checkpoints" }
}

@MainActor private final class StudioTransferProgress: ObservableObject {
    enum Phase: Equatable { case idle, running, paused, installing, stopping }
    @Published var phase: Phase = .idle
    @Published private(set) var name = ""
    @Published private(set) var received: Int64 = 0
    @Published private(set) var expected: Int64 = 0
    private var estimated: Int64 = 0
    private var identity: UUID?

    var isActive: Bool { phase != .idle }
    var fraction: Double? { expected > 0 ? min(1, Double(received) / Double(expected)) : nil }
    var progressLabel: String {
        if phase == .paused { return "Paused" }
        if phase == .stopping { return "Stopping…" }
        if phase == .installing { return "Installing…" }
        return fraction.map { "\(Int($0 * 100))%" } ?? "Downloading…"
    }
    var sizeLabel: String {
        let downloaded = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        let total = expected > 0 ? expected : estimated
        guard total > 0 else { return downloaded + " downloaded" }
        return downloaded + " / " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    func begin(_ title: String, estimatedBytes: Int64) -> UUID {
        let key = UUID()
        identity = key
        name = title
        received = 0; expected = 0; estimated = estimatedBytes
        phase = .running
        return key
    }

    func update(_ key: UUID, received: Int64, expected: Int64) {
        guard identity == key, phase != .stopping else { return }
        self.received = max(0, received)
        self.expected = max(0, expected)
        if expected > 0, received >= expected { phase = .installing }
    }

    func finish(_ key: UUID) {
        guard identity == key else { return }
        identity = nil
        phase = .idle
    }
}

private struct StudioAuroraBackground: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(red: 0.025, green: 0.025, blue: 0.07)
                RadialGradient(colors: [Color(red: 0.40, green: 0.23, blue: 0.70).opacity(0.65), .clear],
                               center: .init(x: 0.15, y: 0.10), startRadius: 0, endRadius: geometry.size.width * 0.9)
                RadialGradient(colors: [Color(red: 0.13, green: 0.43, blue: 0.72).opacity(0.44), .clear],
                               center: .init(x: 0.95, y: 0.70), startRadius: 0, endRadius: geometry.size.width * 1.1)
                ForEach(0..<22, id: \.self) { index in
                    Circle().fill(.white.opacity(index.isMultiple(of: 4) ? 0.65 : 0.27))
                        .frame(width: index.isMultiple(of: 5) ? 2.5 : 1.5,
                               height: index.isMultiple(of: 5) ? 2.5 : 1.5)
                        .position(x: geometry.size.width * CGFloat((index * 37 + 11) % 97) / 97,
                                  y: geometry.size.height * CGFloat((index * 53 + 17) % 89) / 89)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
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
