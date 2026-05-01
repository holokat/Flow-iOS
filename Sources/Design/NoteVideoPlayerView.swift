import SwiftUI
import UIKit

struct NoteVideoPlayerView: View {
    let url: URL
    let layout: NoteContentMediaLayout
    let isGIFLike: Bool
    let aspectRatioHint: CGFloat?
    @State private var videoAspectRatio: CGFloat
    @State private var videoThumbnail: UIImage?
    @State private var isPlaying = false
    @State private var shortMP4LoopURL: URL?

    init(
        url: URL,
        layout: NoteContentMediaLayout,
        isGIFLike: Bool = false,
        aspectRatioHint: CGFloat? = nil
    ) {
        self.url = url
        self.layout = layout
        self.isGIFLike = isGIFLike
        let normalizedHint = NoteImageLayoutGuide.normalizedAspectRatio(aspectRatioHint)
        self.aspectRatioHint = normalizedHint
        _videoAspectRatio = State(
            initialValue: NoteImageLayoutGuide.reservedVideoAspectRatio(
                exactHint: normalizedHint,
                cachedExactRatio: FlowMediaAspectRatioCache.shared.ratio(for: url)
            )
        )
    }

    var body: some View {
        let rendersAsGIFLikeVideo = isGIFLike || shortMP4LoopURL == url

        NoteAspectRatioMediaLayout(
            aspectRatio: videoAspectRatio,
            maxHeight: maxVideoHeight
        ) {
            ZStack {
                Color.black.opacity(0.08)

                NoteNativeVideoPlayerController(
                    url: url,
                    autoplay: rendersAsGIFLikeVideo,
                    showsPlaybackControls: !rendersAsGIFLikeVideo,
                    isMuted: rendersAsGIFLikeVideo,
                    loops: rendersAsGIFLikeVideo,
                    onPlaybackStateChange: { nextIsPlaying in
                        isPlaying = nextIsPlaying
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !isPlaying {
                    thumbnailLayer
                        .allowsHitTesting(false)
                        .transition(.opacity)

                    if !rendersAsGIFLikeVideo {
                        previewPlayAffordance
                    }
                }
            }
        }
        .clipShape(
            RoundedRectangle(cornerRadius: mediaCornerRadius, style: .continuous)
        )
        .contentShape(
            RoundedRectangle(cornerRadius: mediaCornerRadius, style: .continuous)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: url, priority: .utility) {
            await MainActor.run {
                shortMP4LoopURL = nil
                videoThumbnail = NoteVideoThumbnailCache.shared.image(for: url)
            }
            async let shortMP4LoopPolicy: Void = loadShortMP4LoopPolicy()
            async let aspectRatioLoad: Void = loadVideoAspectRatio()
            async let thumbnailLoad: Void = loadVideoThumbnailIfNeeded()
            _ = await (shortMP4LoopPolicy, aspectRatioLoad, thumbnailLoad)
        }
    }

    @ViewBuilder
    private var thumbnailLayer: some View {
        if let videoThumbnail {
            Image(uiImage: videoThumbnail)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
    }

    private var maxVideoHeight: CGFloat {
        min(UIScreen.main.bounds.height * 0.72, 620)
    }

    private var mediaCornerRadius: CGFloat {
        layout == .feed ? 18 : 12
    }

    private var previewPlayAffordance: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 66, height: 66)

            Image(systemName: "play.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .offset(x: 2)
        }
        .shadow(color: .black.opacity(0.24), radius: 14, y: 6)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .transition(.opacity)
    }

    private func loadVideoAspectRatio() async {
        setVideoAspectRatio(
            NoteImageLayoutGuide.reservedVideoAspectRatio(
                exactHint: aspectRatioHint,
                cachedExactRatio: FlowMediaAspectRatioCache.shared.ratio(for: url)
            )
        )

        guard let ratio = await NoteVideoAspectRatioCache.shared.ratio(for: url) else { return }
        guard !Task.isCancelled else { return }

        setVideoAspectRatio(ratio)
    }

    @MainActor
    private func setVideoAspectRatio(_ nextRatio: CGFloat) {
        guard abs(videoAspectRatio - nextRatio) > 0.02 else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            videoAspectRatio = nextRatio
        }
    }

    private func loadVideoThumbnailIfNeeded() async {
        if let cached = NoteVideoThumbnailCache.shared.image(for: url) {
            await MainActor.run {
                videoThumbnail = cached
            }
            return
        }

        let thumbnailPixelSize = await MainActor.run {
            CGSize(
                width: max(UIScreen.main.bounds.width - 28, 1) * UIScreen.main.scale,
                height: max(maxVideoHeight, 1) * UIScreen.main.scale
            )
        }

        let generatedThumbnail: UIImage? = await Task.detached(priority: .utility) {
            await generateNoteVideoThumbnail(for: url, maximumPixelSize: thumbnailPixelSize)
        }.value

        guard !Task.isCancelled else { return }

        await MainActor.run {
            videoThumbnail = generatedThumbnail
        }

        guard let generatedThumbnail else { return }
        NoteVideoThumbnailCache.shared.insert(generatedThumbnail, for: url)
    }

    private func loadShortMP4LoopPolicy() async {
        guard !isGIFLike else { return }

        let shouldLoop = await NoteShortMP4LoopPolicy.shared.shouldLoop(url: url)
        guard !Task.isCancelled else { return }

        await MainActor.run {
            shortMP4LoopURL = shouldLoop ? url : nil
        }
    }
}

private struct NoteAspectRatioMediaLayout: Layout {
    let aspectRatio: CGFloat
    let maxHeight: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        FlowLayoutGuardrails.aspectFitMediaSize(
            availableWidth: proposal.width,
            aspectRatio: aspectRatio,
            maxHeight: maxHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let size = FlowLayoutGuardrails.aspectFitMediaSize(
            availableWidth: bounds.width,
            aspectRatio: aspectRatio,
            maxHeight: maxHeight
        )
        let origin = CGPoint(x: bounds.minX, y: bounds.minY)

        for subview in subviews {
            subview.place(
                at: origin,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
        }
    }
}
