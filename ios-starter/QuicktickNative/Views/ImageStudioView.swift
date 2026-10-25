import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ImageIO

struct ImageStudioView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var renderStatus = StudioRenderProgress()
    @StateObject private var transferStatus = StudioTransferProgress()
    @AppStorage("quicktick-studio-intro-v1") private var introCompleted = false
    @AppStorage("quicktick-studio-anima-checkpoint-v1") private var savedAnimaCheckpointName = ""
    @AppStorage("quicktick-studio-lora-strengths-v1") private var savedLoRAStrengthsJSON = "{}"
    @AppStorage("quicktick-studio-lora-triggers-v1") private var savedLoRATriggersJSON = "{}"
    @AppStorage("quicktick-studio-lora-names-v1") private var savedLoRANamesJSON = "{}"
    @AppStorage("quicktick-studio-coreml-safety-v1") private var coreMLSafetyCheck = true
    @AppStorage("quicktick-modern-ui-v1") private var modernUI = true
    @AppStorage("quicktick-drawthings-experimental-v1") private var useDrawThings = false
    @State private var showIntro = false
    @State private var showSetupLoRAChoice = false
    @State private var showImport = false
    @State private var showAnimaImport = false
    @State private var showLoRAImport = false
    @State private var showToken = false
    @State private var showCatalog = false
    @State private var showAdvanced = false
    @State private var prompt = ""
    @State private var negativePrompt = "low quality, blurry, distorted anatomy, watermark"
    @State private var stepCount = 8.0
    @State private var guidance = 2.0
    @State private var aspect: StudioAspectRatio = .square
    @State private var animaLongestEdge = 512.0
    @State private var scheduler: StudioScheduler = .dpm
    @State private var highResolution = false
    @State private var animeUpscalerReady = false
    @State private var seed = UInt32.random(in: 1...UInt32.max)
    @State private var installedModels: [URL] = []
    @State private var selectedModel: URL?
    @State private var selectedEngine: StudioGenerationEngine = .coreML
    @State private var animaReady = false
    @State private var drawThingsReady = false
    @State private var drawThingsConversion = 0.0
    @State private var selectedAnimaCheckpoint: URL?
    @State private var selectedLoRAStrengths: [String: Double] = [:]
    @State private var loRATriggerWords: [String: String] = [:]
    @State private var loRANames: [String: String] = [:]
    @State private var showGenerationFocus = false
    @State private var renderPreview: URL?
    @State private var renderSequence = UUID()
    @State private var activeRenderPrompt = ""
    @State private var renderStage = "Preparing the canvas"
    @State private var renderPhase: StudioRenderPhase = .idle
    @State private var renderProgressHasExactSteps = false
    @State private var savedImages: [URL] = []
    @State private var savedPromptMetadata: [String: StudioGenerationMetadata] = [:]
    @State private var viewingImage: StudioImageSelection?
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
        studioLifecycle
    }

    // Keeping lifecycle, presentation and layout in separately inferred view
    // expressions prevents Xcode's Swift type checker from timing out while
    // archiving this feature-rich screen in Release configuration.
    private var studioSurface: some View {
        ZStack {
            if showGenerationFocus {
                focusedGenerationView
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        studioHero
                        if let latestImage { generatedImage(latestImage) }
                        modelPanel
                        libraryLauncher
                        if !savedImages.isEmpty { galleryPanel }
                    }
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 48)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .background(StudioAuroraBackground().ignoresSafeArea())
        .navigationTitle(showGenerationFocus ? "" : "Create")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(showGenerationFocus ? .hidden : .visible, for: .navigationBar)
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
    }

    private var studioPresentations: some View {
        studioSurface
        .sheet(isPresented: $showIntro) { introSheet }
        .sheet(isPresented: $showToken) { tokenSheet }
        .sheet(isPresented: $showCatalog) { catalogSheet }
        .fullScreenCover(item: $viewingImage) { selection in
            fullscreenCreation(selection.url)
        }
        .alert("Add a LoRA?", isPresented: $showSetupLoRAChoice) {
            Button("Browse LoRAs") {
                catalogKind = .lora
                searchQuery = inspiration.characters.first ?? inspiration.artists.first ?? "Anima"
                showCatalog = true
                searchCatalog()
            }
            Button("Not now", role: .cancel) { }
        } message: {
            Text("Anima is selected. Add a character or artist LoRA, or continue without one. Selected LoRAs are applied during generation.")
        }
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
    }

    private var studioObservers: some View {
        studioPresentations
        .task {
            await reloadModels()
            savedImages = await LocalImageStudio.shared.savedImages()
            savedPromptMetadata = await LocalImageStudio.shared.generationMetadata(for: Array(savedImages.prefix(18)))
            downloadedAssets = await LocalImageStudio.shared.downloadedAssets()
            let savedLoRAs = (try? JSONDecoder().decode([String: Double].self, from: Data(savedLoRAStrengthsJSON.utf8))) ?? [:]
            let availableNames = Set(downloadedAssets.map(\.lastPathComponent))
            selectedLoRAStrengths = savedLoRAs.filter { availableNames.contains($0.key) }
            loRATriggerWords = (try? JSONDecoder().decode([String: String].self, from: Data(savedLoRATriggersJSON.utf8))) ?? [:]
            loRANames = (try? JSONDecoder().decode([String: String].self, from: Data(savedLoRANamesJSON.utf8))) ?? [:]
            selectedAnimaCheckpoint = downloadedAssets.first { $0.lastPathComponent == savedAnimaCheckpointName }
            animeUpscalerReady = await LocalImageStudio.shared.hasAnimeUpscaler()
            let fullAnimaReady = await LocalImageStudio.shared.hasAnimaBundle()
            let animaAuxiliaryReady = await LocalImageStudio.shared.hasAnimaAuxiliaryFiles()
            animaReady = fullAnimaReady || (selectedAnimaCheckpoint != nil && animaAuxiliaryReady)
#if canImport(_MediaGenerationKit) && canImport(ModelOp) && canImport(ModelZoo) && canImport(DataModels)
            drawThingsReady = await DrawThingsAnimaBridge.shared.isReady(checkpoint: selectedAnimaCheckpoint)
#endif
            if animaReady && (selectedAnimaCheckpoint != nil || installedModels.isEmpty) {
                selectedEngine = .anima
            }
            taxonomy = await store.visual.metadataTaxonomy()
            inspiration = StudioPromptSeed.build(favorites: favorites, taxonomy: taxonomy)
            if !introCompleted { showIntro = true }
        }
        .onChange(of: store.favorites) { _, newFavorites in
            inspiration = StudioPromptSeed.build(favorites: Array(newFavorites.values), taxonomy: taxonomy)
        }
    }

    private var studioLifecycle: some View {
        studioObservers
        .onChange(of: selectedLoRAStrengths) { _, newSelection in
            if let data = try? JSONEncoder().encode(newSelection), let encoded = String(data: data, encoding: .utf8) {
                savedLoRAStrengthsJSON = encoded
            }
        }
        .onChange(of: loRATriggerWords) { _, values in
            if let data = try? JSONEncoder().encode(values), let encoded = String(data: data, encoding: .utf8) {
                savedLoRATriggersJSON = encoded
            }
        }
        .onChange(of: loRANames) { _, values in
            if let data = try? JSONEncoder().encode(values), let encoded = String(data: data, encoding: .utf8) {
                savedLoRANamesJSON = encoded
            }
        }
        .onChange(of: selectedAnimaCheckpoint) { previous, checkpoint in
            // Restoring the saved checkpoint (nil -> file) during .task is not
            // a user model switch. Keep their persisted optimized-engine
            // preference so a fresh launch doesn't silently use Mirage.
            if previous != nil && previous != checkpoint { useDrawThings = false }
#if canImport(_MediaGenerationKit) && canImport(ModelOp) && canImport(ModelZoo) && canImport(DataModels)
            Task {
                let ready = await DrawThingsAnimaBridge.shared.isReady(checkpoint: checkpoint)
                drawThingsReady = ready
                if !ready { useDrawThings = false }
            }
#endif
        }
        .onDisappear {
            renderTask?.cancel()
            downloadTask?.cancel()
        }
        .preferredColorScheme(.dark)
    }

    private var focusedGenerationView: some View {
        GeometryReader { geometry in
            ZStack {
                StudioAuroraBackground().ignoresSafeArea()
                if let image = renderPreview ?? (busy ? latestImage : (renderPhase == .completed ? latestImage : nil)) {
                    StudioImageThumbnail(url: image, maxPixelDimension: 960, fill: true)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .blur(radius: busy ? (renderPreview == nil ? 32 : 8) : 0)
                        .overlay(.black.opacity(busy ? 0.52 : 0.18))
                        .animation(.easeInOut(duration: 0.55), value: renderPreview)
                        .ignoresSafeArea()
                } else {
                    Circle()
                        .fill(AppTheme.accent.opacity(0.28))
                        .frame(width: 270, height: 270)
                        .blur(radius: 105)
                        .offset(y: -80)
                        .accessibilityHidden(true)
                }
                VStack(spacing: 0) {
                    HStack {
                        Label("Creating", systemImage: "sparkles")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        if !busy, let image = renderPreview ?? latestImage {
                            creationMenu(image)
                        }
                        Button {
                            if busy { renderTask?.cancel() }
                            withAnimation(.easeInOut(duration: 0.3)) { showGenerationFocus = false }
                        } label: {
                            Image(systemName: "xmark").font(.subheadline.weight(.semibold))
                                .frame(width: 40, height: 40)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .accessibilityLabel(busy ? "Cancel image render" : "Close image preview")
                    }
                    .padding(.top, 4)
                    if busy {
                        VStack(spacing: 8) {
                            InfinityLoader(size: 78)
                                .frame(width: 78, height: 78)
                                .padding(.top, 20)
                                .accessibilityLabel("Image generation in progress")
                            StudioPromptCrawl(prompt: activeRenderPrompt, reduceMotion: reduceMotion)
                                .id(renderSequence)
                                .frame(maxWidth: 480)
                                .frame(maxHeight: .infinity)
                                .padding(.horizontal, 20)
                                .accessibilityIdentifier("studio-prompt-crawl")
                        }
                    } else {
                        Spacer(minLength: 36)
                        VStack(spacing: 12) {
                            Image(systemName: renderPhase == .completed ? "checkmark.seal.fill" :
                                  renderPhase == .enhancementFailed ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                                .font(.system(size: 42, weight: .light))
                                .foregroundStyle(renderPhase == .completed ? .green : .orange)
                            Text(renderPhase == .completed ? "Your creation is ready" :
                                 renderPhase == .enhancementFailed ? "Original image saved" :
                                 renderPhase == .cancelled ? "Generation cancelled" : "Generation failed")
                                .font(.title2.weight(.bold))
                                .multilineTextAlignment(.center)
                        }
                        Spacer(minLength: 36)
                    }
                    VStack(spacing: 14) {
                        HStack(spacing: 8) {
                            Circle().fill(busy ? AppTheme.accent : (renderPhase == .completed ? .green : .orange))
                                .frame(width: 7, height: 7)
                            Text(busy ? renderStage.uppercased() : renderPhase.label.uppercased())
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .tracking(1.3)
                            Spacer()
                        }
                        Group {
                            if renderPhase == .failed || renderPhase == .cancelled {
                                EmptyView()
                            } else if renderProgressHasExactSteps || !busy {
                                ProgressView(value: renderStatus.fraction)
                            } else {
                                // The native bridge emits internal operations, not
                                // sampler steps. A numeric percent is misleading.
                                InfinityLoader(size: 24)
                            }
                        }
                        .tint(AppTheme.accent)
                        .accessibilityIdentifier("studio-focus-progress")
                        if renderPhase != .failed && renderPhase != .cancelled && (renderProgressHasExactSteps || !busy) {
                            Text("\(Int(renderStatus.fraction * 100))%")
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .monospacedDigit()
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        if let status {
                            Text(status).font(.caption).multilineTextAlignment(.center)
                                .foregroundStyle(.white.opacity(0.84))
                                .accessibilityIdentifier("studio-focus-status")
                        }
                        if busy {
                            Button(role: .destructive) { renderTask?.cancel() } label: {
                                Label("Stop generation", systemImage: "stop.fill")
                                    .frame(maxWidth: .infinity, minHeight: 48)
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button { render() } label: {
                                Label("Generate again", systemImage: "sparkles")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity, minHeight: 52)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(AppTheme.accent)
                            if renderPhase == .failed, let status {
                                Button {
                                    UIPasteboard.general.string = status
                                } label: {
                                    Label("Copy error details", systemImage: "doc.on.doc")
                                }
                                .font(.caption.weight(.medium))
                                .buttonStyle(.plain)
                            }
                            if let image = renderPreview ?? (renderPhase == .completed ? latestImage : nil) {
                                ShareLink(item: image) { Label("Save or share", systemImage: "square.and.arrow.up") }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(20)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26))
                    .overlay(RoundedRectangle(cornerRadius: 26).stroke(.white.opacity(0.15)))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
        }
        .accessibilityIdentifier("studio-focused-generation")
    }

    private var studioHero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.headline).foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: 12))
                Text("Image Studio")
                    .font(.title2.weight(.bold))
                Spacer(minLength: 4)
                Image(systemName: "lock.shield.fill")
                    .font(.caption).foregroundStyle(.green.opacity(0.85))
                    .accessibilityLabel("Private on-device generation")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Prompt").font(.subheadline.weight(.semibold))
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.27))
                    if prompt.isEmpty {
                        Text("Describe your image…")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.45))
                            .padding(.horizontal, 15).padding(.top, 17)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $prompt)
                        .focused($promptFocused)
                        .scrollContentBackground(.hidden)
                        .font(.system(size: 16))
                        .padding(9)
                        .frame(height: 124)
                        .accessibilityLabel("Image prompt")
                        .accessibilityIdentifier("studio-prompt")
                }
                .frame(height: 124)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.19)))
            }
            Button(action: generateFromFavorites) {
                Label("Surprise me", systemImage: "heart.text.square.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(QuicktickPressStyle())
            .disabled(busy)
            .accessibilityIdentifier("studio-generate-from-favorites")
            Button { render() } label: {
                Label(busy ? "Creating…" : "Generate", systemImage: "sparkles")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(QuicktickPressStyle())
            .disabled(busy)
            .accessibilityIdentifier("studio-generate")
            if let status {
                Text(status)
                    .font(.caption).foregroundStyle(.white.opacity(0.76))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityIdentifier("studio-status")
            }
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 22)
                .fill(Color(red: 0.085, green: 0.065, blue: 0.18).opacity(0.94))
                .clipShape(RoundedRectangle(cornerRadius: 22))
        }
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.16)))
    }

    private func inspirationRow(_ title: String, values: [String]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title + ":").font(.caption.weight(.semibold)).foregroundStyle(AppTheme.accent)
            Text(values.prefix(4).map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.white.opacity(0.75))
        }
    }

    @ViewBuilder private var modelPanel: some View {
        if modernUI { modernModelPanel }
        else { legacyModelPanel }
    }

    private var modernModelPanel: some View {
        StudioPanel(title: "Engine & canvas", icon: "square.stack.3d.up.fill") {
            HStack(spacing: 9) {
                modernEngineButton("Anima Turbo", symbol: "sparkles", selected: selectedEngine == .anima,
                                   detail: animaReady ? "Ready" : "Install") {
                    if animaReady { selectedEngine = .anima }
                    else if selectedAnimaCheckpoint != nil { beginAnimaDownload(useExistingCheckpoint: true) }
                    else { beginCivitaiAnimaSetup() }
                }
                modernEngineButton("Core ML", symbol: "cpu", selected: selectedEngine == .coreML,
                                   detail: installedModels.isEmpty ? "Install" : "Ready") {
                    if installedModels.isEmpty { beginStarterDownload() }
                    else { selectedEngine = .coreML }
                }
            }
            if selectedEngine == .anima {
                HStack(spacing: 8) {
                    Circle().fill(animaReady ? .green : .orange).frame(width: 7, height: 7)
                    Text(selectedAnimaCheckpoint == nil ? "Anima" : "Anima Turbo v1.1")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 4)
                    Button("Models & LoRAs") { catalogKind = .lora; showCatalog = true }
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.white.opacity(0.9))
                if !selectedLoRAStrengths.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(selectedLoRAStrengths.keys.sorted(), id: \.self) { name in
                                Text(loRADisplayName(name))
                                    .lineLimit(1)
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(AppTheme.accent.opacity(0.22), in: Capsule())
                            }
                        }
                    }
                }
#if canImport(_MediaGenerationKit) && canImport(ModelOp) && canImport(ModelZoo) && canImport(DataModels)
                HStack(spacing: 8) {
                    Label(useDrawThings && drawThingsReady ? "Optimized · Metal" : "Mirage · Fallback", systemImage: "bolt.fill")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    if drawThingsReady {
                        Toggle("Optimized engine", isOn: $useDrawThings).labelsHidden()
                    } else if selectedAnimaCheckpoint != nil {
                        Button("Optimize") {
                            guard let checkpoint = selectedAnimaCheckpoint else { return }
                            perform("Optimizing Anima…") {
                                try await DrawThingsAnimaBridge.shared.prepare(checkpoint: checkpoint) { fraction in
                                    Task { @MainActor in drawThingsConversion = fraction }
                                }
                                drawThingsReady = true
                                useDrawThings = true
                                status = "Optimized engine ready. Mirage remains available."
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .disabled(busy || selectedAnimaCheckpoint?.lastPathComponent != "checkpoint-3263843.safetensors")
                    }
                }
                .padding(11)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 13))
                if busy && drawThingsConversion > 0 && drawThingsConversion < 1 {
                    ProgressView(value: drawThingsConversion).tint(AppTheme.accent)
                }
#endif
            } else {
                HStack(spacing: 10) {
                    if !installedModels.isEmpty {
                        Menu {
                            ForEach(installedModels, id: \.path) { url in
                                Button(url.deletingLastPathComponent().lastPathComponent) { selectedModel = url }
                            }
                        } label: {
                            Label(selectedModel?.deletingLastPathComponent().lastPathComponent ?? "Choose model", systemImage: "chevron.down")
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Button("Import") { showImport = true }
                    Button("Download") { beginStarterDownload() }
                }
                .font(.caption.weight(.semibold))
                .disabled(busy || transferStatus.isActive)
            }
            Divider().overlay(.white.opacity(0.12))
            HStack {
                Text("Canvas size").font(.subheadline.weight(.semibold))
                Spacer()
                if selectedEngine == .anima {
                    let dimensions = aspect.nativePixelDimensions(longestEdge: Int(animaLongestEdge))
                    Text("\(dimensions.width) × \(dimensions.height)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                } else {
                    Text("Model native").font(.caption).foregroundStyle(AppTheme.secondaryLabel)
                }
            }
            if selectedEngine == .anima {
                HStack(spacing: 6) {
                    ForEach(StudioCanvasSize.allCases) { size in
                        Button(size.label) { animaLongestEdge = Double(size.longestEdge) }
                            .buttonStyle(StudioCompactChipStyle(isSelected: Int(animaLongestEdge) == size.longestEdge))
                            .accessibilityIdentifier("studio-canvas-\(size.rawValue)")
                    }
                }
                .accessibilityIdentifier("studio-anima-resolution")
            }
            HStack(spacing: 7) {
                ForEach(StudioAspectRatio.allCases) { ratio in
                    Button { aspect = ratio } label: { Text(ratio.label).frame(maxWidth: .infinity) }
                        .buttonStyle(StudioCompactChipStyle(isSelected: aspect == ratio))
                        .accessibilityIdentifier("studio-aspect-\(ratio.rawValue)")
                }
            }
            HStack {
                Label("Anime 4×", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button {
                    if !animeUpscalerReady { beginAnimeUpscalerDownload() }
                    else { highResolution.toggle() }
                } label: {
                    Text(!animeUpscalerReady ? "Get upscaler" : highResolution ? "On" : "Off")
                        .font(.caption.weight(.bold))
                }
                .accessibilityIdentifier("studio-anime-upscaler")
            }
            if transferStatus.isActive { downloadProgressPanel }
            DisclosureGroup(isExpanded: $showAdvanced) {
                generationPanel.padding(.top, 10)
            } label: {
                Label("Advanced", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
            }
            .tint(AppTheme.accent)
        }
    }

    private func modernEngineButton(_ title: String, symbol: String, selected: Bool, detail: String,
                                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Image(systemName: symbol).foregroundStyle(selected ? .white : AppTheme.accent)
                    Spacer()
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                }
                Text(title).font(.subheadline.weight(.bold)).lineLimit(1)
                Text(detail).font(.caption2).foregroundStyle(.white.opacity(0.65))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(selected ? AppTheme.accent.opacity(0.28) : .white.opacity(0.055),
                        in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? AppTheme.accent.opacity(0.65) : .white.opacity(0.1)))
        }
        .buttonStyle(QuicktickPressStyle())
        .foregroundStyle(.white)
    }

    private var legacyModelPanel: some View {
        StudioPanel(title: "On-device engine", icon: "cpu.fill") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    Button {
                        if installedModels.isEmpty { beginStarterDownload() }
                        else { selectedEngine = .coreML; status = "Apple Core ML selected." }
                    } label: {
                        engineChip("Apple SD 1.5", detail: installedModels.isEmpty ? "1.57 GB · Get" : "Ready to create",
                                   icon: "cpu.fill", active: selectedEngine == .coreML && !installedModels.isEmpty)
                    }
                    Button {
                        if animaReady { selectedEngine = .anima; status = "Anima Metal engine selected." }
                        else if selectedAnimaCheckpoint != nil { beginAnimaDownload(useExistingCheckpoint: true) }
                        else { beginCivitaiAnimaSetup() }
                    } label: {
                        engineChip("Anima · CivitAI", detail: animaReady ? "Ready · Private" : "Set up",
                                   icon: "sparkles.rectangle.stack", active: selectedEngine == .anima && animaReady)
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
            Text("Set up Anima from civitai.red with its encoder and VAE. Large checkpoints need significant device RAM.")
                .font(.caption2).foregroundStyle(AppTheme.secondaryLabel)
            if selectedEngine == .anima {
                HStack(spacing: 8) {
                    Label(selectedAnimaCheckpoint?.lastPathComponent ?? "Built-in Anima Q4", systemImage: "checkmark.seal")
                        .font(.caption.weight(.medium)).lineLimit(1)
                    Spacer()
                    Button("Models & LoRAs") { showCatalog = true }
                        .font(.caption.weight(.semibold))
                }
                if !selectedLoRAStrengths.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(selectedLoRAStrengths.keys.sorted(), id: \.self) { name in
                                Label(loRADisplayName(name), systemImage: "square.stack.3d.up")
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 10).padding(.vertical, 7)
                                    .background(AppTheme.accent.opacity(0.25), in: Capsule())
                            }
                        }
                    }
                }
#if canImport(_MediaGenerationKit) && canImport(ModelOp) && canImport(ModelZoo) && canImport(DataModels)
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Label("Draw Things · Turbo v1.1", systemImage: "bolt.fill")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        if drawThingsReady {
                            Toggle("Use Draw Things", isOn: $useDrawThings)
                                .labelsHidden()
                        } else {
                            Text("Experimental").font(.caption2).foregroundStyle(AppTheme.secondaryLabel)
                        }
                    }
                    if !drawThingsReady {
                        Button {
                            guard let checkpoint = selectedAnimaCheckpoint else { return }
                            perform("Preparing the optimized engine…") {
                                try await DrawThingsAnimaBridge.shared.prepare(checkpoint: checkpoint) { fraction in
                                    Task { @MainActor in drawThingsConversion = fraction }
                                }
                                drawThingsReady = true
                                useDrawThings = true
                                status = "Draw Things is ready. Mirage remains available as fallback."
                            }
                        } label: {
                            Label("Convert Turbo v1.1 for faster generation", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption.weight(.semibold))
                        }
                        .disabled(busy || selectedAnimaCheckpoint?.lastPathComponent != "checkpoint-3263843.safetensors")
                        if busy && drawThingsConversion > 0 && drawThingsConversion < 1 {
                            ProgressView(value: drawThingsConversion)
                        }
                        Text("Download the verified Turbo v1.1 checkpoint from Civitai setup first. Conversion needs ~7 GB free; Mirage keeps the original file.")
                            .font(.caption2).foregroundStyle(AppTheme.secondaryLabel)
                    } else {
                        Text(useDrawThings ? "Optimized engine active · Mirage fallback" : "Mirage active · optimized engine available")
                            .font(.caption2).foregroundStyle(AppTheme.secondaryLabel)
                    }
                }
                .padding(11)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 15))
#endif
            }
            if !installedModels.isEmpty && selectedEngine == .coreML {
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
            if selectedEngine == .anima {
                HStack(spacing: 8) {
                    Text("Preset").font(.caption.weight(.semibold))
                    Spacer()
                    Button("Fast") { stepCount = 8; animaLongestEdge = 512 }
                        .buttonStyle(StudioOptionChipStyle(isSelected: stepCount == 8 && animaLongestEdge == 512))
                        .accessibilityIdentifier("studio-preset-fast")
                    Button("Quality") { stepCount = 8; animaLongestEdge = 768 }
                        .buttonStyle(StudioOptionChipStyle(isSelected: stepCount == 8 && animaLongestEdge == 768))
                        .accessibilityIdentifier("studio-preset-quality")
                }
            }
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
            if selectedEngine == .anima {
                let pixels = aspect.nativePixelDimensions(longestEdge: Int(animaLongestEdge))
                HStack(spacing: 7) {
                    ForEach(StudioCanvasSize.allCases) { size in
                        Button(size.label) { animaLongestEdge = Double(size.longestEdge) }
                            .buttonStyle(StudioCompactChipStyle(isSelected: Int(animaLongestEdge) == size.longestEdge))
                    }
                    Text("\(pixels.width) × \(pixels.height)")
                        .font(.caption2.monospacedDigit()).foregroundStyle(AppTheme.secondaryLabel)
                }
                .accessibilityIdentifier("studio-anima-resolution")
            }
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
        }
    }

    private var downloadProgressPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                InfinityLoader(size: 32)
                    .accessibilityLabel("Download active")
                VStack(alignment: .leading, spacing: 2) {
                    Text(transferStatus.phase == .paused ? "Download paused" : "Downloading")
                        .font(.caption2.weight(.medium)).foregroundStyle(AppTheme.secondaryLabel)
                    Text(transferStatus.name)
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(transferStatus.progressLabel)
                    .font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(AppTheme.accent)
            }
            if let fraction = transferStatus.fraction {
                ProgressView(value: fraction)
                    .tint(AppTheme.accent)
                    .accessibilityIdentifier("studio-download-progress")
            } else {
                ProgressView()
                    .tint(AppTheme.accent)
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
            if selectedEngine == .anima {
                Text(useDrawThings && drawThingsReady
                     ? "Optimized Anima: Euler A Substep. Mirage is available as fallback."
                     : "Mirage uses its native Euler sampler. Enable the optimized engine for Euler A Substep.")
                    .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
            } else {
                HStack(spacing: 8) {
                Text("Scheduler").font(.caption.weight(.semibold))
                Spacer()
                ForEach(StudioScheduler.allCases) { candidate in
                    Button(candidate.label) { scheduler = candidate }
                        .buttonStyle(StudioOptionChipStyle(isSelected: scheduler == candidate))
                }
                }
                Toggle("Check Core ML images for unsafe content", isOn: $coreMLSafetyCheck)
                    .font(.caption)
                Text("When enabled, the safety checker may return no image. You can choose to turn it off for your private, local renders.")
                    .font(.caption2).foregroundStyle(AppTheme.secondaryLabel)
            }
            HStack {
                Text("Steps").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(Int(stepCount))").font(.subheadline.monospacedDigit()).foregroundStyle(AppTheme.secondaryLabel)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach([4, 6, 8, 12, 16, 24, 32], id: \.self) { count in
                        Button("\(count)") { stepCount = Double(count) }
                            .buttonStyle(StudioOptionChipStyle(isSelected: Int(stepCount) == count))
                    }
                }
            }
            HStack {
                Text("Guidance").font(.subheadline.weight(.semibold))
                Spacer()
                Text(guidance.formatted(.number.precision(.fractionLength(1))))
                    .font(.subheadline.monospacedDigit()).foregroundStyle(AppTheme.secondaryLabel)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach([1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0], id: \.self) { scale in
                        Button(scale.formatted(.number.precision(.fractionLength(1)))) { guidance = scale }
                            .buttonStyle(StudioOptionChipStyle(isSelected: guidance == scale))
                    }
                }
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
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("LATEST CREATION", systemImage: "photo.artframe")
                    .font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(1.2)
                Spacer()
                Text("READY TO SHARE")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.green)
            }
            creationPreview(url, thumbnailSize: 1200, height: 370, fill: false)
            ShareLink(item: url) {
                Label("Save or share image", systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.accent)
        }
        .padding(16)
        .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).stroke(AppTheme.border))
    }

    private var catalogSheet: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 15) {
                    HStack(spacing: 12) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.white)
                            .frame(width: 46, height: 46)
                            .background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: 15))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Model library")
                                .font(.title2.weight(.bold))
                            Text("Discover · Download · Create")
                                .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
                        }
                        Spacer(minLength: 2)
                        if !downloadedAssets.isEmpty {
                            Text("\(downloadedAssets.count) saved")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(AppTheme.accent.opacity(0.14), in: Capsule())
                        }
                    }
                    .padding(.top, 8)
                    HStack(spacing: 8) {
                        ForEach(StudioCatalogKind.allCases) { kind in
                            Button {
                                withAnimation(AppTheme.spring) { catalogKind = kind }
                            } label: {
                                Text(kind.title)
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity, minHeight: 42)
                                    .foregroundStyle(catalogKind == kind ? .white : AppTheme.secondaryLabel)
                                    .background {
                                        if catalogKind == kind {
                                            Capsule().fill(AppTheme.gradient)
                                        } else {
                                            Capsule().fill(AppTheme.elevatedSurface)
                                        }
                                    }
                                    .overlay(Capsule().stroke(.white.opacity(catalogKind == kind ? 0.20 : 0.10)))
                            }
                            .buttonStyle(QuicktickPressStyle())
                            .accessibilityAddTraits(catalogKind == kind ? .isSelected : [])
                            .accessibilityIdentifier("studio-catalog-kind-\(kind.rawValue)")
                        }
                    }
                    .accessibilityElement(children: .contain)
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(AppTheme.secondaryLabel)
                        TextField("Search \(catalogKind.title.lowercased())", text: $searchQuery)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .onSubmit { searchCatalog() }
                            .accessibilityIdentifier("studio-catalog-search")
                        Button { searchCatalog() } label: {
                            Image(systemName: "arrow.right")
                                .font(.subheadline.weight(.bold))
                                .frame(width: 36, height: 36)
                                .background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: 11))
                        }
                            .buttonStyle(QuicktickPressStyle())
                            .disabled(catalogBusy || searchQuery.isEmpty)
                    }
                    .padding(.leading, 15).padding(.trailing, 6).padding(.vertical, 5)
                    .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 17))
                    .overlay(RoundedRectangle(cornerRadius: 17).stroke(AppTheme.border))
                    HStack(spacing: 10) {
                        Label("civitai.red", systemImage: "globe")
                            .font(.caption.weight(.medium))
                        Toggle("civitai.red", isOn: $useRed).labelsHidden().tint(AppTheme.accent)
                        Spacer()
                        Button {
                            tokenDraft = KeychainStore.get(account: "civitai-api-key") ?? ""
                            showToken = true
                        } label: { Label("API key", systemImage: "key.fill") }
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(AppTheme.secondaryLabel)
                    HStack(spacing: 9) {
                        Button { showAnimaImport = true } label: {
                            Label("Import model", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity, minHeight: 43)
                        }
                        Button { showLoRAImport = true } label: {
                            Label("Import LoRA", systemImage: "plus.circle.fill")
                                .frame(maxWidth: .infinity, minHeight: 43)
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.bordered)
                    HStack {
                        Text("For you").font(.headline)
                        Spacer()
                        Text("From favorites")
                            .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            catalogChip("Anima", icon: "sparkles", kind: .checkpoint, query: "Anima")
                            ForEach(inspiration.characters.prefix(3), id: \.self) { character in
                                catalogChip(character.replacingOccurrences(of: "_", with: " "), icon: "heart.fill", kind: .lora, query: character)
                            }
                            ForEach(inspiration.artists.prefix(2), id: \.self) { artist in
                                catalogChip(artist.replacingOccurrences(of: "_", with: " "), icon: "paintpalette.fill", kind: .lora, query: artist)
                            }
                        }
                        .font(.caption.weight(.medium))
                        .buttonStyle(.bordered)
                        .disabled(catalogBusy)
                    }
                    if transferStatus.isActive { downloadProgressPanel }
                    if catalogBusy {
                        HStack(spacing: 10) {
                            InfinityLoader(size: 31)
                            Text("Finding models…")
                                .font(.subheadline.weight(.medium))
                        }
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 18))
                    }
                    HStack {
                        Text(catalogKind == .lora ? "LoRAs" : "Checkpoints")
                            .font(.headline)
                        Spacer()
                        Text("\((catalogKind == .lora ? loras : checkpoints).count) results")
                            .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
                    }
                    ForEach(catalogKind == .lora ? loras : checkpoints) { model in modelRow(model) }
                    if !catalogBusy && (catalogKind == .lora ? loras : checkpoints).isEmpty {
                        Label("Search a name or try a favorite above.", systemImage: "sparkle.magnifyingglass")
                            .font(.subheadline).foregroundStyle(AppTheme.secondaryLabel)
                            .frame(maxWidth: .infinity, minHeight: 82)
                            .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 18))
                    }
                    if let status, status.localizedCaseInsensitiveContains("download") || status.localizedCaseInsensitiveContains("saved") || status.localizedCaseInsensitiveContains("import") {
                        Text(status).font(.caption).foregroundStyle(AppTheme.secondaryLabel)
                    }
                    if !downloadedAssets.isEmpty { downloadedAssetsPanel }
                }
                .padding(16).frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .background(StudioAuroraBackground().ignoresSafeArea())
            .navigationTitle("Model library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { showCatalog = false } }
            }
            // Present the document picker from the model-library sheet itself.
            // A picker attached to the covered parent view fails on some iOS releases.
            .fileImporter(isPresented: $showAnimaImport, allowedContentTypes: [.item]) { importAsset($0, type: "checkpoint") }
            .fileImporter(isPresented: $showLoRAImport, allowedContentTypes: [.item]) { importAsset($0, type: "lora") }
        }
        .preferredColorScheme(.dark)
    }

    private func catalogChip(_ title: String, icon: String, kind: StudioCatalogKind, query: String) -> some View {
        Button {
            catalogKind = kind
            searchQuery = query
            searchCatalog()
        } label: {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 13).padding(.vertical, 10)
                .background(AppTheme.accent.opacity(0.16), in: Capsule())
                .overlay(Capsule().stroke(AppTheme.accent.opacity(0.34)))
        }
        .buttonStyle(QuicktickPressStyle())
    }

    private func modelRow(_ model: CivitaiStudioModel) -> some View {
        HStack(spacing: 12) {
            if modernUI {
                Image(systemName: model.type == "LORA" ? "wand.and.stars" : "square.stack.3d.up.fill")
                    .font(.title3).foregroundStyle(AppTheme.accent)
                    .frame(width: 42, height: 42)
                    .background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(model.name).font(.subheadline.weight(.medium)).lineLimit(2)
                if modernUI {
                    HStack(spacing: 5) {
                        modelBadge(model.type == "LORA" ? "LoRA" : "Checkpoint")
                        if let base = model.latest?.baseModel { modelBadge(base) }
                        if let size = model.latest?.displaySize { modelBadge(size) }
                    }
                } else {
                    Text([model.type, model.latest?.baseModel, model.latest?.displaySize].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
                }
                if let words = model.latest?.trainedWords, !words.isEmpty {
                    Text(words.prefix(2).joined(separator: ", ")).font(.caption2).foregroundStyle(AppTheme.accent)
                }
            }
            Spacer(minLength: 6)
            Button { beginAssetDownload(model) } label: {
                Group {
                    if downloadBusyID == model.id {
                        InfinityLoader(size: 30)
                    } else {
                        Image(systemName: "arrow.down.to.line.compact")
                            .font(.system(size: 17, weight: .semibold))
                    }
                }
                    .frame(width: 42, height: 42)
                    .background(AppTheme.accent.opacity(0.22), in: RoundedRectangle(cornerRadius: 13))
            }
                .buttonStyle(QuicktickPressStyle()).font(.title3)
                .disabled(transferStatus.isActive || downloadBusyID != nil)
                .accessibilityLabel("Download \(model.name)")
        }
        .padding(12)
        .background(modernUI ? AppTheme.elevatedSurface : AppTheme.surface, in: RoundedRectangle(cornerRadius: modernUI ? 20 : 14))
        .overlay(RoundedRectangle(cornerRadius: modernUI ? 20 : 14).stroke(AppTheme.border))
    }

    private func modelBadge(_ value: String) -> some View {
        Text(value).font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(Color.white.opacity(0.08), in: Capsule())
            .foregroundStyle(AppTheme.secondaryLabel)
    }

    private var downloadedAssetsPanel: some View {
        StudioPanel(title: "Downloaded CivitAI assets", icon: "externaldrive") {
            Text("Select an Anima checkpoint and up to four compatible LoRAs. Other model families may not work with Anima.")
                .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
            ForEach(downloadedAssets, id: \.path) { file in
                VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 10) {
                    Image(systemName: "doc.zipper").foregroundStyle(AppTheme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loRANames[file.lastPathComponent] ?? studioAssetDisplayName(file))
                            .font(.caption.weight(.medium)).lineLimit(1)
                        Text(file.pathExtension.uppercased())
                            .font(.caption2).foregroundStyle(AppTheme.secondaryLabel)
                    }
                    Spacer(minLength: 4)
                    if file.lastPathComponent.hasPrefix("checkpoint-") && ["safetensors", "gguf"].contains(file.pathExtension.lowercased()) {
                        Button { activateAnimaCheckpoint(file) } label: {
                            Label(selectedAnimaCheckpoint == file ? "Selected" : "Use Anima", systemImage: "sparkles")
                        }
                            .font(.caption2).accessibilityIdentifier("studio-use-downloaded-anima")
                    }
                    ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Export \(file.lastPathComponent)")
                    Button(role: .destructive) {
                        Task {
                            do {
                                try await LocalImageStudio.shared.deleteDownloadedAsset(file)
                                downloadedAssets = await LocalImageStudio.shared.downloadedAssets()
                                selectedLoRAStrengths.removeValue(forKey: file.lastPathComponent)
                                loRATriggerWords.removeValue(forKey: file.lastPathComponent)
                                loRANames.removeValue(forKey: file.lastPathComponent)
                                if selectedAnimaCheckpoint == file {
                                    selectedAnimaCheckpoint = nil
                                    savedAnimaCheckpointName = ""
                                    animaReady = await LocalImageStudio.shared.hasAnimaBundle()
                                }
                            } catch { status = "Could not remove asset: \(error.localizedDescription)" }
                        }
                    } label: { Image(systemName: "trash") }
                        .accessibilityLabel("Delete \(file.lastPathComponent)")
                }
                .buttonStyle(QuicktickPressStyle())
                .frame(minHeight: 44)
                if file.lastPathComponent.hasPrefix("lora-") && file.pathExtension.lowercased() == "safetensors" {
                    HStack {
                        Toggle("Use LoRA", isOn: Binding(
                            get: { selectedLoRAStrengths[file.lastPathComponent] != nil },
                            set: { enabled in
                                if enabled {
                                    if selectedLoRAStrengths.count < 4 { selectedLoRAStrengths[file.lastPathComponent] = 0.8 }
                                    else { status = "Choose up to four LoRAs at a time." }
                                } else { selectedLoRAStrengths.removeValue(forKey: file.lastPathComponent) }
                            }
                        ))
                        .font(.caption)
                        if selectedLoRAStrengths[file.lastPathComponent] != nil {
                            Slider(value: Binding(
                                get: { selectedLoRAStrengths[file.lastPathComponent] ?? 0.8 },
                                set: { selectedLoRAStrengths[file.lastPathComponent] = $0 }
                            ), in: 0.0...1.5, step: 0.1)
                            Text((selectedLoRAStrengths[file.lastPathComponent] ?? 0.8).formatted(.number.precision(.fractionLength(1))))
                                .font(.caption.monospacedDigit())
                        }
                    }
                    if selectedLoRAStrengths[file.lastPathComponent] != nil {
                        HStack(spacing: 8) {
                            Image(systemName: "text.quote").foregroundStyle(AppTheme.accent)
                            TextField("Style trigger words (optional)", text: Binding(
                                get: { loRATriggerWords[file.lastPathComponent] ?? "" },
                                set: { loRATriggerWords[file.lastPathComponent] = $0 }
                            ))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.caption)
                        }
                        .padding(10)
                        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                }
            }
        }
    }

    private func studioAssetDisplayName(_ file: URL) -> String {
        let basename = file.deletingPathExtension().lastPathComponent
        if basename.hasPrefix("lora-import-") {
            return "Imported LoRA · \(basename.suffix(6))"
        }
        if basename.hasPrefix("checkpoint-import-") {
            return "Imported checkpoint · \(basename.suffix(6))"
        }
        if basename.hasPrefix("lora-") { return "LoRA · \(basename.dropFirst(5))" }
        if basename.hasPrefix("checkpoint-") { return "Checkpoint · \(basename.dropFirst(11))" }
        return basename
    }

    private func loRADisplayName(_ filename: String) -> String {
        loRANames[filename] ?? studioAssetDisplayName(URL(fileURLWithPath: filename))
    }

    private var galleryPanel: some View {
        StudioPanel(title: "My creations", icon: "photo.on.rectangle.angled") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                ForEach(savedImages.prefix(18), id: \.path) { url in
                    creationPreview(url, thumbnailSize: 240, height: 112, fill: true)
                }
            }
        }
    }

    private func creationPreview(_ url: URL, thumbnailSize: Int, height: CGFloat, fill: Bool) -> some View {
        StudioImageThumbnail(url: url, maxPixelDimension: thumbnailSize, fill: fill)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipped()
            .background(.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.14)))
            .contentShape(RoundedRectangle(cornerRadius: 15))
            .onTapGesture { viewingImage = StudioImageSelection(url: url) }
            .overlay(alignment: .topTrailing) {
                creationMenu(url)
                    .padding(7)
            }
            .accessibilityLabel("View generated image fullscreen")
    }

    private func creationMenu(_ url: URL) -> some View {
        Menu {
            Button {
                viewingImage = StudioImageSelection(url: url)
            } label: { Label("View fullscreen", systemImage: "arrow.up.left.and.arrow.down.right") }
            if let metadata = savedPromptMetadata[url.lastPathComponent] {
                Button {
                    reusePrompt(metadata)
                } label: { Label("Reuse prompt", systemImage: "text.badge.plus") }
            } else {
                Button("Prompt unavailable for older images") { }
                    .disabled(true)
            }
            ShareLink(item: url) {
                Label("Save or share", systemImage: "square.and.arrow.up")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.black.opacity(0.62), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.15)))
        }
        .accessibilityLabel("Image options")
    }

    private func reusePrompt(_ metadata: StudioGenerationMetadata) {
        prompt = metadata.prompt
        negativePrompt = metadata.negativePrompt
        stepCount = Double(metadata.steps)
        guidance = metadata.guidance
        seed = metadata.seed
        if let savedAspect = StudioAspectRatio(rawValue: metadata.aspect) { aspect = savedAspect }
        animaLongestEdge = Double(StudioCanvasSize.closest(to: metadata.longestEdge).longestEdge)
        viewingImage = nil
        status = "Prompt restored. Edit it or generate again."
        promptFocused = true
    }

    private func fullscreenCreation(_ url: URL) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                HStack {
                    Text("YOUR CREATION")
                        .font(.caption.weight(.bold)).tracking(1.8)
                        .foregroundStyle(.white.opacity(0.65))
                    Spacer()
                    creationMenu(url)
                    Button { viewingImage = nil } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .background(.white.opacity(0.13), in: Circle())
                    }
                    .accessibilityLabel("Close fullscreen image")
                }
                .padding(.horizontal, 18)
                StudioImageThumbnail(url: url, maxPixelDimension: 2048, fill: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let metadata = savedPromptMetadata[url.lastPathComponent] {
                    Text(metadata.prompt)
                        .font(.subheadline)
                        .lineLimit(2)
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                    Button {
                        reusePrompt(metadata)
                    } label: {
                        Label("Reuse this prompt", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accent)
                    .padding(.horizontal, 18)
                }
            }
            .foregroundStyle(.white)
            .padding(.vertical, 16)
        }
        .preferredColorScheme(.dark)
    }

    private var introSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: 45)).foregroundStyle(AppTheme.accent)
            Text("Create with QuickTick")
                .font(.system(.largeTitle, design: .default, weight: .bold))
            ForEach([
                ("1", "Your taste", "Prompts inspired by favorites"),
                ("2", "Install Anima", "Checkpoint + Qwen3 + VAE"),
                ("3", "Add LoRAs", "Choose characters and styles")
            ], id: \.0) { item in
                HStack(alignment: .top, spacing: 12) {
                    Text(item.0).font(.headline).foregroundStyle(.white)
                        .frame(width: 36, height: 36).background(AppTheme.gradient, in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.1).font(.headline)
                        Text(item.2).font(.caption).foregroundStyle(AppTheme.secondaryLabel)
                    }
                }
            }
            if transferStatus.isActive {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        InfinityLoader(size: 26)
                        Text(status ?? "Installing Anima…").font(.subheadline).lineLimit(2)
                    }
                    if let fraction = transferStatus.fraction {
                        ProgressView(value: fraction).tint(AppTheme.accent)
                    }
                    Text(transferStatus.progressLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("anima-setup-progress")
            } else if let status, status.contains("failed") || status.contains("stopped") {
                Label(status, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("anima-setup-error")
            }
            Spacer(minLength: 4)
            if !animaReady {
                Button(transferStatus.isActive ? "Installing Anima…" : "Set up Anima") {
                    if selectedAnimaCheckpoint != nil {
                        beginAnimaDownload(useExistingCheckpoint: true)
                    } else {
                        beginCivitaiAnimaSetup()
                    }
                }
                .disabled(transferStatus.isActive)
                .font(.headline).foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(AppTheme.gradient, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityIdentifier("studio-anima-install")
            }
            // Continue is deliberately independent of model installation.
            // Even a stalled/failed download must never trap users in onboarding.
            Button("Continue to Studio") {
                introCompleted = true
                showIntro = false
                if animaReady { selectedEngine = .anima }
                if animaReady { showSetupLoRAChoice = true }
            }
                .font(.headline).foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(animaReady ? AppTheme.gradient : LinearGradient(colors: [AppTheme.surface, AppTheme.elevatedSurface], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 16))
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
        }.padding(24).presentationDetents([.large])
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
        if selectedEngine == .anima && animaReady || selectedEngine == .coreML && selectedModel != nil {
            render(promptOverride: lovedPrompt)
        } else { status = "Your idea is ready. Download Anima or an Apple Core ML model to generate it." }
    }

    private func activateAnimaCheckpoint(_ file: URL) {
        selectedAnimaCheckpoint = file
        savedAnimaCheckpointName = file.lastPathComponent
        showCatalog = false
        Task {
            let ready = await LocalImageStudio.shared.hasAnimaAuxiliaryFiles()
            animaReady = ready
            if ready {
                selectedEngine = .anima
                status = "Using \(file.lastPathComponent). The checkpoint must use Anima-compatible diffusion weights."
            } else {
                status = "Downloading the text encoder and VAE needed for this checkpoint."
                beginAnimaDownload(useExistingCheckpoint: true)
            }
        }
    }

    private func importAsset(_ result: Result<URL, Error>, type: String) {
        switch result {
        case .failure(let error):
            status = "Import failed: \(error.localizedDescription)"
        case .success(let pickedURL):
            perform("Importing \(type)…") {
                let file = try await LocalImageStudio.shared.importCivitaiAsset(pickedURL, type: type)
                downloadedAssets = await LocalImageStudio.shared.downloadedAssets()
                if type == "checkpoint" {
                    // `perform` holds `busy` while copying multi-gigabyte files.
                    selectedAnimaCheckpoint = file
                    savedAnimaCheckpointName = file.lastPathComponent
                    let auxiliaryReady = await LocalImageStudio.shared.hasAnimaAuxiliaryFiles()
                    animaReady = auxiliaryReady
                    if auxiliaryReady { selectedEngine = .anima }
                    status = auxiliaryReady
                        ? "Anima checkpoint imported and selected."
                        : "Checkpoint imported. Select Anima to install its text encoder and VAE."
                } else {
                    loRANames[file.lastPathComponent] = pickedURL.deletingPathExtension().lastPathComponent
                    if selectedLoRAStrengths.count < 4 {
                        selectedLoRAStrengths[file.lastPathComponent] = 1.0
                        status = "LoRA imported and enabled. Add its trigger words if needed."
                    } else {
                        status = "LoRA imported. Disable one of your four active LoRAs before enabling it."
                    }
                }
            }
        }
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
                selectedEngine = .coreML
                status = "Model installed. Ready to create offline."
            } catch is CancellationError {
                status = "Download stopped."
            } catch let error as URLError where error.code == .cancelled {
                status = "Download stopped."
            } catch { status = "Model download failed: \(error.localizedDescription)" }
        }
    }

    private func beginCivitaiAnimaSetup() {
        guard !transferStatus.isActive, !busy else { return }
        let identity = transferStatus.begin("Anima Turbo · civitai.red", estimatedBytes: 0)
        let progress = transferStatus
        status = "Finding Anima Turbo on civitai.red…"
        downloadTask = Task {
            defer { progress.finish(identity); downloadTask = nil }
            do {
                let token = KeychainStore.get(account: "civitai-api-key")
                let version = try await CivitaiStudioCatalog().recommendedAnima(token: token)
                status = "Downloading Anima Turbo v1.1…"
                let checkpoint = try await LocalImageStudio.shared.downloadCivitaiAsset(
                    version, type: "Checkpoint", host: "civitai.red", token: token,
                    onProgress: { received, expected in
                        Task { @MainActor in progress.update(identity, received: received, expected: expected) }
                    })
                try Task.checkCancellation()
                selectedAnimaCheckpoint = checkpoint
                savedAnimaCheckpointName = checkpoint.lastPathComponent
                downloadedAssets = await LocalImageStudio.shared.downloadedAssets()
                status = "Downloading Anima text encoder and VAE…"
                try await LocalImageStudio.shared.downloadAnimaBundle(useExistingCheckpoint: true,
                    onProgress: { received, expected in
                        Task { @MainActor in progress.update(identity, received: received, expected: expected) }
                    })
                try Task.checkCancellation()
                animaReady = await LocalImageStudio.shared.hasAnimaAuxiliaryFiles()
                guard animaReady else { throw StudioError.unavailableModel }
                selectedEngine = .anima
                status = "Anima installed and selected. Choose a LoRA if you like."
                introCompleted = true
                showIntro = false
                showSetupLoRAChoice = true
            } catch is CancellationError {
                status = "Setup stopped. Downloaded components are kept."
            } catch {
                status = "Anima setup failed: \(error.localizedDescription)"
            }
        }
    }

    private func beginAnimaDownload(useExistingCheckpoint: Bool = false) {
        guard !animaReady, !transferStatus.isActive, !busy else { return }
        let estimate = useExistingCheckpoint ? StudioAnimaBundle.components.dropFirst().reduce(Int64(0)) { $0 + $1.bytes } : StudioAnimaBundle.totalBytes
        let identity = transferStatus.begin(useExistingCheckpoint ? "Anima Qwen3 + VAE" : "Anima Q4 · Qwen3 · VAE", estimatedBytes: estimate)
        let progress = transferStatus
        status = useExistingCheckpoint ? "Preparing your Anima checkpoint with Qwen3 and VAE (650 MB)…" : "Installing Anima's Metal-ready model bundle (2.07 GB)…"
        downloadTask = Task {
            defer { progress.finish(identity); downloadTask = nil }
            do {
                try await LocalImageStudio.shared.downloadAnimaBundle(useExistingCheckpoint: useExistingCheckpoint, onProgress: { received, expected in
                    Task { @MainActor in progress.update(identity, received: received, expected: expected) }
                })
                try Task.checkCancellation()
                animaReady = useExistingCheckpoint
                    ? await LocalImageStudio.shared.hasAnimaAuxiliaryFiles()
                    : await LocalImageStudio.shared.hasAnimaBundle()
                if animaReady {
                    selectedEngine = .anima
                    status = useExistingCheckpoint ? "Anima supporting files installed. Try generating with your CivitAI checkpoint." : "Anima Q4 installed! Select Generate to render with Metal."
                    if useExistingCheckpoint {
                        introCompleted = true
                        showIntro = false
                        showSetupLoRAChoice = true
                    }
                }
            } catch is CancellationError {
                status = "Anima download stopped; completed model components are kept."
            } catch let error as URLError where error.code == .cancelled {
                status = "Anima download stopped; completed components are kept."
            } catch { status = "Anima download failed: \(error.localizedDescription)" }
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
                let file = try await LocalImageStudio.shared.downloadCivitaiAsset(version, type: model.type,
                    host: useRed ? "civitai.red" : "civitai.com",
                    token: KeychainStore.get(account: "civitai-api-key"),
                    onProgress: { received, total in
                        Task { @MainActor in progress.update(identity, received: received, expected: total) }
                    })
                try Task.checkCancellation()
                downloadedAssets = await LocalImageStudio.shared.downloadedAssets()
                if model.type == "LORA" { loRANames[file.lastPathComponent] = model.name }
                if model.type == "LORA", let triggers = version.trainedWords, !triggers.isEmpty {
                    loRATriggerWords[file.lastPathComponent] = triggers.prefix(3).joined(separator: ", ")
                }
                if model.type == "LORA", selectedLoRAStrengths.count < 4 {
                    selectedLoRAStrengths[file.lastPathComponent] = 1.0
                }
                if model.type == "Checkpoint" && model.name.localizedCaseInsensitiveContains("Anima") {
                    activateAnimaCheckpoint(file)
                } else {
                    status = model.type == "LORA" && selectedLoRAStrengths[file.lastPathComponent] != nil
                        ? "Downloaded and enabled \(model.name)."
                        : "Saved \(model.name). You can select it in your downloaded assets."
                }
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
        if selectedEngine == .coreML && selectedModel == nil {
            status = "Download the Apple Core ML model, or select Anima Metal."
            return
        }
        if selectedEngine == .anima && !animaReady {
            status = "Download the Anima Q4 bundle (diffusion weights, Qwen3 and VAE) first."
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
        let basePrompt = promptOverride ?? prompt, inputNegative = negativePrompt
        let activeTriggers: [String] = selectedEngine == .anima ? downloadedAssets.compactMap { file -> String? in
            guard selectedLoRAStrengths[file.lastPathComponent] != nil else { return nil }
            return loRATriggerWords[file.lastPathComponent]
        } : []
        let inputPrompt = StudioLoRATriggers.applying(activeTriggers, to: basePrompt)
        busy = true
        renderPhase = .rendering
        renderPreview = nil
        renderSequence = UUID()
        activeRenderPrompt = inputPrompt
        renderStage = "Preparing the canvas"
        status = "Rendering on device…"
        renderStatus.fraction = 0
        renderProgressHasExactSteps = false
        withAnimation(.easeInOut(duration: 0.3)) { showGenerationFocus = true }
        let steps = Int(stepCount), scale = Float(guidance), inputSeed = seed
        let selectedAspect = aspect, selectedScheduler = scheduler, shouldUpscale = highResolution
        let useSafetyCheck = coreMLSafetyCheck
        let longestEdge = Int(animaLongestEdge)
        let engineChoice = selectedEngine, coreMLModel = selectedModel
        let existingAnimaFile = selectedAnimaCheckpoint
        let enabledLoRAs: [StudioLoRA] = downloadedAssets.compactMap { file in
            guard let strength = selectedLoRAStrengths[file.lastPathComponent] else { return nil }
            return StudioLoRA(file: file, strength: Float(strength))
        }
        let progress = renderStatus
        renderTask = Task {
            defer { busy = false; renderTask = nil }
            do {
                await store.prepareForImageGeneration()
                try Task.checkCancellation()
                let callback: @Sendable (Int, Int) -> Void = { finished, total in
                    Task { @MainActor in
                        guard renderPhase == .rendering else { return }
                        let exactSteps = total == steps
                        renderProgressHasExactSteps = exactSteps
                        if exactSteps {
                            let share = shouldUpscale ? 0.90 : 0.98
                            progress.fraction = max(progress.fraction, min(share, Double(finished) / Double(max(1, total)) * share))
                        }
                        // Mirage can report hundreds of internal operations, not
                        // the user's requested diffusion steps. Never label those
                        // operations as sampler steps (e.g. "685 of 685").
                        renderStage = total == steps
                            ? "Diffusing · step \(min(finished, steps)) of \(steps)"
                            : "Generating · \(steps) diffusion steps"
                    }
                }
                let previewCallback: @Sendable (URL) -> Void = { file in
                    Task { @MainActor in
                        guard renderPhase == .rendering else { return }
                        renderPreview = file
                        renderStage = shouldUpscale ? "Applying Anime 4× enhancement" : "Saving your image"
                        status = shouldUpscale ? "Original ready · enhancing in 4×…" : "Image generated · saving…"
                        progress.fraction = max(progress.fraction, shouldUpscale ? 0.92 : 0.98)
                    }
                }
                let result: StudioRenderOutput
                if engineChoice == .anima {
                    result = try await LocalImageStudio.shared.generateAnima(
                        prompt: inputPrompt, negative: inputNegative, steps: steps,
                        guidance: scale, seed: inputSeed, aspect: selectedAspect,
                        longestEdge: longestEdge,
                        upscale: shouldUpscale, checkpoint: existingAnimaFile,
                        loras: enabledLoRAs,
                        onProgress: callback, onPreview: previewCallback)
                } else if let coreMLModel {
                    result = try await LocalImageStudio.shared.generate(
                        prompt: inputPrompt, negative: inputNegative, modelURL: coreMLModel,
                        steps: steps, guidance: scale, seed: inputSeed, aspect: selectedAspect,
                        scheduler: selectedScheduler, upscale: shouldUpscale, safetyCheck: useSafetyCheck,
                        onProgress: callback, onPreview: previewCallback)
                } else { throw StudioError.unavailableModel }
                try Task.checkCancellation()
                latestImage = result.url
                renderPreview = result.url
                let metadata = StudioGenerationMetadata(
                    prompt: inputPrompt, negativePrompt: inputNegative, steps: steps,
                    guidance: Double(scale), seed: inputSeed, aspect: selectedAspect.rawValue,
                    longestEdge: longestEdge)
                try? await LocalImageStudio.shared.saveGenerationMetadata(metadata, for: result.url)
                savedPromptMetadata[result.url.lastPathComponent] = metadata
                savedImages = await LocalImageStudio.shared.savedImages()
                renderStatus.fraction = 1
                if let warning = result.enhancementWarning {
                    renderPhase = .enhancementFailed
                    status = "4× enhancement failed (\(warning)). Your original image is saved and ready to share."
                } else {
                    renderPhase = .completed
                    status = result.enhanced ? "Created and enhanced 4× entirely on this device." : "Created entirely on this device."
                }
            } catch is CancellationError {
                renderPhase = .cancelled
                status = "Render cancelled."
            } catch {
                renderPhase = .failed
                status = "Render failed: \(error.localizedDescription)"
            }
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

private struct StudioImageSelection: Identifiable {
    let url: URL
    var id: String { url.path }
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

/// Five canvas choices fit compact phones without horizontal clipping.
private struct StudioCompactChipStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .minimumScaleFactor(0.8)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 37)
            .foregroundStyle(isSelected ? .white : .white.opacity(0.78))
            .background(isSelected ? AppTheme.accent.opacity(0.42) : AppTheme.surface,
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? AppTheme.accent : AppTheme.border))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

/// Decode small previews only when the gallery row is first displayed. In
/// particular, a download progress update must never re-decode 18 full PNGs.
private struct StudioImageThumbnail: View {
    let url: URL
    let maxPixelDimension: Int
    let fill: Bool
    @State private var preview: UIImage?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let preview {
                if fill { Image(uiImage: preview).resizable().scaledToFill() }
                else { Image(uiImage: preview).resizable().scaledToFit() }
            } else if loadFailed {
                ContentUnavailableView("Preview unavailable", systemImage: "photo.badge.exclamationmark")
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                RoundedRectangle(cornerRadius: 12).fill(AppTheme.surface)
                    .overlay(InfinityLoader(size: 27))
            }
        }
        .task(id: url) {
            preview = nil
            loadFailed = false
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                loadFailed = true
                return
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
                kCGImageSourceShouldCacheImmediately: true
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                preview = UIImage(cgImage: image)
            } else {
                loadFailed = true
            }
        }
    }
}

private enum StudioRenderPhase {
    case idle, rendering, completed, enhancementFailed, failed, cancelled

    var label: String {
        switch self {
        case .idle: "Ready"
        case .rendering: "Rendering"
        case .completed: "Completed"
        case .enhancementFailed: "Original preserved"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}

/// Lightweight, reusable infinity loader: a glowing highlight travels along
/// a continuous figure-eight. It doesn't allocate images or schedule timers.
struct InfinityLoader: View {
    var size: CGFloat = 44
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let phase = reduceMotion ? 0.2 : timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.75) / 1.75
            Canvas { graphics, bounds in
                func point(_ fraction: Double) -> CGPoint {
                    let angle = 2 * Double.pi * fraction
                    return CGPoint(x: bounds.width / 2 + sin(angle) * bounds.width * 0.42,
                                   y: bounds.height / 2 + sin(2 * angle) * bounds.height * 0.32)
                }
                var loop = Path()
                for step in 0...160 {
                    let p = point(Double(step) / 160)
                    if step == 0 { loop.move(to: p) } else { loop.addLine(to: p) }
                }
                graphics.stroke(loop, with: .color(AppTheme.accent.opacity(0.27)),
                                style: StrokeStyle(lineWidth: max(2, size * 0.065), lineCap: .round))
                var shimmer = Path()
                for step in 0...45 {
                    let p = point((phase + Double(step) / 180).truncatingRemainder(dividingBy: 1))
                    if step == 0 { shimmer.move(to: p) } else { shimmer.addLine(to: p) }
                }
                graphics.stroke(shimmer,
                                with: .linearGradient(Gradient(colors: [.clear, AppTheme.accent, .cyan, .white]),
                                                      startPoint: point(phase), endPoint: point(phase + 0.24)),
                                style: StrokeStyle(lineWidth: max(2.5, size * 0.072), lineCap: .round))
                let glow = point(phase + 0.24)
                let diameter = max(3, size * 0.105)
                graphics.fill(Path(ellipseIn: CGRect(x: glow.x - diameter / 2, y: glow.y - diameter / 2,
                                                     width: diameter, height: diameter)), with: .color(.white))
            }
            .shadow(color: AppTheme.accent.opacity(0.65), radius: size * 0.12)
            .frame(width: size, height: size * 0.72)
            .frame(width: size, height: size)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}

/// A cinematic perspective crawl of the actual prompt. This runs solely as a
/// SwiftUI animation; it does not pretend to be a decoded diffusion preview.
private struct StudioPromptCrawl: View {
    let prompt: String
    let reduceMotion: Bool
    @State private var crawlStarted = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 18) {
                Text(prompt)
                    .font(.system(size: 21, weight: .semibold))
                    .lineSpacing(12)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Color(red: 1, green: 0.86, blue: 0.54))
            .shadow(color: Color(red: 1, green: 0.55, blue: 0.25).opacity(0.25), radius: 12)
            .frame(maxWidth: .infinity)
            .rotation3DEffect(.degrees(reduceMotion ? 0 : 55), axis: (x: 1, y: 0, z: 0), perspective: 0.36)
            .offset(y: reduceMotion ? geometry.size.height * 0.18 :
                    (crawlStarted ? -geometry.size.height * 1.6 : geometry.size.height * 0.83))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .mask(LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .white, location: 0.23),
                .init(color: .white, location: 0.78),
                .init(color: .clear, location: 1)
            ], startPoint: .top, endPoint: .bottom))
        }
        .onAppear {
            guard !reduceMotion else { return }
            crawlStarted = false
            withAnimation(.linear(duration: 34).repeatForever(autoreverses: false)) {
                crawlStarted = true
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rendering prompt: \(prompt)")
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
