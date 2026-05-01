import AVFoundation
import AVKit
import SwiftUI
import UIKit

enum NoteNativeVideoBufferingPolicy {
    static let preferredForwardBufferDuration: TimeInterval = 12
}

private final class NoteInlineAVPlayerViewController: AVPlayerViewController {
    override var childForStatusBarHidden: UIViewController? {
        nil
    }

    override var prefersStatusBarHidden: Bool {
        false
    }
}

struct NoteNativeVideoPlayerController: UIViewControllerRepresentable {
    let url: URL
    var autoplay: Bool = true
    var showsPlaybackControls: Bool = true
    var isMuted: Bool = false
    var loops: Bool = false
    var onPlaybackStateChange: ((Bool) -> Void)? = nil

    final class Coordinator {
        let player = AVPlayer()
        private var currentURL: URL?
        private var shouldAutoplayForCurrentURL = true
        private var isMutedForCurrentURL = false
        private var loopsCurrentURL = false
        private var playbackEndedObserver: NSObjectProtocol?
        private var playbackStatusObserver: NSKeyValueObservation?
        private var onPlaybackStateChange: ((Bool) -> Void)?
        private var lastKnownIsPlaying = false

        deinit {
            removePlaybackEndedObserver()
            playbackStatusObserver?.invalidate()
        }

        func configure(
            url: URL,
            autoplay: Bool,
            isMuted: Bool,
            loops: Bool,
            controller: AVPlayerViewController,
            onPlaybackStateChange: ((Bool) -> Void)?
        ) {
            self.onPlaybackStateChange = onPlaybackStateChange
            observePlaybackStateIfNeeded()
            isMutedForCurrentURL = isMuted
            loopsCurrentURL = loops
            player.isMuted = isMuted
            player.volume = isMuted ? 0 : 1
            player.automaticallyWaitsToMinimizeStalling = true

            if currentURL != url || controller.player !== player {
                currentURL = url
                shouldAutoplayForCurrentURL = autoplay
                controller.player = player
                player.actionAtItemEnd = loops ? .none : .pause
                let item = AVPlayerItem(url: url)
                item.preferredForwardBufferDuration = NoteNativeVideoBufferingPolicy.preferredForwardBufferDuration
                player.replaceCurrentItem(with: item)
                observePlaybackEnded(for: item)
                publishPlaybackState(false)
            } else {
                shouldAutoplayForCurrentURL = shouldAutoplayForCurrentURL || autoplay
                player.actionAtItemEnd = loops ? .none : .pause
            }

            guard controller.player === player else { return }

            if shouldAutoplayForCurrentURL {
                NoteVideoPlaybackAudioSession.configureForMediaPlayback()
                if !isMuted {
                    NoteVideoPlaybackAudioSession.activateIfNeeded()
                }
                player.play()
                shouldAutoplayForCurrentURL = false
            }
        }

        func stop() {
            removePlaybackEndedObserver()
            playbackStatusObserver?.invalidate()
            playbackStatusObserver = nil
            player.pause()
            player.replaceCurrentItem(with: nil)
            currentURL = nil
            onPlaybackStateChange = nil
            publishPlaybackState(false)
        }

        private func observePlaybackStateIfNeeded() {
            guard playbackStatusObserver == nil else { return }

            playbackStatusObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
                let isPlaying = player.timeControlStatus == .playing
                DispatchQueue.main.async {
                    guard let self else { return }
                    if isPlaying, !self.isMutedForCurrentURL {
                        NoteVideoPlaybackAudioSession.activateIfNeeded()
                    }
                    self.publishPlaybackState(isPlaying)
                }
            }
        }

        private func observePlaybackEnded(for item: AVPlayerItem) {
            removePlaybackEndedObserver()
            playbackEndedObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }

                if self.loopsCurrentURL {
                    self.player.seek(
                        to: .zero,
                        toleranceBefore: .zero,
                        toleranceAfter: .zero
                    ) { [weak self] finished in
                        guard finished, let self else { return }
                        NoteVideoPlaybackAudioSession.configureForMediaPlayback()
                        self.player.play()
                    }
                } else {
                    self.publishPlaybackState(false)
                }
            }
        }

        private func removePlaybackEndedObserver() {
            guard let playbackEndedObserver else { return }
            NotificationCenter.default.removeObserver(playbackEndedObserver)
            self.playbackEndedObserver = nil
        }

        private func publishPlaybackState(_ isPlaying: Bool) {
            guard lastKnownIsPlaying != isPlaying else { return }
            lastKnownIsPlaying = isPlaying
            onPlaybackStateChange?(isPlaying)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = NoteInlineAVPlayerViewController()
        controller.showsPlaybackControls = showsPlaybackControls
        controller.videoGravity = .resizeAspect
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.exitsFullScreenWhenPlaybackEnds = false
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        controller.modalPresentationCapturesStatusBarAppearance = false
        controller.view.backgroundColor = .clear
        controller.view.isOpaque = false
        controller.contentOverlayView?.backgroundColor = .clear
        controller.setNeedsStatusBarAppearanceUpdate()
        context.coordinator.configure(
            url: url,
            autoplay: autoplay,
            isMuted: isMuted,
            loops: loops,
            controller: controller,
            onPlaybackStateChange: onPlaybackStateChange
        )
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        uiViewController.showsPlaybackControls = showsPlaybackControls
        uiViewController.modalPresentationCapturesStatusBarAppearance = false
        uiViewController.view.backgroundColor = .clear
        uiViewController.view.isOpaque = false
        uiViewController.contentOverlayView?.backgroundColor = .clear
        uiViewController.setNeedsStatusBarAppearanceUpdate()
        context.coordinator.configure(
            url: url,
            autoplay: autoplay,
            isMuted: isMuted,
            loops: loops,
            controller: uiViewController,
            onPlaybackStateChange: onPlaybackStateChange
        )
    }

    static func dismantleUIViewController(
        _ uiViewController: AVPlayerViewController,
        coordinator: Coordinator
    ) {
        uiViewController.player = nil
        coordinator.stop()
    }
}
