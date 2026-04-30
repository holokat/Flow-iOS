import AVFoundation
import AVKit
import ImageIO
import SwiftUI
import UIKit

struct ComposeMediaAttachmentStrip: View {
    @EnvironmentObject private var appSettings: AppSettingsStore

    let attachments: [ComposeMediaAttachment]
    let colorScheme: ColorScheme
    let onPreview: (ComposeMediaAttachment) -> Void
    let onRemove: (ComposeMediaAttachment) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        CompactMediaAttachmentPreview(
                            url: attachment.url,
                            mimeType: attachment.mimeType,
                            fileSizeBytes: attachment.fileSizeBytes,
                            colorScheme: colorScheme,
                            onTap: {
                                onPreview(attachment)
                            }
                        )

                        Button {
                            onRemove(attachment)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(appSettings.themePalette.iconMutedForeground)
                                .padding(6)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove attachment")
                    }
                }
            }
            .padding(.horizontal, 1)
            .padding(.vertical, 1)
        }
    }
}

struct ComposeMediaAttachmentPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    let attachment: ComposeMediaAttachment
    @State private var isAnimatingGIF = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black
                    .ignoresSafeArea()

                if attachment.isVideo {
                    VideoPreviewPlayer(url: attachment.url)
                        .ignoresSafeArea(edges: .bottom)
                } else if attachment.isImage {
                    ComposeAttachmentImagePreview(
                        url: attachment.url,
                        animateGIF: attachment.isGIF && isAnimatingGIF
                    )
                    .padding()
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: attachment.isAudio ? "waveform" : "paperclip")
                            .font(.system(size: 34, weight: .medium))
                        Text("Preview isn't available for this attachment.")
                            .font(.body)
                    }
                    .foregroundStyle(.white.opacity(0.84))
                }
            }
            .toolbar {
                if attachment.isGIF {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(isAnimatingGIF ? "Pause" : "Animate") {
                            isAnimatingGIF.toggle()
                        }
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    ThemedToolbarDoneButton {
                        dismiss()
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }
}

private struct ComposeAttachmentImagePreview: View {
    let url: URL
    let animateGIF: Bool

    @State private var animatedImage: UIImage?
    @State private var animatedImageLoadFailed = false

    var body: some View {
        Group {
            if animateGIF {
                animatedPreview
            } else {
                staticPreview
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: animateGIF) {
            guard animateGIF, animatedImage == nil, !animatedImageLoadFailed else { return }

            let decodedImage: UIImage? = await Task.detached(priority: .userInitiated) {
                guard let data = await FlowImageCache.shared.data(for: url) else {
                    return nil
                }
                return ComposeGIFImageDecoder.image(from: data)
            }.value

            guard !Task.isCancelled else { return }
            animatedImage = decodedImage
            animatedImageLoadFailed = decodedImage == nil
        }
    }

    @ViewBuilder
    private var staticPreview: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .empty:
                ProgressView()
                    .tint(.white)
            case .success(let image):
                image
                    .resizable()
                    .scaledToFit()
            case .failure:
                previewFailureIcon
            @unknown default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var animatedPreview: some View {
        if let animatedImage {
            ComposeAnimatedUIImageView(
                image: animatedImage,
                contentMode: .scaleAspectFit
            )
        } else if animatedImageLoadFailed {
            staticPreview
        } else {
            ProgressView()
                .tint(.white)
        }
    }

    private var previewFailureIcon: some View {
        Image(systemName: "exclamationmark.triangle")
            .font(.largeTitle)
            .foregroundStyle(.white.opacity(0.8))
    }
}

private struct VideoPreviewPlayer: View {
    @State private var player: AVPlayer

    init(url: URL) {
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VideoPlayer(player: player)
            .background(Color.black)
            .onAppear {
                let audioSession = AVAudioSession.sharedInstance()
                try? audioSession.setCategory(
                    .playback,
                    mode: .moviePlayback,
                    options: [.mixWithOthers]
                )
            }
            .onDisappear {
                player.pause()
            }
    }
}

private struct ComposeAnimatedUIImageView: UIViewRepresentable {
    let image: UIImage
    let contentMode: UIView.ContentMode

    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.backgroundColor = .clear
        imageView.clipsToBounds = true
        imageView.isUserInteractionEnabled = false
        return imageView
    }

    func updateUIView(_ imageView: UIImageView, context: Context) {
        imageView.stopAnimating()
        imageView.contentMode = contentMode
        imageView.image = image
        if image.images != nil {
            imageView.startAnimating()
        }
    }

    static func dismantleUIView(_ imageView: UIImageView, coordinator: ()) {
        imageView.stopAnimating()
        imageView.image = nil
    }
}

private enum ComposeGIFImageDecoder {
    static func image(from data: Data) -> UIImage? {
        guard data.starts(with: [0x47, 0x49, 0x46]),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }

        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 1 else {
            return UIImage(data: data)
        }

        var frames: [UIImage] = []
        frames.reserveCapacity(frameCount)
        var totalDuration: TimeInterval = 0

        for index in 0..<frameCount {
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            totalDuration += frameDuration(forFrameAt: index, source: source)
            frames.append(UIImage(cgImage: frame, scale: UIScreen.main.scale, orientation: .up))
        }

        guard !frames.isEmpty else {
            return UIImage(data: data)
        }

        return UIImage.animatedImage(
            with: frames,
            duration: max(totalDuration, Double(frames.count) * 0.1)
        )
    }

    private static func frameDuration(forFrameAt index: Int, source: CGImageSource) -> TimeInterval {
        let defaultDelay = 0.1
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gifProperties = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
            return defaultDelay
        }

        let unclampedDelay = (gifProperties[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
        let delay = (gifProperties[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
        let frameDelay = unclampedDelay ?? delay ?? defaultDelay
        return frameDelay < 0.02 ? defaultDelay : frameDelay
    }
}
