import AVFoundation
import SwiftUI
import UIKit

struct NoteInlineFeedVideoPlayer: UIViewRepresentable {
    let url: URL
    let isPlaying: Bool
    let onPlaybackEnded: () -> Void

    final class Coordinator {
        let player = AVPlayer()
        private var currentURL: URL?
        private var playbackEndedObserver: NSObjectProtocol?
        private var onPlaybackEnded: (() -> Void)?

        deinit {
            removePlaybackEndedObserver()
        }

        func configure(
            url: URL,
            in view: NoteInlineFeedVideoPlayerContainerView,
            isPlaying: Bool,
            onPlaybackEnded: @escaping () -> Void
        ) {
            self.onPlaybackEnded = onPlaybackEnded
            view.playerLayer.player = player

            if currentURL != url {
                currentURL = url

                let item = AVPlayerItem(url: url)
                player.actionAtItemEnd = .pause
                player.replaceCurrentItem(with: item)
                observePlaybackEnded(for: item)
            }

            if isPlaying {
                NoteVideoPlaybackAudioSession.activateIfNeeded()
                if player.timeControlStatus != .playing {
                    player.play()
                }
            } else {
                player.pause()
            }
        }

        func stop() {
            removePlaybackEndedObserver()
            player.pause()
            player.replaceCurrentItem(with: nil)
            currentURL = nil
            onPlaybackEnded = nil
        }

        private func observePlaybackEnded(for item: AVPlayerItem) {
            removePlaybackEndedObserver()
            playbackEndedObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.player.pause()
                self.player.seek(to: .zero)
                self.onPlaybackEnded?()
            }
        }

        private func removePlaybackEndedObserver() {
            guard let playbackEndedObserver else { return }
            NotificationCenter.default.removeObserver(playbackEndedObserver)
            self.playbackEndedObserver = nil
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> NoteInlineFeedVideoPlayerContainerView {
        let view = NoteInlineFeedVideoPlayerContainerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = context.coordinator.player
        context.coordinator.configure(
            url: url,
            in: view,
            isPlaying: isPlaying,
            onPlaybackEnded: onPlaybackEnded
        )
        return view
    }

    func updateUIView(_ uiView: NoteInlineFeedVideoPlayerContainerView, context: Context) {
        uiView.playerLayer.videoGravity = .resizeAspect
        uiView.playerLayer.player = context.coordinator.player
        context.coordinator.configure(
            url: url,
            in: uiView,
            isPlaying: isPlaying,
            onPlaybackEnded: onPlaybackEnded
        )
    }

    static func dismantleUIView(
        _ uiView: NoteInlineFeedVideoPlayerContainerView,
        coordinator: Coordinator
    ) {
        uiView.playerLayer.player = nil
        coordinator.stop()
    }
}

final class NoteInlineFeedVideoPlayerContainerView: UIView {
    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}
