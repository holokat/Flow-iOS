import AVFoundation
import Foundation
import SwiftUI

struct NoteAudioPlayerView: View {
    let url: URL
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var appSettings: AppSettingsStore
    @State private var player: AVPlayer
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var dragProgress: Double?
    @State private var timeObserverToken: Any?
    @State private var timeControlStatusObserver: NSKeyValueObservation?

    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(appSettings.buttonTextColor)
                    .offset(x: isPlaying ? 0 : 1.5)
                    .frame(
                        width: NoteAudioPlayerLayout.playButtonDiameter,
                        height: NoteAudioPlayerLayout.playButtonDiameter
                    )
                    .background {
                        Circle()
                            .fill(appSettings.primaryGradient)
                    }
                    .shadow(
                        color: appSettings.primaryColor.opacity(isPlaying ? 0.24 : 0.12),
                        radius: isPlaying ? 12 : 7,
                        x: 0,
                        y: isPlaying ? 7 : 4
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause audio" : "Play audio")

            VStack(alignment: .leading, spacing: 8) {
                NoteAudioWaveformScrubber(
                    progress: displayedProgress,
                    isPlaying: isPlaying,
                    isEnabled: hasPlayableDuration,
                    onScrub: { progress in
                        dragProgress = progress
                    },
                    onScrubEnded: { progress in
                        seek(toProgress: progress)
                        dragProgress = nil
                    }
                )

                HStack(spacing: 8) {
                    Text(NoteAudioPlayerLayout.timeText(seconds: displayedTime))
                    Spacer(minLength: 8)
                    Text(durationText)
                }
                .font(appSettings.appFont(.caption2, weight: .medium))
                .foregroundStyle(appSettings.themePalette.secondaryForeground)
                .monospacedDigit()
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(audioPlayerBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(appSettings.themeSeparator(defaultOpacity: 0.72), lineWidth: 0.7)
        )
        .onAppear {
            configurePlaybackObservers()
            updateDurationFromCurrentItem()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
        ) { notification in
            guard let endedItem = notification.object as? AVPlayerItem,
                  endedItem == player.currentItem else { return }
            isPlaying = false
            currentTime = 0
            dragProgress = nil
            player.seek(to: .zero)
        }
        .onDisappear {
            player.pause()
            isPlaying = false
            removePlaybackObservers()
        }
    }

    private var audioPlayerBackground: Color {
        if effectiveAudioColorScheme == .light {
            return .white
        }
        return appSettings.themePalette.secondaryBackground.opacity(0.94)
    }

    private var effectiveAudioColorScheme: ColorScheme {
        appSettings.preferredColorScheme ?? colorScheme
    }

    private var hasPlayableDuration: Bool {
        duration.isFinite && duration > 0
    }

    private var displayedProgress: Double {
        dragProgress ?? NoteAudioPlayerLayout.progress(
            currentTime: currentTime,
            duration: duration
        )
    }

    private var displayedTime: Double {
        guard let dragProgress else { return currentTime }
        return NoteAudioPlayerLayout.seekSeconds(
            forProgress: dragProgress,
            duration: duration
        )
    }

    private var durationText: String {
        guard hasPlayableDuration else { return "--:--" }
        return NoteAudioPlayerLayout.timeText(seconds: duration)
    }

    private func togglePlayback() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            NoteVideoPlaybackAudioSession.activateIfNeeded()
            player.play()
            isPlaying = true
        }
    }

    private func seek(toProgress progress: Double) {
        guard hasPlayableDuration else { return }
        let seconds = NoteAudioPlayerLayout.seekSeconds(
            forProgress: progress,
            duration: duration
        )
        currentTime = seconds
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func configurePlaybackObservers() {
        guard timeObserverToken == nil else { return }

        timeControlStatusObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { observedPlayer, _ in
            DispatchQueue.main.async {
                isPlaying = observedPlayer.timeControlStatus == .playing
            }
        }

        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.12, preferredTimescale: 600),
            queue: .main
        ) { time in
            guard dragProgress == nil else { return }
            let seconds = time.seconds
            if seconds.isFinite {
                currentTime = seconds
            }
            updateDurationFromCurrentItem()
        }
    }

    private func removePlaybackObservers() {
        if let timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
            self.timeObserverToken = nil
        }

        timeControlStatusObserver?.invalidate()
        timeControlStatusObserver = nil
    }

    private func updateDurationFromCurrentItem() {
        guard let seconds = player.currentItem?.duration.seconds,
              seconds.isFinite,
              seconds > 0 else {
            return
        }
        duration = seconds
    }
}

enum NoteAudioPlayerLayout {
    static let playButtonDiameter: CGFloat = 54
    static let waveformHeight: CGFloat = 44
    static let waveformBarCount = 40

    static func progress(currentTime: Double, duration: Double) -> Double {
        guard currentTime.isFinite,
              duration.isFinite,
              duration > 0 else {
            return 0
        }
        return min(max(currentTime / duration, 0), 1)
    }

    static func seekSeconds(forProgress progress: Double, duration: Double) -> Double {
        guard progress.isFinite,
              duration.isFinite,
              duration > 0 else {
            return 0
        }
        return min(max(progress, 0), 1) * duration
    }

    static func waveformBarHeight(
        index: Int,
        phase: Double,
        isPlaying: Bool,
        maxHeight: CGFloat = waveformHeight
    ) -> CGFloat {
        let base = 0.34 + (sin(Double(index) * 0.74) + 1) * 0.23
        let motion = isPlaying ? (sin((phase * 4.2) + Double(index) * 0.58) + 1) * 0.18 : 0
        let normalized = min(max(base + motion, 0.18), 0.96)
        return max(8, maxHeight * normalized)
    }

    static func timeText(seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds.rounded(.down))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes):\(String(format: "%02d", seconds))"
    }
}

private struct NoteAudioWaveformScrubber: View {
    let progress: Double
    let isPlaying: Bool
    let isEnabled: Bool
    let onScrub: (Double) -> Void
    let onScrubEnded: (Double) -> Void

    @EnvironmentObject private var appSettings: AppSettingsStore

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !isPlaying)) { context in
            GeometryReader { proxy in
                let clampedProgress = min(max(progress, 0), 1)
                let phase = isPlaying ? context.date.timeIntervalSinceReferenceDate : 0
                let width = max(proxy.size.width, 1)
                let barCount = NoteAudioPlayerLayout.waveformBarCount
                let spacing: CGFloat = 3
                let barWidth = max(2.5, (width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))
                let filledBarCount = Int((clampedProgress * Double(barCount)).rounded(.down))

                HStack(alignment: .center, spacing: spacing) {
                    ForEach(0..<barCount, id: \.self) { index in
                        Capsule(style: .continuous)
                            .fill(barFill(for: index, filledBarCount: filledBarCount))
                            .frame(
                                width: barWidth,
                                height: NoteAudioPlayerLayout.waveformBarHeight(
                                    index: index,
                                    phase: phase,
                                    isPlaying: isPlaying,
                                    maxHeight: NoteAudioPlayerLayout.waveformHeight
                                )
                            )
                    }
                }
                .frame(width: width, height: NoteAudioPlayerLayout.waveformHeight, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard isEnabled else { return }
                            onScrub(progress(forX: value.location.x, width: width))
                        }
                        .onEnded { value in
                            guard isEnabled else { return }
                            onScrubEnded(progress(forX: value.location.x, width: width))
                        }
                )
            }
        }
        .frame(height: NoteAudioPlayerLayout.waveformHeight)
        .accessibilityElement()
        .accessibilityLabel("Audio progress")
        .accessibilityValue("\(Int(min(max(progress, 0), 1) * 100)) percent")
        .accessibilityHint(isEnabled ? "Drag to seek" : "Duration unavailable")
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            let step = 0.05
            switch direction {
            case .increment:
                onScrubEnded(min(progress + step, 1))
            case .decrement:
                onScrubEnded(max(progress - step, 0))
            @unknown default:
                break
            }
        }
    }

    private func progress(forX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(max(Double(x / width), 0), 1)
    }

    private func barFill(for index: Int, filledBarCount: Int) -> Color {
        if index < filledBarCount {
            return appSettings.primaryColor.opacity(isEnabled ? 0.95 : 0.62)
        }

        return appSettings.themePalette.secondaryFill.opacity(isPlaying ? 0.88 : 0.72)
    }
}
