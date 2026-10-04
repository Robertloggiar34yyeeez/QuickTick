import SwiftUI
import AVFoundation
import UIKit

struct NativePlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    let fill: Bool
    @Binding var ready: Bool
    func makeUIView(context: Context) -> PlayerLayerView { PlayerLayerView() }
    func updateUIView(_ view: PlayerLayerView, context: Context) {
        view.layerPlayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        if view.layerPlayer.player !== player {
            view.layerPlayer.player = player
            let coordinator = context.coordinator
            coordinator.observation = view.layerPlayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { layer, _ in
                let isReady = layer.isReadyForDisplay
                Task { @MainActor in coordinator.ready.wrappedValue = isReady }
            }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(ready: $ready) }
    @MainActor final class Coordinator {
        var ready: Binding<Bool>
        var observation: NSKeyValueObservation?
        init(ready: Binding<Bool>) { self.ready = ready }
    }
}

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var layerPlayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
