import AVFoundation
import CryptoKit
import Foundation
import MediaPlayer
import NowPlaying
import Observation

@MainActor
final class HaloAudioPlaybackCoordinator: ObservableObject {
    static let shared = HaloAudioPlaybackCoordinator()

    @Published private(set) var currentURL: URL?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0

    private let player = AVPlayer()
    private var timeObserverToken: Any?
    private var timeControlStatusObserver: NSKeyValueObservation?
    private var playbackEndedObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
    private var nowPlayingBridge27: AnyObject?

    private init() {
        player.automaticallyWaitsToMinimizeStalling = true
        configurePlaybackObservers()
        configureAudioInterruptionObserver()
        configureLegacyRemoteCommands()

        if #available(iOS 27.0, *) {
            nowPlayingBridge27 = HaloNowPlayingBridge27(coordinator: self)
        }
    }

    deinit {
        if let timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
        }
        timeControlStatusObserver?.invalidate()
        if let playbackEndedObserver {
            NotificationCenter.default.removeObserver(playbackEndedObserver)
        }
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        for (command, target) in remoteCommandTargets {
            command.removeTarget(target)
        }
    }

    func isCurrent(_ url: URL) -> Bool {
        currentURL == url
    }

    func toggle(url: URL) {
        if currentURL == url, isPlaying {
            pause()
        } else {
            play(url: url)
        }
    }

    func play(url: URL) {
        if currentURL != url {
            replaceCurrentItem(with: url)
        }

        NoteVideoPlaybackAudioSession.activateIfNeeded()
        player.play()
        publishPlaybackState()

        if #available(iOS 27.0, *),
           let bridge = nowPlayingBridge27 as? HaloNowPlayingBridge27 {
            Task {
                await bridge.requestSystemPrimary()
            }
        }
    }

    func play() {
        guard currentURL != nil else { return }
        NoteVideoPlaybackAudioSession.activateIfNeeded()
        player.play()
        publishPlaybackState()
    }

    func pause() {
        player.pause()
        publishPlaybackState()
    }

    func seek(url: URL, toProgress progress: Double) {
        guard currentURL == url, duration.isFinite, duration > 0 else { return }
        let seconds = NoteAudioPlayerLayout.seekSeconds(
            forProgress: progress,
            duration: duration
        )
        seek(toSeconds: seconds)
    }

    func seek(toSeconds seconds: Double) {
        guard currentURL != nil, duration.isFinite, duration > 0 else { return }
        let clampedSeconds = min(max(seconds, 0), duration)
        currentTime = clampedSeconds
        player.seek(
            to: CMTime(seconds: clampedSeconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        publishPlaybackState()
    }

    private func replaceCurrentItem(with url: URL) {
        removePlaybackEndedObserver()
        currentURL = url
        currentTime = 0
        duration = 0

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 12
        player.replaceCurrentItem(with: item)
        observePlaybackEnded(for: item)
        publishPlaybackState()
    }

    private func configurePlaybackObservers() {
        timeControlStatusObserver = player.observe(
            \.timeControlStatus,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.publishPlaybackState()
            }
        }

        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if time.seconds.isFinite {
                    self.currentTime = max(0, time.seconds)
                }
                self.updateDurationFromCurrentItem()
                self.publishNowPlayingState()
            }
        }
    }

    private func observePlaybackEnded(for item: AVPlayerItem) {
        playbackEndedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.player.pause()
                self.player.seek(to: .zero)
                self.currentTime = 0
                self.publishPlaybackState()
            }
        }
    }

    private func removePlaybackEndedObserver() {
        guard let playbackEndedObserver else { return }
        NotificationCenter.default.removeObserver(playbackEndedObserver)
        self.playbackEndedObserver = nil
    }

    private func configureAudioInterruptionObserver() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else {
                return
            }
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt

            Task { @MainActor [weak self] in
                guard let self,
                      let type = AVAudioSession.InterruptionType(rawValue: rawType) else {
                    return
                }

                switch type {
                case .began:
                    self.pause()
                case .ended:
                    guard let rawOptions,
                          AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume) else {
                        return
                    }
                    self.play()
                @unknown default:
                    break
                }
            }
        }
    }

    private func updateDurationFromCurrentItem() {
        guard let seconds = player.currentItem?.duration.seconds,
              seconds.isFinite,
              seconds > 0 else {
            return
        }
        duration = seconds
    }

    private func publishPlaybackState() {
        isPlaying = player.timeControlStatus == .playing
        updateDurationFromCurrentItem()
        publishNowPlayingState()
    }

    private func publishNowPlayingState() {
        if #available(iOS 27.0, *),
           let bridge = nowPlayingBridge27 as? HaloNowPlayingBridge27 {
            bridge.update(
                url: currentURL,
                isPlaying: isPlaying,
                elapsedTime: currentTime,
                duration: duration
            )
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        guard let currentURL else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: "Audio note",
            MPMediaItemPropertyAlbumTitle: AppBrand.displayName,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyExternalContentIdentifier: Self.contentIdentifier(for: currentURL)
        ]
        if duration.isFinite, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func configureLegacyRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false

        let playTarget = commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        remoteCommandTargets.append((commandCenter.playCommand, playTarget))

        let pauseTarget = commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        remoteCommandTargets.append((commandCenter.pauseCommand, pauseTarget))

        let toggleTarget = commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying ? self.pause() : self.play()
            }
            return .success
        }
        remoteCommandTargets.append((commandCenter.togglePlayPauseCommand, toggleTarget))

        let seekTarget = commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in
                self?.seek(toSeconds: event.positionTime)
            }
            return .success
        }
        remoteCommandTargets.append((commandCenter.changePlaybackPositionCommand, seekTarget))
    }

    fileprivate static func contentIdentifier(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

@available(iOS 27.0, *)
@Observable
@MainActor
private final class HaloNowPlayingModel27: MediaSessionRepresentable {
    let id = "halo-audio-session"

    @ObservationIgnored weak var coordinator: HaloAudioPlaybackCoordinator?
    private var contentID: String?
    private var isPlaying = false
    private var elapsedTime: Double = 0
    private var durationSeconds: Double = 0

    init(coordinator: HaloAudioPlaybackCoordinator) {
        self.coordinator = coordinator
    }

    var content: (any MediaContentRepresentable)? {
        guard let contentID else { return nil }
        let mediaDuration: MediaDuration? = durationSeconds.isFinite && durationSeconds > 0
            ? .finite(durationSeconds)
            : nil
        return GenericContent(
            id: contentID,
            title: "Audio note",
            subtitle: AppBrand.displayName,
            type: .audio,
            duration: mediaDuration,
            artwork: nil
        )
    }

    var playbackSnapshot: MediaPlaybackSnapshot? {
        guard contentID != nil else { return nil }
        return MediaPlaybackSnapshot(
            state: isPlaying ? .playing() : .paused,
            elapsedTime: elapsedTime,
            timestamp: Date()
        )
    }

    var commands: [MediaCommand] {
        [
            .play { [weak coordinator] in
                coordinator?.play()
            },
            .pause { [weak coordinator] in
                coordinator?.pause()
            },
            .togglePlayPause { [weak coordinator] in
                guard let coordinator else { return }
                coordinator.isPlaying ? coordinator.pause() : coordinator.play()
            },
            .seekToPosition { [weak coordinator] position in
                coordinator?.seek(toSeconds: position)
            }
        ]
    }

    func update(url: URL?, isPlaying: Bool, elapsedTime: Double, duration: Double) {
        contentID = url.map(HaloAudioPlaybackCoordinator.contentIdentifier(for:))
        self.isPlaying = isPlaying
        self.elapsedTime = elapsedTime
        durationSeconds = duration
    }
}

@available(iOS 27.0, *)
@MainActor
private final class HaloNowPlayingBridge27 {
    private let model: HaloNowPlayingModel27
    private let session: MediaSession<HaloNowPlayingModel27>

    init(coordinator: HaloAudioPlaybackCoordinator) {
        model = HaloNowPlayingModel27(coordinator: coordinator)
        session = MediaSession(model)
    }

    func update(url: URL?, isPlaying: Bool, elapsedTime: Double, duration: Double) {
        model.update(
            url: url,
            isPlaying: isPlaying,
            elapsedTime: elapsedTime,
            duration: duration
        )
    }

    func requestSystemPrimary() async {
        try? await session.requestToBecomeApplicationPrimary()
        try? await session.requestToBecomeSystemPrimary()
    }
}
