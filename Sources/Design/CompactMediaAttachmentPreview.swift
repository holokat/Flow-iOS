import AVFoundation
import SwiftUI

struct CompactMediaAttachmentPreview: View {
    private static let hlsMimeTypes: Set<String> = [
        "application/vnd.apple.mpegurl",
        "application/x-mpegurl",
        "application/mpegurl",
        "audio/mpegurl",
        "audio/x-mpegurl"
    ]

    private enum Kind {
        case image
        case video
        case audio
        case file

        var iconName: String {
            switch self {
            case .image:
                return "photo"
            case .video:
                return "video"
            case .audio:
                return "waveform"
            case .file:
                return "paperclip"
            }
        }

        var badgeTitle: String? {
            switch self {
            case .image:
                return nil
            case .video:
                return nil
            case .audio:
                return "Audio"
            case .file:
                return "File"
            }
        }
    }

    static let thumbnailWidth: CGFloat = 132
    static let thumbnailHeight: CGFloat = 132

    let url: URL
    let mimeType: String
    let fileSizeBytes: Int?
    let colorScheme: ColorScheme
    let onTap: (() -> Void)?

    init(
        url: URL,
        mimeType: String,
        fileSizeBytes: Int?,
        colorScheme: ColorScheme,
        onTap: (() -> Void)? = nil
    ) {
        self.url = url
        self.mimeType = mimeType
        self.fileSizeBytes = fileSizeBytes
        self.colorScheme = colorScheme
        self.onTap = onTap
    }

    private var kind: Kind {
        let normalizedMIMEType = mimeType.lowercased()
        let path = url.path.lowercased()

        if normalizedMIMEType.hasPrefix("image/") || [".jpg", ".jpeg", ".png", ".webp", ".gif", ".heic", ".bmp", ".svg"].contains(where: path.hasSuffix) {
            return .image
        }
        if normalizedMIMEType.hasPrefix("video/") ||
            Self.hlsMimeTypes.contains(normalizedMIMEType) ||
            [".mp4", ".mov", ".m4v", ".webm", ".mkv", ".m3u8"].contains(where: path.hasSuffix) {
            return .video
        }
        if normalizedMIMEType.hasPrefix("audio/") || [".mp3", ".m4a", ".aac", ".wav", ".ogg"].contains(where: path.hasSuffix) {
            return .audio
        }
        return .file
    }

    var body: some View {
        Group {
            if let onTap {
                Button(action: onTap) {
                    content
                }
                .buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    private var content: some View {
        ZStack {
            previewContent

            if let fileSizeLabel {
                badgeLabel(fileSizeLabel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(6)
            }

            if let badgeTitle = kind.badgeTitle {
                HStack(spacing: 4) {
                    Image(systemName: kind.iconName)
                        .font(.system(size: 10, weight: .semibold))
                    Text(badgeTitle)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(6)
            }
        }
        .frame(width: Self.thumbnailWidth, height: Self.thumbnailHeight)
        .background(Color(.tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.2), lineWidth: 0.8)
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        switch kind {
        case .image:
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    progressPlaceholder
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    placeholder(iconName: kind.iconName)
                @unknown default:
                    placeholder(iconName: kind.iconName)
                }
            }
        case .video:
            ZStack {
                VideoThumbnailView(url: url)

                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 32, height: 32)
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                            .offset(x: 1)
                    }
            }
        case .audio, .file:
            placeholder(iconName: kind.iconName)
        }
    }

    private var progressPlaceholder: some View {
        ZStack {
            Color(.tertiarySystemFill)
            ProgressView()
                .controlSize(.small)
        }
    }

    private func placeholder(iconName: String) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(.secondarySystemFill),
                    Color(.tertiarySystemFill)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Image(systemName: iconName)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var fileSizeLabel: String? {
        guard let fileSizeBytes, fileSizeBytes > 0 else { return nil }

        if fileSizeBytes >= 1_024 * 1_024 {
            let megabytes = Double(fileSizeBytes) / (1_024 * 1_024)
            return String(format: "%.1f mb", megabytes)
        }

        let kilobytes = max(1, Int(ceil(Double(fileSizeBytes) / 1_024)))
        return "\(kilobytes) kb"
    }

    private func badgeLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
    }
}

private struct VideoThumbnailView: View {
    let url: URL

    @State private var thumbnail: UIImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(.secondarySystemFill),
                            Color(.tertiarySystemFill)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .task(id: url) {
            guard thumbnail == nil else { return }

            let thumbnailPixelSize = await MainActor.run {
                CGSize(
                    width: CompactMediaAttachmentPreview.thumbnailWidth * UIScreen.main.scale,
                    height: CompactMediaAttachmentPreview.thumbnailHeight * UIScreen.main.scale
                )
            }

            let generatedThumbnail: UIImage? = await Task.detached(priority: .userInitiated) {
                let asset = AVURLAsset(url: url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = thumbnailPixelSize

                let time = CMTime(seconds: 0.15, preferredTimescale: 600)
                guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
                    return nil
                }
                return UIImage(cgImage: cgImage)
            }.value

            guard !Task.isCancelled else { return }
            thumbnail = generatedThumbnail
        }
    }
}
