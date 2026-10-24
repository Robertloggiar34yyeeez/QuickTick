import SwiftUI
import AVKit
import AVFoundation
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

/// A short synthesized, high-presence click mixed through the app's audio
/// session. System sound 1104 was barely audible and has no per-click gain.
@MainActor
final class RhythmClickSound: ObservableObject {
    private let strong: AVAudioPlayer?
    private let soft: AVAudioPlayer?

    init() {
        strong = try? AVAudioPlayer(data: Self.wave(pitch: 1_900))
        soft = try? AVAudioPlayer(data: Self.wave(pitch: 1_400))
        strong?.prepareToPlay()
        soft?.prepareToPlay()
    }

    func play(accented: Bool, gain: Double) {
        guard let player = accented ? strong : soft else {
            AudioServicesPlaySystemSound(1104)
            return
        }
        player.volume = Float(min(1, max(0, gain)))
        player.currentTime = 0
        player.play()
    }

    private static func wave(pitch: Double) -> Data {
        let sampleRate = 44_100
        let frames = Int(Double(sampleRate) * 0.095)
        var wav = Data()
        func bytes(_ s: String) { wav.append(contentsOf: s.utf8) }
        func word(_ number: UInt16) {
            var little = number.littleEndian
            withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
        }
        func dword(_ number: UInt32) {
            var little = number.littleEndian
            withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
        }
        bytes("RIFF"); dword(UInt32(36 + frames * 2)); bytes("WAVE")
        bytes("fmt "); dword(16); word(1); word(1)
        dword(UInt32(sampleRate)); dword(UInt32(sampleRate * 2)); word(2); word(16)
        bytes("data"); dword(UInt32(frames * 2))
        for frame in 0..<frames {
            let seconds = Double(frame) / Double(sampleRate)
            let envelope = exp(-seconds * 47) * min(1, seconds * 16_000)
            let tone = sin(2 * .pi * pitch * seconds) * 0.77
                + sin(2 * .pi * pitch * 1.91 * seconds) * 0.23
            let sample = Int16((max(-1, min(1, tone * envelope * 1.85)) * Double(Int16.max)).rounded())
            word(UInt16(bitPattern: sample))
        }
        return wav
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
    @AppStorage("quicktick-rhythm-click-volume-v1") private var clickVolume = 1.0
    @AppStorage("quicktick-rhythm-bars-per-phrase-v1") private var barsPerPhrase = 4
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
    @State private var controlsVisible = true
    @StateObject private var clickSound = RhythmClickSound()

    private var mode: RhythmPattern { RhythmPattern(rawValue: pattern) ?? .adaptive }
    private var current: Post? { deck.indices.contains(index) ? deck[index] : nil }
    private var beatInterval: Double { 60 / Double(max(40, min(260, bpm))) / Double(phraseSequencer.current.rawValue) }
    private var phraseLength: Int {
        // Four bars at 112 BPM last ~8.6 seconds; several images/videos
        // should pass before a subdivision changes. Not every post is a phrase.
        max(2, min(8, barsPerPhrase)) * 4
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
              ZStack {
                AppTheme.canvas.ignoresSafeArea()
                if finished {
                    completionPanel
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    mediaPanel
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea(edges: .all)
                        .animation(reduceMotion ? nil : .easeInOut(duration: transitionSpeed), value: current?.stableID)
                    VStack(spacing: 12) {
                        HStack(spacing: 10) {
                            Button { dismiss() } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 16, weight: .bold))
                                    .frame(width: 46, height: 46)
                            }
                            .accessibilityLabel("Close Rhythm Mode")
                            Spacer()
                            Button {
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { controlsVisible.toggle() }
                            } label: {
                                Image(systemName: controlsVisible ? "eye.slash" : "slider.horizontal.3")
                                    .frame(width: 46, height: 46)
                            }
                            .accessibilityLabel(controlsVisible ? "Hide rhythm controls" : "Show rhythm controls")
                            Button { finishSession() } label: {
                                Label("Finish", systemImage: "checkmark.circle.fill")
                                    .font(.subheadline.weight(.bold))
                                    .padding(.horizontal, 15)
                                    .frame(height: 46)
                            }
                            .accessibilityIdentifier("rhythm-finish")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .background {
                            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                                .padding(.horizontal, -18).padding(.top, -18).frame(height: 90, alignment: .top)
                        }
                        Spacer(minLength: 0)
                        if controlsVisible { rhythmHUD.transition(.move(edge: .bottom).combined(with: .opacity)) }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                    .padding(.bottom, 12)
                }
              }
              .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showFineTune) { rhythmSettingsSheet }
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
                if metronome { clickSound.play(accented: beat == 0, gain: clickVolume) }
                if haptics { UIImpactFeedbackGenerator(style: beat == 0 ? .medium : .light).impactOccurred() }
                if !manual && Date() >= nextSwitch { advance() }
                do { try await Task.sleep(for: .seconds(max(0.075, beatInterval))) }
                catch { return }
            }
        }
        .task(id: current?.stableID) { await prepareCurrentVideo() }
    }

    private var rhythmHUD: some View {
        VStack(spacing: 9) {
            HStack {
                Text("\(phraseSequencer.current.title.uppercased())  ·  \(barsPerPhrase) BARS")
                    .font(.caption2.weight(.bold)).tracking(1.2)
                Spacer()
                Text("\(switches + 1)  ·  \(bpm) BPM")
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
            .foregroundStyle(.white.opacity(0.86))
            HStack(spacing: 7) {
                ForEach(0..<8, id: \.self) { bar in
                    Capsule()
                        .fill(bar == beat ? AppTheme.accent : .white.opacity(0.24))
                        .frame(maxWidth: .infinity)
                        .frame(height: bar == beat ? 26 : 9)
                        .animation(reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.64), value: beat)
                }
            }
            .frame(height: 27)
            .accessibilityLabel("\(phraseSequencer.current.title), beat \(beat + 1) of 8")
            HStack(spacing: 8) {
                Menu {
                    Picker("Rhythm", selection: $pattern) {
                        ForEach(RhythmPattern.allCases) { item in Text(item.title).tag(item.rawValue) }
                    }
                } label: {
                    Label("\(mode.title) · \(phraseSequencer.current.title)", systemImage: "waveform.path")
                        .lineLimit(1).minimumScaleFactor(0.76)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .accessibilityIdentifier("rhythm-current-division")
                Button {
                    manual.toggle()
                    nextSwitch = .now.addingTimeInterval(dwellTime())
                } label: { Image(systemName: manual ? "hand.tap.fill" : "hand.tap").frame(width: 44, height: 44) }
                .accessibilityLabel(manual ? "Manual tap mode on" : "Enable manual tap mode")
                Button { showFineTune = true } label: {
                    Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Rhythm settings")
            }
            .buttonStyle(.bordered)
            if manual {
                Button { advance() } label: {
                    Label("Tap to beat · Next", systemImage: "hand.tap")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent)
            }
        }
        .padding(13)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 23, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 23).stroke(AppTheme.accent.opacity(0.35)))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
    }

    private var rhythmSettingsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    labeledSlider("BPM", value: Binding(get: { Double(bpm) }, set: { bpm = Int($0) }), range: 40...260)
                    labeledSlider("Randomness", value: $randomness, range: 0...1)
                    labeledSlider("Acceleration", value: $acceleration, range: 0...1)
                    labeledSlider("Transitions", value: $transitionSpeed, range: 0.08...0.65)
                    labeledSlider("Bars per rhythm", value: Binding(get: { Double(barsPerPhrase) }, set: { barsPerPhrase = Int($0) }), range: 2...8)
                    Text("\(barsPerPhrase) bars per phrase. Posts continue switching at their own pace.")
                        .font(.caption).foregroundStyle(AppTheme.secondaryLabel)
                    Toggle("Metronome clicks", isOn: $metronome)
                    labeledSlider("Click volume", value: $clickVolume, range: 0.4...1)
                    Toggle("Beat haptics", isOn: $haptics)
                    Toggle("Alternate Regular, Duo, Triple and Quad", isOn: $mixSubdivisions)
                }
                .font(.subheadline)
                .padding(20)
            }
            .background(AppTheme.canvas)
            .navigationTitle("Rhythm settings")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { showFineTune = false } } }
        }
        .presentationDetents([.medium, .large])
        .tint(AppTheme.accent)
    }

    private func finishSession() {
        running = false
        player?.pause()
        withAnimation(reduceMotion ? nil : .spring(response: 0.46)) { finished = true }
    }

    @ViewBuilder private var mediaPanel: some View {
        if let post = current {
            ZStack {
                Color.black
                CachedMediaImage(url: post.cardPreviewURL, pixels: 700, comic: false, fill: true)
                    .blur(radius: 34).scaleEffect(1.12).opacity(0.68)
                Color.black.opacity(0.26)
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
            .clipped()
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
        let spreadInBars = Int((randomness * 1.5).rounded())
        let bars = max(2, min(8, barsPerPhrase + Int.random(in: -spreadInBars...spreadInBars)))
        return bars * 4
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
