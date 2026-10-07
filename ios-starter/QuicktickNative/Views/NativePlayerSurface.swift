import SwiftUI
import AVFoundation
import UIKit

struct NativePlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    let fill: Bool
    @Binding var ready: Bool
    func makeUIView(context: Context) -> PlayerLayerView { let view = PlayerLayerView(); view.isAccessibilityElement = true; view.accessibilityIdentifier = "video-frame"; return view }
    func updateUIView(_ view: PlayerLayerView, context: Context) {
        context.coordinator.ready = $ready
        view.accessibilityValue = view.layerPlayer.isReadyForDisplay ? "Ready" : "Loading"
        view.layerPlayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        if view.layerPlayer.player !== player {
            context.coordinator.observation = nil
            context.coordinator.generation = UUID()
            let generation = context.coordinator.generation
            view.layerPlayer.player = player
            let coordinator = context.coordinator
            coordinator.observation = view.layerPlayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
                let isReady = layer.isReadyForDisplay
                Task { @MainActor in if coordinator.generation == generation { coordinator.ready.wrappedValue = isReady } }
            }
        }
    }
    static func dismantleUIView(_ view: PlayerLayerView, coordinator: Coordinator) {
        coordinator.generation = UUID(); coordinator.observation = nil; view.layerPlayer.player = nil
    }
    func makeCoordinator() -> Coordinator { Coordinator(ready: $ready) }
    @MainActor final class Coordinator {
        var generation = UUID()
        var ready: Binding<Bool>
        var observation: NSKeyValueObservation?
        init(ready: Binding<Bool>) { self.ready = ready }
    }
}

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var layerPlayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
