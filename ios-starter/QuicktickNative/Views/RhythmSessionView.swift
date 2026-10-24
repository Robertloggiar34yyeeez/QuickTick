import SwiftUI
import AVKit
import AudioToolbox
import UIKit

enum RhythmPattern: String, CaseIterable, Identifiable {
    case chill, single, duo, triple, quad, fast, spam, progressive, chaos, adaptive, custom
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var subdivisions: Int {
        switch self {
        case .duo: 2
        case .triple: 3
        case .quad: 4
        case .fast, .spam: 4
        default: 1
        }
    }
}

/// Beat-bar phrases change density within a *single* session. We start with a
/// familiar regular pulse, then visit Duo, Triple and Quad before repeating.
/// Subsequent rounds may shuffle, but never repeat the same phrase twice in a
/// row. This is a local sequencer, not a dependency on the reference editor.
enum RhythmDivision: Int, CaseIterable, Identifiable {
    case regular = 1, duo, triple, quad
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .regular: "Regular"
        case .duo: "Duo"
        case .triple: "Triple"
        case .quad: "Quad"
        }
    }
}

struct RhythmPhraseSequencer {
    private(set) var current: RhythmDivision = .regular
    private(set) var phraseNumber = 0
    private(set) var ticksRemaining = 4
    private var upcoming: [RhythmDivision] = [.duo, .triple, .quad]

    mutating func reset(mode: RhythmPattern, mixed: Bool, quarterBeats: Int = 4) {
        current = mixed ? .regular : (RhythmDivision(rawValue: mode.subdivisions) ?? .regular)
        upcoming = [.duo, .triple, .quad]
        phraseNumber = 0
        ticksRemaining = max(2, quarterBeats) * current.rawValue
    }

    /// Return true only when the next phrase begins. Duration is measured in
    /// quarter notes so a triple phrase isn't three times shorter than regular.
    mutating func tick(mixed: Bool, quarterBeats: Int, shuffle: Bool = true) -> Bool {
        guard mixed else { return false }
        ticksRemaining -= 1
        guard ticksRemaining <= 0 else { return false }
        if upcoming.isEmpty {
            upcoming = RhythmDivision.allCases
            if shuffle { upcoming.shuffle() }
            if upcoming.first == current, let different = upcoming.firstIndex(where: { $0 != current }) {
                upcoming.swapAt(0, different)
            }
        }
        current = upcoming.removeFirst()
        phraseNumber += 1
        ticksRemaining = max(2, quarterBeats) * current.rawValue
        return true
    }
}

/// Local-only auto shuffle. The engine owns its timer and media player, never
/// the feed's PlayerPool, so ending a session cannot disrupt feed autoplay.
struct RhythmSessionView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let posts: [Post]
    let offline: Bool

    @AppStorage("quicktick-rhythm-mode-v1") private var pattern = "adaptive"
    @AppStorage("quicktick-rhythm-bpm-v1") private var bpm = 112
    @AppStorage("quicktick-rhythm-randomness-v1") private var randomness = 0.65
    @AppStorage("quicktick-rhythm-acceleration-v1") private var acceleration = 0.25
    @AppStorage("quicktick-rhythm-transition-v1") private var transitionSpeed = 0.25
    @AppStorage("quicktick-rhythm-metronome-v1") private var metronome = false
    @AppStorage("quicktick-rhythm-haptics-v1") private var haptics = true
    @AppStorage("quicktick-rhythm-manual-v1") private var manual = false
    @AppStorage("quicktick-rhythm-mix-subdivisions-v1") private var mixSubdivisions = true
    @AppStorage("quicktick-rhythm-finish-text-v1") private var finishText = "Beautiful rhythm. Session complete."
    @AppStorage("quicktick-rhythm-finish-style-v1") private var finishStyle = "Glow"
    @AppStorage("quicktick-rhythm-finish-animation-v1") private var finishAnimation = "Scale"

    @State private var deck: [Post] = []
    @State private var index = 0
    @State private var beat = 0
    @State private var phraseSequencer = RhythmPhraseSequencer()
    @State private var switches = 0
    @State private var started = false
    @State private var running = false
    @State private var finished = false
    @State private var nextSwitch = Date.distantFuture
    @State private var player: AVPlayer?
    @State private var resolvedVideoID: String?
    @State private var showFineTune = false

    private var mode: RhythmPattern { RhythmPattern(rawValue: pattern) ?? .adaptive }
    private var current: Post? { deck.indices.contains(index) ? deck[index] : nil }
    private var beatInterval: Double { 60 / Double(max(40, min(260, bpm))) / Double(phraseSequencer.current.rawValue) }
    private var phraseLength: Int {
        // Randomness changes phrase length as well as media switch timing.
        max(2, Int((5 - randomness * 2).rounded()))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if finished {
                    completionPanel
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    mediaPanel
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 24).stroke(AppTheme.border))
                        .animation(reduceMotion ? nil : .easeInOut(duration: transitionSpeed), value: current?.stableID)
                    HStack(spacing: 8) {
                        ForEach(0..<8, id: \.self) { bar in
                            Capsule()
                                .fill(bar == beat ? AppTheme.accent : .white.opacity(0.15))
                                .frame(height: bar == beat ? 28 : 12)
                                .animation(reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.58), value: beat)
                        }
                    }
                    .frame(height: 30)
                    .accessibilityLabel("\(phraseSequencer.current.title), beat \(beat + 1) of 8")
                    HStack(spacing: 12) {
                        Menu {
                            Picker("Rhythm", selection: $pattern) {
                                ForEach(RhythmPattern.allCases) { item in Text(item.title).tag(item.rawValue) }
                            }
                        } label: {
                            Label("\(mode.title) · \(phraseSequencer.current.title)", systemImage: "waveform.path")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("rhythm-current-division")
                        Text("\(bpm) BPM")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .foregroundStyle(AppTheme.secondaryLabel)
                        Button {
                            manual.toggle()
                            nextSwitch = .now.addingTimeInterval(dwellTime())
                        } label: {
                            Image(systemName: manual ? "hand.tap.fill" : "hand.tap")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(manual ? "Manual tap mode on" : "Enable manual tap mode")
                    }
                    if manual {
                        Button { advance() } label: {
                            Label("Tap to beat · Next", systemImage: "hand.tap")
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    DisclosureGroup("Rhythm controls", isExpanded: $showFineTune) {
                        VStack(spacing: 10) {
                            labeledSlider("BPM", value: Binding(get: { Double(bpm) }, set: { bpm = Int($0) }), range: 40...260)
                            labeledSlider("Randomness", value: $randomness, range: 0...1)
                            labeledSlider("Acceleration", value: $acceleration, range: 0...1)
                            labeledSlider("Transitions", value: $transitionSpeed, range: 0.08...0.65)
                            Toggle("Metronome clicks", isOn: $metronome)
                            Toggle("Beat haptics", isOn: $haptics)
                            Toggle("Alternate Regular, Duo, Triple and Quad", isOn: $mixSubdivisions)
                            Text("Each phrase lasts a few beats. Every rhythm appears in one session; the order varies over time.")
                                .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
                        }
                        .font(.subheadline)
                        .padding(.top, 8)
                    }
                    .font(.subheadline.weight(.semibold))
                    .tint(AppTheme.accent)
                    Button {
                        running = false
                        player?.pause()
                        withAnimation(reduceMotion ? nil : .spring(response: 0.46)) { finished = true }
                    } label: {
                        Label("Finish", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accent)
                    .accessibilityIdentifier("rhythm-finish")
                }
            }
            .padding(16)
            .background(AppTheme.canvas)
            .navigationTitle("Rhythm Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } } }
        }
        .onAppear {
            guard !started else { return }
            started = true
            deck = posts.shuffled()
            running = !deck.isEmpty
            resetPhrases()
            nextSwitch = .now.addingTimeInterval(dwellTime())
        }
        .onDisappear { running = false; player?.pause(); player = nil }
        .onChange(of: pattern) { _, _ in resetPhrases() }
        .onChange(of: mixSubdivisions) { _, _ in resetPhrases() }
        .task(id: "\(running):\(bpm):\(pattern):\(manual):\(mixSubdivisions)") {
            guard running else { return }
            while !Task.isCancelled && running {
                beat = (beat + 1) % 8
                if phraseSequencer.tick(mixed: mixSubdivisions, quarterBeats: nextPhraseLength()) {
                    beat = 0
                }
                if metronome { AudioServicesPlaySystemSound(1104) }
                if haptics { UIImpactFeedbackGenerator(style: beat == 0 ? .medium : .light).impactOccurred() }
                if !manual && Date() >= nextSwitch { advance() }
                do { try await Task.sleep(for: .seconds(max(0.075, beatInterval))) }
                catch { return }
            }
        }
        .task(id: current?.stableID) { await prepareCurrentVideo() }
    }

    @ViewBuilder private var mediaPanel: some View {
        if let post = current {
            ZStack {
                AppTheme.elevatedSurface
                if post.type.lowercased() == "video" {
                    if let player, resolvedVideoID == post.stableID {
                        VideoPlayer(player: player).id(post.stableID)
                    } else {
                        CachedMediaImage(url: post.cardPreviewURL, pixels: 960, fill: false)
                        ProgressView().tint(AppTheme.accent)
                    }
                } else if post.type.lowercased() == "gif", offline,
                          let url = URL(string: post.mediaUrl), url.isFileURL {
                    AnimatedGIFSurface(url: url, playing: running)
                } else {
                    CachedMediaImage(url: offline && post.mediaUrl.hasPrefix("file:") ? post.mediaUrl : post.cardPreviewURL,
                                     pixels: 1200, comic: false, fill: false)
                }
            }
            .overlay(alignment: .topLeading) {
                HStack(spacing: 6) {
                    Image(systemName: "shuffle")
                    Text("\(switches + 1) · \(post.provider.uppercased())")
                }
                .font(.caption.weight(.bold)).padding(10)
                .background(.black.opacity(0.55), in: Capsule()).padding(12)
            }
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.965)))
        } else {
            ContentUnavailableView("No media to shuffle", systemImage: "photo.stack",
                                   description: Text("Save some posts first."))
        }
    }

    private var completionPanel: some View {
        VStack(spacing: 22) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 62)).foregroundStyle(AppTheme.accent)
                .symbolEffect(.bounce, value: finished)
            Text(finishText.isEmpty ? "Session complete" : finishText)
                .font(.system(size: 27, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .padding(26)
                .frame(maxWidth: .infinity)
                .background(finishStyle == "Minimal" ? AnyShapeStyle(Color.clear) : AnyShapeStyle(AppTheme.elevatedSurface),
                            in: RoundedRectangle(cornerRadius: 24))
                .shadow(color: finishStyle == "Glow" ? AppTheme.accent.opacity(0.45) : .clear, radius: 25)
                .transition(finishAnimation == "Slide" ? .move(edge: .bottom) :
                                (finishAnimation == "Fade" ? .opacity : .scale.combined(with: .opacity)))
            Text("\(switches + 1) moments · \(mode.title)").foregroundStyle(AppTheme.secondaryLabel)
            Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
        }
    }

    private func labeledSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).frame(width: 100, alignment: .leading)
            Slider(value: value, in: range)
        }
    }

    private func resetPhrases() {
        phraseSequencer.reset(mode: mode, mixed: mixSubdivisions, quarterBeats: phraseLength)
        beat = 0
    }

    private func nextPhraseLength() -> Int {
        let spread = Int((randomness * 2).rounded())
        return Int.random(in: max(2, phraseLength - spread)...max(2, phraseLength + spread))
    }

    private func dwellTime() -> Double {
        let video = current?.type.lowercased() == "video"
        var bounds: ClosedRange<Double> = video ? 3...5 : 0.6...2
        switch mode {
        case .chill: bounds = video ? 4...5 : 1.5...2.0
        case .fast: bounds = video ? 3...3.8 : 0.6...0.95
        case .spam: bounds = video ? 1.8...3 : 0.3...0.6
        case .chaos: bounds = video ? 2.5...5 : 0.45...2
        default: break
        }
        let center = (bounds.lowerBound + bounds.upperBound) / 2
        let spread = (bounds.upperBound - bounds.lowerBound) * randomness
        var seconds = Double.random(in: max(bounds.lowerBound, center - spread / 2)...min(bounds.upperBound, center + spread / 2))
        if mode == .progressive { seconds *= max(0.55, 1 - Double(switches) * acceleration * 0.012) }
        if mode == .custom { seconds *= (112 / Double(max(40, bpm))) }
        return max(0.25, seconds)
    }

    private func advance() {
        guard !deck.isEmpty else { return }
        player?.pause(); player = nil; resolvedVideoID = nil
        switches += 1
        if index + 1 < deck.count { index += 1 }
        else {
            let previous = deck.last?.stableID
            deck.shuffle()
            if deck.count > 1, deck.first?.stableID == previous { deck.swapAt(0, 1) }
            index = 0
        }
        nextSwitch = Date().addingTimeInterval(dwellTime())
        // Reuse the global thumbnail cache; a bounded single-image warmup
        // does not compete with playback or visual-taste inference.
        let following = deck[(index + 1) % deck.count]
        if following.type.lowercased() != "video" {
            Task(priority: .utility) {
                _ = try? await MediaImagePipeline.shared.image(raw: following.cardPreviewURL, pixels: 900)
            }
        }
    }

    private func prepareCurrentVideo() async {
        guard let post = current, post.type.lowercased() == "video" else { return }
        let url: URL?
        if offline { url = URL(string: post.mediaUrl) }
        else { url = try? await store.resolver.resolve(post).mediaUrlURL }
        guard !Task.isCancelled, current?.stableID == post.stableID,
              let url, (!offline || url.isFileURL) else { return }
        let next = AVPlayer(url: url)
        next.isMuted = store.muted
        next.automaticallyWaitsToMinimizeStalling = true
        player = next
        resolvedVideoID = post.stableID
        if running { next.play() }
    }
}
