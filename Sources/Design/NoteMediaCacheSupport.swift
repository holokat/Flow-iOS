import AVFoundation
import Foundation
import NostrSDK
import UIKit

actor NoteVideoAspectRatioCache {
    static let shared = NoteVideoAspectRatioCache()

    private var cachedRatios: [URL: CGFloat] = [:]
    private var inFlight: [URL: Task<CGFloat?, Never>] = [:]

    func ratio(for url: URL) async -> CGFloat? {
        if let persistedRatio = FlowMediaAspectRatioCache.shared.ratio(for: url) {
            cachedRatios[url] = persistedRatio
            return persistedRatio
        }

        if let cached = cachedRatios[url] {
            return cached
        }

        if let existingTask = inFlight[url] {
            return await existingTask.value
        }

        let task = Task(priority: .utility) {
            await Self.loadRatio(for: url)
        }
        inFlight[url] = task

        let ratio = await task.value
        inFlight[url] = nil

        if let ratio {
            cachedRatios[url] = ratio
            FlowMediaAspectRatioCache.shared.insert(ratio, for: url)
        }

        return ratio
    }

    private static func loadRatio(for url: URL) async -> CGFloat? {
        let asset = AVURLAsset(url: url)

        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else { return nil }

            let naturalSize = try await track.load(.naturalSize)
            let preferredTransform = try await track.load(.preferredTransform)
            let transformedSize = naturalSize.applying(preferredTransform)

            let width = abs(transformedSize.width)
            let height = abs(transformedSize.height)
            guard width > 0, height > 0 else { return nil }

            return max(0.4, min(width / height, 3.0))
        } catch {
            return nil
        }
    }
}

actor NoteShortMP4LoopPolicy {
    static let shared = NoteShortMP4LoopPolicy()
    static let maximumLoopingDurationSeconds: TimeInterval = 4

    private var cachedDecisions: [URL: Bool] = [:]
    private var inFlight: [URL: Task<Bool, Never>] = [:]

    static func isCandidateURL(_ url: URL) -> Bool {
        url.pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "mp4"
    }

    func shouldLoop(url: URL) async -> Bool {
        guard Self.isCandidateURL(url) else { return false }

        if let cached = cachedDecisions[url] {
            return cached
        }

        if let existingTask = inFlight[url] {
            return await existingTask.value
        }

        let task = Task(priority: .utility) {
            await Self.loadShouldLoop(url: url)
        }
        inFlight[url] = task

        let shouldLoop = await task.value
        inFlight[url] = nil
        cachedDecisions[url] = shouldLoop

        return shouldLoop
    }

    private static func loadShouldLoop(url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)

        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            return seconds.isFinite &&
                seconds > 0 &&
                seconds <= maximumLoopingDurationSeconds
        } catch {
            return false
        }
    }
}

actor NoteMediaGeometryPrefetcher {
    static let shared = NoteMediaGeometryPrefetcher()

    private let maxPrefetchedImages = 36
    private let maxPrefetchedVideos = 12

    func prefetch(events: [NostrEvent]) async {
        let candidates = Self.mediaCandidates(in: events)

        for hint in candidates.hints {
            FlowMediaAspectRatioCache.shared.insert(hint.ratio, forURLString: hint.urlString)
        }

        await withTaskGroup(of: Void.self) { group in
            for url in candidates.imageURLs.prefix(maxPrefetchedImages) {
                group.addTask {
                    _ = await FlowImageCache.shared.aspectRatio(for: url)
                }
            }

            for url in candidates.videoURLs.prefix(maxPrefetchedVideos) {
                group.addTask {
                    _ = await NoteVideoAspectRatioCache.shared.ratio(for: url)
                }
            }

            await group.waitForAll()
        }
    }

    private static func mediaCandidates(
        in events: [NostrEvent]
    ) -> (imageURLs: [URL], videoURLs: [URL], hints: [(urlString: String, ratio: CGFloat)]) {
        var imageURLs: [URL] = []
        var videoURLs: [URL] = []
        var hints: [(urlString: String, ratio: CGFloat)] = []
        var seenImageURLs = Set<String>()
        var seenVideoURLs = Set<String>()
        var seenHintURLs = Set<String>()

        for event in events {
            for tag in event.tags where tag.first?.lowercased() == "imeta" {
                var urlString: String?
                var pixelSize: CGSize?

                for value in tag.dropFirst() {
                    if value.hasPrefix("url ") {
                        urlString = String(value.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                    } else if value.hasPrefix("dim ") {
                        pixelSize = Self.pixelSize(fromDimensionString: String(value.dropFirst(4)))
                    }
                }

                guard let urlString,
                      !urlString.isEmpty,
                      let pixelSize,
                      let ratio = NoteImageLayoutGuide.normalizedAspectRatio(pixelSize.width / max(pixelSize.height, 1)) else {
                    continue
                }

                let key = urlString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard seenHintURLs.insert(key).inserted else { continue }
                hints.append((urlString: urlString, ratio: ratio))
            }

            for token in NoteContentParser.tokenize(event: event) {
                switch token.type {
                case .image:
                    appendURL(
                        token.value,
                        to: &imageURLs,
                        seen: &seenImageURLs
                    )
                case .video:
                    appendURL(
                        token.value,
                        to: &videoURLs,
                        seen: &seenVideoURLs
                    )
                default:
                    continue
                }
            }
        }

        return (imageURLs, videoURLs, hints)
    }

    private static func appendURL(
        _ rawValue: String,
        to urls: inout [URL],
        seen: inout Set<String>
    ) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return
        }

        let key = url.absoluteString.lowercased()
        guard seen.insert(key).inserted else { return }
        urls.append(url)
    }

    private static func pixelSize(fromDimensionString value: String) -> CGSize? {
        let sanitized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "×", with: "x")
            .replacingOccurrences(of: "X", with: "x")
        let components = sanitized.split(separator: "x", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard components.count == 2,
              let width = Double(components[0]),
              let height = Double(components[1]),
              width > 0,
              height > 0 else {
            return nil
        }

        return CGSize(width: width, height: height)
    }
}

final class NoteVideoThumbnailCache {
    static let shared = NoteVideoThumbnailCache()

    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        cache.countLimit = 96
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func insert(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
}

func generateNoteVideoThumbnail(for url: URL, maximumPixelSize: CGSize) async -> UIImage? {
    let asset = AVURLAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = maximumPixelSize

    do {
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)
        let candidateSeconds = [
            0.15,
            0.8,
            durationSeconds.isFinite && durationSeconds > 0
                ? min(max(durationSeconds * 0.18, 0.25), min(durationSeconds, 2.0))
                : 1.0
        ]

        for seconds in candidateSeconds {
            let time = CMTime(seconds: max(seconds, 0), preferredTimescale: 600)
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                return UIImage(cgImage: cgImage)
            }
        }
    } catch {
        for seconds in [0.15, 0.8, 1.0] {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                return UIImage(cgImage: cgImage)
            }
        }
    }

    return nil
}
