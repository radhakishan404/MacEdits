import AppKit
import AVFoundation
import AVKit
import SwiftUI

struct PlayerPreviewView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.setPlayer(player)
        return view
    }

    func updateNSView(_ nsView: PlayerContainerView, context: Context) {
        nsView.setPlayer(player)
    }
}

final class PlayerContainerView: NSView {
    private let playerView = AVPlayerView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspectFill
        playerView.showsFrameSteppingButtons = false
        playerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(playerView)

        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerView.topAnchor.constraint(equalTo: topAnchor),
            playerView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setPlayer(_ player: AVPlayer) {
        playerView.player = player
    }
}
