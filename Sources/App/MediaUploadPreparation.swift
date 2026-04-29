import AVFoundation
import CoreTransferable
import Foundation
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PreparedUploadMedia {
    let data: Data
    let mimeType: String
    let fileExtension: String
    let previewImage: UIImage?

    init(
        data: Data,
        mimeType: String,
        fileExtension: String,
        previewImage: UIImage? = nil
    ) {
        self.data = data
        self.mimeType = mimeType
        self.fileExtension = fileExtension
        self.previewImage = previewImage
    }
}

enum MediaUploadPreparationError: LocalizedError {
    case missingVideoFile
    case unsupportedVideoExport
    case videoCompressionFailed

    var errorDescription: String? {
        switch self {
        case .missingVideoFile:
            return "Couldn't access the selected video."
        case .unsupportedVideoExport:
            return "This video format can't be optimized right now."
        case .videoCompressionFailed:
            return "Couldn't optimize the selected video."
        }
    }
}

enum MediaUploadPreparation {
    private static let lightCompressionThresholdBytes = 24 * 1_024 * 1_024
    private static let aggressiveCompressionThresholdBytes = 80 * 1_024 * 1_024
    private static let maxStillImageUploadBytes = 1_500 * 1_024
    private static let maxStillImageDimension: CGFloat = 3_000
    private static let maxProfileImageDimension: CGFloat = 460
    private static let profileBannerTargetSize = CGSize(width: 1_200, height: 1_600)
    private static let maxProfileBannerBytes = 2_500 * 1_024
    private static let animatedProfileGIFVideoThresholdBytes = 1 * 1_024 * 1_024
    private static let animatedProfileVideoBitRate = 420_000
    private static let animatedGIFUploadVideoMaxDimension: CGFloat = 720
    private static let animatedGIFUploadVideoBitRate = 900_000
    private static let animatedGIFUploadMinimumSavingsRatio = 0.98
    private static let stillImageDownscaleStep: CGFloat = 0.88
    private static let minimumStillImageDimension: CGFloat = 1_200
    private static let stillImageJPEGQualities: [CGFloat] = [0.92, 0.88, 0.84, 0.80, 0.76, 0.72]

    static func prepareUploadMedia(from item: PhotosPickerItem) async throws -> PreparedUploadMedia {
        let contentType = preferredContentType(for: item)
        let mimeType = contentType.preferredMIMEType ?? fallbackMimeType(for: contentType)
        let fileExtension = contentType.preferredFilenameExtension ?? defaultFileExtension(for: mimeType)

        if contentType.conforms(to: UTType.movie) || mimeType.lowercased().hasPrefix("video/") {
            let sourceURL = try await loadTemporaryFileURL(from: item, contentType: contentType, fallbackFileExtension: fileExtension)
            defer { try? FileManager.default.removeItem(at: sourceURL) }
            return try await prepareVideoUpload(from: sourceURL, mimeType: mimeType, fallbackFileExtension: fileExtension)
        }

        guard let data = try await item.loadTransferable(type: Data.self), !data.isEmpty else {
            throw MediaUploadError.missingFileData
        }

        let optimizedMedia = optimizeStillImageIfUseful(
            data: data,
            contentType: contentType,
            mimeType: mimeType,
            fileExtension: fileExtension
        )

        return optimizedMedia ?? PreparedUploadMedia(
            data: data,
            mimeType: mimeType,
            fileExtension: fileExtension.lowercased()
        )
    }

    static func prepareUploadMedia(
        data: Data,
        mimeType: String,
        fileExtension: String
    ) throws -> PreparedUploadMedia {
        guard !data.isEmpty else {
            throw MediaUploadError.missingFileData
        }

        let inferredContentType = UTType(mimeType: mimeType) ?? UTType(filenameExtension: fileExtension)
        let optimizedMedia = optimizeStillImageIfUseful(
            data: data,
            contentType: inferredContentType,
            mimeType: mimeType,
            fileExtension: fileExtension
        )

        return optimizedMedia ?? PreparedUploadMedia(
            data: data,
            mimeType: mimeType,
            fileExtension: fileExtension.lowercased()
        )
    }

    static func prepareUploadMedia(
        fileURL: URL,
        mimeType: String,
        fileExtension: String
    ) async throws -> PreparedUploadMedia {
        try await prepareVideoUpload(from: fileURL, mimeType: mimeType, fallbackFileExtension: fileExtension)
    }

    static func prepareGIFKeyboardUploadMedia(
        data: Data,
        mimeType: String,
        fileExtension: String
    ) async throws -> PreparedUploadMedia {
        guard !data.isEmpty else {
            throw MediaUploadError.missingFileData
        }

        let contentType = UTType(mimeType: mimeType) ?? UTType(filenameExtension: fileExtension)
        if isGIFAsset(mimeType: mimeType, fileExtension: fileExtension),
           let optimizedVideo = await optimizedAnimatedGIFVideoPayload(
               from: data,
               contentType: contentType,
               maxDimension: animatedGIFUploadVideoMaxDimension,
               bitRate: animatedGIFUploadVideoBitRate,
               minimumSavingsRatio: animatedGIFUploadMinimumSavingsRatio,
               outputFilePrefix: "gif-upload-",
               requiresProfileOptimizationThreshold: false
           ) {
            return optimizedVideo
        }

        return try prepareUploadMedia(
            data: data,
            mimeType: mimeType,
            fileExtension: fileExtension
        )
    }

    static func prepareProfileImageUpload(from item: PhotosPickerItem) async throws -> PreparedUploadMedia {
        let contentType = preferredContentType(for: item)
        let mimeType = contentType.preferredMIMEType ?? fallbackMimeType(for: contentType)
        let fileExtension = contentType.preferredFilenameExtension ?? defaultFileExtension(for: mimeType)

        guard let data = try await item.loadTransferable(type: Data.self), !data.isEmpty else {
            throw MediaUploadError.missingFileData
        }

        return try await prepareProfileImageUpload(
            data: data,
            mimeType: mimeType,
            fileExtension: fileExtension
        )
    }

    static func prepareProfileImageUpload(
        data: Data,
        mimeType: String,
        fileExtension: String
    ) async throws -> PreparedUploadMedia {
        guard !data.isEmpty else {
            throw MediaUploadError.missingFileData
        }

        let contentType = UTType(mimeType: mimeType) ?? UTType(filenameExtension: fileExtension)
        if isGIFAsset(mimeType: mimeType, fileExtension: fileExtension) {
            if let optimizedVideo = await optimizedProfileGIFVideoPayload(
                from: data,
                contentType: contentType
            ) {
                return optimizedVideo
            }

            return PreparedUploadMedia(
                data: data,
                mimeType: mimeType,
                fileExtension: fileExtension.lowercased()
            )
        }

        if let optimized = optimizedProfileImagePayload(
            from: data,
            contentType: contentType,
            originalMimeType: mimeType,
            originalFileExtension: fileExtension
        ) {
            return optimized
        }

        return try prepareUploadMedia(
            data: data,
            mimeType: mimeType,
            fileExtension: fileExtension
        )
    }

    static func prepareProfileBannerUpload(from item: PhotosPickerItem) async throws -> PreparedUploadMedia {
        let contentType = preferredContentType(for: item)
        let mimeType = contentType.preferredMIMEType ?? fallbackMimeType(for: contentType)
        let fileExtension = contentType.preferredFilenameExtension ?? defaultFileExtension(for: mimeType)

        guard let data = try await item.loadTransferable(type: Data.self), !data.isEmpty else {
            throw MediaUploadError.missingFileData
        }

        return try prepareProfileBannerUpload(
            data: data,
            mimeType: mimeType,
            fileExtension: fileExtension
        )
    }

    static func prepareProfileBannerUpload(
        data: Data,
        mimeType: String,
        fileExtension: String
    ) throws -> PreparedUploadMedia {
        guard !data.isEmpty else {
            throw MediaUploadError.missingFileData
        }

        let contentType = UTType(mimeType: mimeType) ?? UTType(filenameExtension: fileExtension)
        if let optimized = optimizedProfileBannerPayload(
            from: data,
            contentType: contentType,
            originalMimeType: mimeType,
            originalFileExtension: fileExtension
        ) {
            return optimized
        }

        return try prepareUploadMedia(
            data: data,
            mimeType: mimeType,
            fileExtension: fileExtension
        )
    }

    private static func isGIFAsset(
        mimeType: String,
        fileExtension: String
    ) -> Bool {
        let normalizedMimeType = mimeType.lowercased()
        let normalizedExtension = fileExtension.lowercased()
        return normalizedExtension == "gif" ||
            normalizedMimeType.contains("gif")
    }

    private static func optimizedProfileGIFVideoPayload(
        from data: Data,
        contentType: UTType?
    ) async -> PreparedUploadMedia? {
        await optimizedAnimatedGIFVideoPayload(
            from: data,
            contentType: contentType,
            maxDimension: maxProfileImageDimension,
            bitRate: animatedProfileVideoBitRate,
            minimumSavingsRatio: 1.0,
            outputFilePrefix: "profile-gif-",
            requiresProfileOptimizationThreshold: true
        )
    }

    private static func optimizedAnimatedGIFVideoPayload(
        from data: Data,
        contentType: UTType?,
        maxDimension: CGFloat,
        bitRate: Int,
        minimumSavingsRatio: Double,
        outputFilePrefix: String,
        requiresProfileOptimizationThreshold: Bool
    ) async -> PreparedUploadMedia? {
        if let contentType, contentType.conforms(to: .movie) {
            return nil
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 1 else {
            return nil
        }

        let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelWidth = (sourceProperties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let pixelHeight = (sourceProperties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let longestEdge = max(pixelWidth, pixelHeight)
        if requiresProfileOptimizationThreshold,
           data.count < animatedProfileGIFVideoThresholdBytes,
           longestEdge <= maxProfileImageDimension {
            return nil
        }

        let outputURL = temporaryFileURL(prefix: outputFilePrefix, fileExtension: "mp4")
        defer {
            try? FileManager.default.removeItem(at: outputURL)
        }

        let previewImage = animatedGIFPreviewImage(from: source, targetMaxDimension: maxDimension)

        do {
            try await transcodeAnimatedGIFToVideo(
                source: source,
                outputURL: outputURL,
                originalWidth: pixelWidth,
                originalHeight: pixelHeight,
                frameCount: frameCount,
                maxDimension: maxDimension,
                bitRate: bitRate
            )
        } catch {
            return nil
        }

        guard let outputData = try? Data(contentsOf: outputURL),
              !outputData.isEmpty,
              Double(outputData.count) < Double(data.count) * minimumSavingsRatio else {
            return nil
        }

        return PreparedUploadMedia(
            data: outputData,
            mimeType: "video/mp4",
            fileExtension: "mp4",
            previewImage: previewImage
        )
    }

    private static func prepareVideoUpload(
        from sourceURL: URL,
        mimeType: String,
        fallbackFileExtension: String
    ) async throws -> PreparedUploadMedia {
        let originalData = try Data(contentsOf: sourceURL)
        guard !originalData.isEmpty else {
            throw MediaUploadError.missingFileData
        }

        let originalSize = originalData.count
        let optimizedURL = await optimizedVideoURLIfNeeded(
            from: sourceURL,
            mimeType: mimeType,
            fallbackFileExtension: fallbackFileExtension,
            originalSize: originalSize
        )

        defer {
            if let optimizedURL {
                try? FileManager.default.removeItem(at: optimizedURL)
            }
        }

        let finalData: Data
        let finalExtension: String
        let finalMimeType: String

        if let optimizedURL,
           let optimizedData = try? Data(contentsOf: optimizedURL),
           !optimizedData.isEmpty,
           optimizedData.count < originalData.count {
            finalData = optimizedData
            finalExtension = optimizedURL.pathExtension.isEmpty
                ? fallbackFileExtension.lowercased()
                : optimizedURL.pathExtension.lowercased()
            finalMimeType = UTType(filenameExtension: finalExtension)?.preferredMIMEType ?? mimeType
        } else {
            finalData = originalData
            finalExtension = sourceURL.pathExtension.isEmpty
                ? fallbackFileExtension.lowercased()
                : sourceURL.pathExtension.lowercased()
            finalMimeType = UTType(filenameExtension: finalExtension)?.preferredMIMEType ?? mimeType
        }

        return PreparedUploadMedia(
            data: finalData,
            mimeType: finalMimeType,
            fileExtension: finalExtension
        )
    }

    private static func optimizedVideoURLIfNeeded(
        from sourceURL: URL,
        mimeType: String,
        fallbackFileExtension: String,
        originalSize: Int
    ) async -> URL? {
        let normalizedMimeType = mimeType.lowercased()
        let normalizedExtension = fallbackFileExtension.lowercased()
        let shouldAttemptCompression =
            originalSize >= lightCompressionThresholdBytes ||
            normalizedMimeType.contains("quicktime") ||
            normalizedExtension == "mov"

        guard shouldAttemptCompression else {
            return nil
        }

        let asset = AVURLAsset(url: sourceURL)
        let presets = preferredExportPresets(for: asset, originalSize: originalSize)

        for presetName in presets {
            let candidateURL = try? await exportCompressedVideo(
                from: sourceURL,
                presetName: presetName,
                mimeType: mimeType,
                fallbackFileExtension: fallbackFileExtension
            )

            guard let candidateURL else { continue }
            let candidateSize = measuredFileSize(at: candidateURL)

            if candidateSize > 0, candidateSize < originalSize {
                return candidateURL
            }

            try? FileManager.default.removeItem(at: candidateURL)
        }

        return nil
    }

    private static func exportCompressedVideo(
        from sourceURL: URL,
        presetName: String,
        mimeType: String,
        fallbackFileExtension: String
    ) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: presetName) else {
            throw MediaUploadPreparationError.videoCompressionFailed
        }

        let outputFileType = preferredOutputFileType(for: exportSession) ?? .mov
        let outputExtension = fileExtension(for: outputFileType) ?? fallbackFileExtension.lowercased()
        let outputURL = temporaryFileURL(prefix: "video-upload-", fileExtension: outputExtension)

        exportSession.outputURL = outputURL
        exportSession.outputFileType = outputFileType
        exportSession.shouldOptimizeForNetworkUse = true

        try await export(session: exportSession)
        return outputURL
    }

    private static func preferredExportPresets(for asset: AVAsset, originalSize: Int) -> [String] {
        let presets = AVAssetExportSession.exportPresets(compatibleWith: asset)
        var preferredPresets = [
            AVAssetExportPresetPassthrough,
            AVAssetExportPresetHighestQuality
        ]

        if originalSize >= aggressiveCompressionThresholdBytes {
            preferredPresets.append(contentsOf: [
                AVAssetExportPreset1920x1080,
                AVAssetExportPreset1280x720,
                AVAssetExportPresetMediumQuality
            ])
        }

        return preferredPresets.filter { presets.contains($0) }
    }

    private static func preferredOutputFileType(for exportSession: AVAssetExportSession) -> AVFileType? {
        if exportSession.supportedFileTypes.contains(.mp4) {
            return .mp4
        }
        if exportSession.supportedFileTypes.contains(.mov) {
            return .mov
        }
        return exportSession.supportedFileTypes.first
    }

    private static func export(session: AVAssetExportSession) async throws {
        try await withCheckedThrowingContinuation { continuation in
            session.exportAsynchronously {
                switch session.status {
                case .completed:
                    continuation.resume()
                case .failed:
                    continuation.resume(throwing: session.error ?? MediaUploadPreparationError.videoCompressionFailed)
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                default:
                    continuation.resume(throwing: MediaUploadPreparationError.videoCompressionFailed)
                }
            }
        }
    }

    private static func loadTemporaryFileURL(
        from item: PhotosPickerItem,
        contentType: UTType,
        fallbackFileExtension: String
    ) async throws -> URL {
        guard let transferredFile = try await item.loadTransferable(type: ImportedMovieFile.self) else {
            throw MediaUploadPreparationError.missingVideoFile
        }

        let sourceURL = transferredFile.file
        let sourceExtension = sourceURL.pathExtension.isEmpty
            ? fallbackFileExtension.lowercased()
            : sourceURL.pathExtension.lowercased()
        let copiedURL = temporaryFileURL(prefix: "picked-video-", fileExtension: sourceExtension)
        try FileManager.default.copyItem(at: sourceURL, to: copiedURL)
        return copiedURL
    }

    private static func preferredContentType(for item: PhotosPickerItem) -> UTType {
        item.supportedContentTypes.first(where: { $0.conforms(to: UTType.movie) })
            ?? item.supportedContentTypes.first
            ?? .jpeg
    }

    private static func optimizeStillImageIfUseful(
        data: Data,
        contentType: UTType?,
        mimeType: String,
        fileExtension: String
    ) -> PreparedUploadMedia? {
        let normalizedMimeType = mimeType.lowercased()
        let normalizedExtension = fileExtension.lowercased()

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        guard CGImageSourceGetCount(source) <= 1 else {
            return nil
        }

        let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelWidth = (sourceProperties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let pixelHeight = (sourceProperties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let longestEdge = max(pixelWidth, pixelHeight)
        let shouldResize = longestEdge > maxStillImageDimension

        guard shouldAttemptStillImageOptimization(
            contentType: contentType,
            mimeType: normalizedMimeType,
            fileExtension: normalizedExtension,
            byteCount: data.count,
            longestEdge: longestEdge
        ) else {
            return nil
        }

        guard let optimized = optimizedStillImagePayload(
            from: source,
            originalByteCount: data.count,
            longestEdge: longestEdge
        ) else {
            return nil
        }

        guard optimized.data.count > 0 else {
            return nil
        }

        guard optimized.data.count < data.count || shouldResize else {
            return nil
        }

        return optimized
    }

    private static func shouldAttemptStillImageOptimization(
        contentType: UTType?,
        mimeType: String,
        fileExtension: String,
        byteCount: Int,
        longestEdge: Double
    ) -> Bool {
        if let contentType, contentType.conforms(to: .movie) {
            return false
        }

        let normalizedExtension = fileExtension.lowercased()
        if ["gif", "webp", "svg", "pdf"].contains(normalizedExtension) {
            return false
        }

        if mimeType.contains("gif") || mimeType.contains("webp") || mimeType.contains("svg") {
            return false
        }

        guard contentType?.conforms(to: .image) != false || mimeType.hasPrefix("image/") else {
            return false
        }

        return byteCount > maxStillImageUploadBytes ||
            longestEdge > maxStillImageDimension ||
            mimeType.contains("heic")
    }

    private static func optimizedStillImagePayload(
        from source: CGImageSource,
        originalByteCount: Int,
        longestEdge: Double
    ) -> PreparedUploadMedia? {
        let initialCandidateDimension = min(CGFloat(longestEdge), maxStillImageDimension)
        guard initialCandidateDimension > 0 else {
            return nil
        }

        var candidateDimension = initialCandidateDimension
        var smallestCandidate: PreparedUploadMedia?

        while true {
            guard let cgImage = cgImageForStillImageOptimization(
                from: source,
                originalLongestEdge: CGFloat(longestEdge),
                targetMaxDimension: candidateDimension
            ) else {
                return smallestCandidate
            }

            let hasAlphaChannel = cgImage.hasAlphaChannel
            let renderedImage = renderedStillImage(from: cgImage, hasAlphaChannel: hasAlphaChannel)

            if hasAlphaChannel {
                if let pngData = renderedImage.pngData() {
                    let candidate = PreparedUploadMedia(
                        data: pngData,
                        mimeType: "image/png",
                        fileExtension: "png"
                    )
                    smallestCandidate = smallerStillImageCandidate(candidate, than: smallestCandidate)
                    if pngData.count <= maxStillImageUploadBytes {
                        return candidate
                    }
                }
            } else {
                let preferredQualities: [CGFloat]
                if originalByteCount >= 8 * 1_024 * 1_024 || longestEdge > 3_600 {
                    preferredQualities = [0.88, 0.84, 0.80, 0.76, 0.72]
                } else {
                    preferredQualities = stillImageJPEGQualities
                }

                for quality in preferredQualities {
                    guard let jpegData = renderedImage.jpegData(compressionQuality: quality) else {
                        continue
                    }

                    let candidate = PreparedUploadMedia(
                        data: jpegData,
                        mimeType: "image/jpeg",
                        fileExtension: "jpg"
                    )
                    smallestCandidate = smallerStillImageCandidate(candidate, than: smallestCandidate)

                    if jpegData.count <= maxStillImageUploadBytes {
                        return candidate
                    }
                }
            }

            if candidateDimension <= minimumStillImageDimension {
                break
            }

            let nextCandidateDimension = floor(candidateDimension * stillImageDownscaleStep)
            if nextCandidateDimension >= candidateDimension {
                break
            }
            candidateDimension = max(nextCandidateDimension, minimumStillImageDimension)
        }

        return smallestCandidate
    }

    private static func optimizedProfileImagePayload(
        from data: Data,
        contentType: UTType?,
        originalMimeType: String,
        originalFileExtension: String
    ) -> PreparedUploadMedia? {
        let normalizedMimeType = originalMimeType.lowercased()
        let normalizedExtension = originalFileExtension.lowercased()

        if let contentType, contentType.conforms(to: .movie) {
            return nil
        }
        if ["gif", "webp", "svg", "pdf"].contains(normalizedExtension) {
            return nil
        }
        if normalizedMimeType.contains("gif") || normalizedMimeType.contains("webp") || normalizedMimeType.contains("svg") {
            return nil
        }
        guard contentType?.conforms(to: .image) != false || normalizedMimeType.hasPrefix("image/") else {
            return nil
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        guard CGImageSourceGetCount(source) <= 1 else {
            return nil
        }

        let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelWidth = (sourceProperties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let pixelHeight = (sourceProperties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        let longestEdge = max(pixelWidth, pixelHeight)
        let shouldResize = longestEdge > maxProfileImageDimension

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxProfileImageDimension,
            kCGImageSourceShouldCacheImmediately: false
        ]

        let cgImage: CGImage?
        if shouldResize {
            cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
        } else {
            cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }

        guard let cgImage else {
            return nil
        }

        let hasAlphaChannel = cgImage.hasAlphaChannel
        let renderedImage = renderedStillImage(from: cgImage, hasAlphaChannel: hasAlphaChannel)

        if hasAlphaChannel {
            guard let pngData = renderedImage.pngData() else {
                return nil
            }
            return PreparedUploadMedia(
                data: pngData,
                mimeType: "image/png",
                fileExtension: "png",
                previewImage: renderedImage
            )
        }

        guard let jpegData = renderedImage.jpegData(compressionQuality: 0.86) else {
            return nil
        }

        return PreparedUploadMedia(
            data: jpegData,
            mimeType: "image/jpeg",
            fileExtension: "jpg",
            previewImage: renderedImage
        )
    }

    private static func optimizedProfileBannerPayload(
        from data: Data,
        contentType: UTType?,
        originalMimeType: String,
        originalFileExtension: String
    ) -> PreparedUploadMedia? {
        let normalizedMimeType = originalMimeType.lowercased()
        let normalizedExtension = originalFileExtension.lowercased()

        if let contentType, contentType.conforms(to: .movie) {
            return nil
        }
        if ["svg", "pdf"].contains(normalizedExtension) || normalizedMimeType.contains("svg") {
            return nil
        }
        guard contentType?.conforms(to: .image) != false || normalizedMimeType.hasPrefix("image/") else {
            return nil
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let transparentRender = renderedBannerImage(
            from: cgImage,
            targetSize: profileBannerTargetSize,
            opaque: false
        )

        if cgImage.hasAlphaChannel,
           let pngData = transparentRender.pngData(),
           pngData.count <= maxProfileBannerBytes {
            return PreparedUploadMedia(
                data: pngData,
                mimeType: "image/png",
                fileExtension: "png",
                previewImage: transparentRender
            )
        }

        let opaqueRender = renderedBannerImage(
            from: cgImage,
            targetSize: profileBannerTargetSize,
            opaque: true
        )

        let compressionQualities: [CGFloat] = [0.96, 0.94, 0.92, 0.90]
        for quality in compressionQualities {
            guard let jpegData = opaqueRender.jpegData(compressionQuality: quality) else {
                continue
            }

            if jpegData.count <= maxProfileBannerBytes || quality == compressionQualities.last {
                return PreparedUploadMedia(
                    data: jpegData,
                    mimeType: "image/jpeg",
                    fileExtension: "jpg",
                    previewImage: opaqueRender
                )
            }
        }

        return nil
    }

    private static func transcodeAnimatedGIFToVideo(
        source: CGImageSource,
        outputURL: URL,
        originalWidth: Double,
        originalHeight: Double,
        frameCount: Int,
        maxDimension: CGFloat,
        bitRate: Int
    ) async throws {
        let outputSize = animatedGIFVideoOutputSize(
            originalWidth: originalWidth,
            originalHeight: originalHeight,
            maxDimension: maxDimension
        )

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputSize.width,
            AVVideoHeightKey: outputSize.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: 15,
                AVVideoMaxKeyFrameIntervalKey: 15,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false

        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
            kCVPixelBufferWidthKey as String: outputSize.width,
            kCVPixelBufferHeightKey as String: outputSize.height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )

        guard writer.canAdd(input) else {
            throw MediaUploadPreparationError.videoCompressionFailed
        }

        writer.add(input)

        guard writer.startWriting() else {
            throw writer.error ?? MediaUploadPreparationError.videoCompressionFailed
        }

        writer.startSession(atSourceTime: .zero)

        let renderSize = CGSize(width: outputSize.width, height: outputSize.height)
        let timescale: Int32 = 600
        var presentationTime = CMTime.zero

        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }

            guard let frameImage = CGImageSourceCreateImageAtIndex(source, index, nil),
                  let pixelBufferPool = adaptor.pixelBufferPool,
                  let pixelBuffer = makePixelBuffer(
                    from: frameImage,
                    size: renderSize,
                    pixelBufferPool: pixelBufferPool
                  ) else {
                continue
            }

            guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw writer.error ?? MediaUploadPreparationError.videoCompressionFailed
            }

            let frameDuration = max(gifFrameDuration(forFrameAt: index, source: source), 1.0 / 15.0)
            presentationTime = presentationTime + CMTime(
                seconds: frameDuration,
                preferredTimescale: timescale
            )
        }

        input.markAsFinished()

        try await withCheckedThrowingContinuation { continuation in
            writer.finishWriting {
                switch writer.status {
                case .completed:
                    continuation.resume()
                case .failed:
                    continuation.resume(throwing: writer.error ?? MediaUploadPreparationError.videoCompressionFailed)
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                default:
                    continuation.resume(throwing: MediaUploadPreparationError.videoCompressionFailed)
                }
            }
        }
    }

    private static func animatedGIFVideoOutputSize(
        originalWidth: Double,
        originalHeight: Double,
        maxDimension: CGFloat
    ) -> CGSize {
        let safeWidth = max(originalWidth, 1)
        let safeHeight = max(originalHeight, 1)
        let scale = min(1, Double(maxDimension) / max(safeWidth, safeHeight))
        let scaledWidth = evenPixelDimension(Int((safeWidth * scale).rounded()))
        let scaledHeight = evenPixelDimension(Int((safeHeight * scale).rounded()))
        return CGSize(width: scaledWidth, height: scaledHeight)
    }

    private static func evenPixelDimension(_ value: Int) -> Int {
        let clamped = max(value, 2)
        return clamped.isMultiple(of: 2) ? clamped : clamped + 1
    }

    private static func makePixelBuffer(
        from cgImage: CGImage,
        size: CGSize,
        pixelBufferPool: CVPixelBufferPool
    ) -> CVPixelBuffer? {
        var pixelBufferOut: CVPixelBuffer?
        let createStatus = CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &pixelBufferOut)
        guard createStatus == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: baseAddress,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else {
            return nil
        }

        context.clear(CGRect(origin: .zero, size: size))
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(origin: .zero, size: size))
        return pixelBuffer
    }

    private static func animatedGIFPreviewImage(
        from source: CGImageSource,
        targetMaxDimension: CGFloat
    ) -> UIImage? {
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: targetMaxDimension,
            kCGImageSourceShouldCacheImmediately: false
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let image = UIImage(cgImage: cgImage)
        return image.preparingForDisplay() ?? image
    }

    private static func gifFrameDuration(
        forFrameAt index: Int,
        source: CGImageSource
    ) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gifProperties = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
            return 0.1
        }

        let unclampedDelay = (gifProperties[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
        let delay = (gifProperties[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
        let duration = unclampedDelay ?? delay ?? 0.1

        if duration < 0.011 {
            return 0.1
        }

        return max(duration, 0.02)
    }

    private static func renderedStillImage(
        from cgImage: CGImage,
        hasAlphaChannel: Bool
    ) -> UIImage {
        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = !hasAlphaChannel
        let renderer = UIGraphicsImageRenderer(size: imageSize, format: format)

        return renderer.image { _ in
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: imageSize))
        }
    }

    private static func cgImageForStillImageOptimization(
        from source: CGImageSource,
        originalLongestEdge: CGFloat,
        targetMaxDimension: CGFloat
    ) -> CGImage? {
        let effectiveDimension = max(1, min(originalLongestEdge, targetMaxDimension))
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: effectiveDimension,
            kCGImageSourceShouldCacheImmediately: false
        ]

        if effectiveDimension < originalLongestEdge {
            return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
        }

        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func smallerStillImageCandidate(
        _ candidate: PreparedUploadMedia,
        than current: PreparedUploadMedia?
    ) -> PreparedUploadMedia {
        guard let current else {
            return candidate
        }

        if candidate.data.count < current.data.count {
            return candidate
        }

        return current
    }

    private static func renderedBannerImage(
        from cgImage: CGImage,
        targetSize: CGSize,
        opaque: Bool
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = opaque

        let sourceSize = CGSize(width: cgImage.width, height: cgImage.height)
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)

        return renderer.image { context in
            if opaque {
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: targetSize))
            }

            let scale = max(
                targetSize.width / max(sourceSize.width, 1),
                targetSize.height / max(sourceSize.height, 1)
            )
            let drawSize = CGSize(
                width: sourceSize.width * scale,
                height: sourceSize.height * scale
            )
            let drawOrigin = CGPoint(
                x: (targetSize.width - drawSize.width) / 2,
                y: (targetSize.height - drawSize.height) / 2
            )

            UIImage(cgImage: cgImage).draw(in: CGRect(origin: drawOrigin, size: drawSize))
        }
    }

    private static func fallbackMimeType(for contentType: UTType) -> String {
        if contentType.conforms(to: UTType.movie) {
            return "video/quicktime"
        }
        if contentType.conforms(to: UTType.image) {
            return "image/jpeg"
        }
        return "application/octet-stream"
    }

    private static func fileExtension(for fileType: AVFileType) -> String? {
        switch fileType {
        case .mp4:
            return "mp4"
        case .mov:
            return "mov"
        case .m4v:
            return "m4v"
        default:
            return nil
        }
    }

    private static func temporaryFileURL(prefix: String, fileExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
    }

    private static func measuredFileSize(at url: URL) -> Int {
        if let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           fileSize > 0 {
            return fileSize
        }

        if let fileAttributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let fileSize = fileAttributes[.size] as? NSNumber {
            return fileSize.intValue
        }

        if let data = try? Data(contentsOf: url) {
            return data.count
        }

        return 0
    }

    private static func defaultFileExtension(for mimeType: String) -> String {
        let normalized = mimeType.lowercased()
        if normalized.contains("jpeg") || normalized.contains("jpg") {
            return "jpg"
        }
        if normalized.contains("png") {
            return "png"
        }
        if normalized.contains("heic") {
            return "heic"
        }
        if normalized.contains("gif") {
            return "gif"
        }
        if normalized.contains("webp") {
            return "webp"
        }
        if normalized.contains("quicktime") || normalized.contains("mov") {
            return "mov"
        }
        if normalized.contains("mp4") {
            return "mp4"
        }
        if normalized.contains("mpeg") || normalized.contains("mp3") {
            return "mp3"
        }
        if normalized.contains("m4a") {
            return "m4a"
        }
        return "bin"
    }
}

private extension CGImage {
    var hasAlphaChannel: Bool {
        switch alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast:
            return true
        default:
            return false
        }
    }
}

private struct ImportedMovieFile: Transferable {
    let file: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: UTType.movie) { received in
            ImportedMovieFile(file: received.file)
        }
    }
}
