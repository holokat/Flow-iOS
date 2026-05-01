import AVKit
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Flow

final class MediaUploadPreparationTests: XCTestCase {
    private let maxStillImageUploadBytes = 1_500 * 1_024
    private let maxStillImageDimension = 3_000.0
    private let legacyProfileBannerUploadBytes = 500 * 1_024
    private let maxProfileBannerUploadBytes = 2_500 * 1_024

    func testPrepareUploadMediaOptimizesOversizedJPEGWithinUploadLimits() throws {
        let originalImage = makeLargeTestImage(size: CGSize(width: 4_000, height: 3_000))
        let originalData = try XCTUnwrap(originalImage.jpegData(compressionQuality: 0.92))

        XCTAssertLessThan(originalData.count, 2 * 1_024 * 1_024)

        let prepared = try MediaUploadPreparation.prepareUploadMedia(
            data: originalData,
            mimeType: "image/jpeg",
            fileExtension: "jpg"
        )

        XCTAssertEqual(prepared.mimeType, "image/jpeg")
        XCTAssertEqual(prepared.fileExtension, "jpg")
        XCTAssertLessThan(prepared.data.count, originalData.count)
        XCTAssertLessThanOrEqual(prepared.data.count, maxStillImageUploadBytes)

        let preparedDimensions = try XCTUnwrap(imageDimensions(for: prepared.data))
        XCTAssertLessThanOrEqual(preparedDimensions.width, maxStillImageDimension)
        XCTAssertLessThanOrEqual(preparedDimensions.height, maxStillImageDimension)
    }

    func testPrepareProfileBannerUploadKeepsHighQualityBannerUnderRelaxedLimit() throws {
        let originalImage = makeDetailedBannerImage(size: CGSize(width: 1_200, height: 1_600))
        let originalData = try XCTUnwrap(originalImage.jpegData(compressionQuality: 0.98))

        let prepared = try MediaUploadPreparation.prepareProfileBannerUpload(
            data: originalData,
            mimeType: "image/jpeg",
            fileExtension: "jpg"
        )

        XCTAssertEqual(prepared.mimeType, "image/jpeg")
        XCTAssertEqual(prepared.fileExtension, "jpg")
        XCTAssertGreaterThan(prepared.data.count, legacyProfileBannerUploadBytes)
        XCTAssertGreaterThan(Double(prepared.data.count), Double(originalData.count) * 0.65)
        XCTAssertLessThanOrEqual(prepared.data.count, maxProfileBannerUploadBytes)

        let preparedDimensions = try XCTUnwrap(imageDimensions(for: prepared.data))
        XCTAssertEqual(preparedDimensions.width, 1_200)
        XCTAssertEqual(preparedDimensions.height, 1_600)
    }

    func testPrepareGIFKeyboardUploadMediaConvertsAnimatedGIFToSmallerMP4() async throws {
        let originalData = try XCTUnwrap(makeAnimatedGIFData(
            frameCount: 20,
            size: CGSize(width: 360, height: 240)
        ))

        let prepared = try await MediaUploadPreparation.prepareGIFKeyboardUploadMedia(
            data: originalData,
            mimeType: "image/gif",
            fileExtension: "gif"
        )

        XCTAssertEqual(prepared.mimeType, "video/mp4")
        XCTAssertEqual(prepared.fileExtension, "mp4")
        XCTAssertLessThan(prepared.data.count, originalData.count)
    }

    func testConvertedGIFKeyboardMP4QualifiesForShortLoopingPlayback() async throws {
        let originalData = try XCTUnwrap(makeAnimatedGIFData(
            frameCount: 20,
            size: CGSize(width: 360, height: 240)
        ))

        let prepared = try await MediaUploadPreparation.prepareGIFKeyboardUploadMedia(
            data: originalData,
            mimeType: "image/gif",
            fileExtension: "gif"
        )
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("short-loop-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        try prepared.data.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let shouldLoop = await NoteShortMP4LoopPolicy.shared.shouldLoop(url: fileURL)

        XCTAssertTrue(shouldLoop)
    }

    func testShortMP4LoopPolicyOnlyChecksMP4URLs() throws {
        let mp4URL = try XCTUnwrap(URL(string: "https://example.com/media/clip.MP4?download=1"))
        let movURL = try XCTUnwrap(URL(string: "https://example.com/media/clip.mov"))

        XCTAssertTrue(NoteShortMP4LoopPolicy.isCandidateURL(mp4URL))
        XCTAssertFalse(NoteShortMP4LoopPolicy.isCandidateURL(movURL))
    }

    func testShortMP4LoopPolicyCapsGIFLikePlaybackAtFourSeconds() {
        XCTAssertEqual(NoteShortMP4LoopPolicy.maximumLoopingDurationSeconds, 4, accuracy: 0.0001)
    }

    func testNativeVideoPlaybackUsesStallResistantBufferingPolicy() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/media/video.mp4"))
        let coordinator = NoteNativeVideoPlayerController.Coordinator()
        let controller = AVPlayerViewController()

        coordinator.configure(
            url: url,
            autoplay: false,
            isMuted: false,
            loops: false,
            controller: controller,
            onPlaybackStateChange: nil
        )

        XCTAssertTrue(coordinator.player.automaticallyWaitsToMinimizeStalling)
        XCTAssertGreaterThanOrEqual(
            coordinator.player.currentItem?.preferredForwardBufferDuration ?? 0,
            12
        )
    }

    func testPrepareGIFKeyboardUploadMediaKeepsStaticGIFAsGIF() async throws {
        let staticGIFData = Data(
            base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=="
        )

        let originalData = try XCTUnwrap(staticGIFData)
        let prepared = try await MediaUploadPreparation.prepareGIFKeyboardUploadMedia(
            data: originalData,
            mimeType: "image/gif",
            fileExtension: "gif"
        )

        XCTAssertEqual(prepared.mimeType, "image/gif")
        XCTAssertEqual(prepared.fileExtension, "gif")
        XCTAssertEqual(prepared.data, originalData)
    }

    private func makeLargeTestImage(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            UIColor(red: 0.96, green: 0.94, blue: 0.88, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))

            let stripeColors: [UIColor] = [
                UIColor(red: 0.89, green: 0.35, blue: 0.22, alpha: 1),
                UIColor(red: 0.17, green: 0.45, blue: 0.74, alpha: 1),
                UIColor(red: 0.19, green: 0.61, blue: 0.39, alpha: 1),
                UIColor(red: 0.92, green: 0.72, blue: 0.18, alpha: 1)
            ]

            let stripeWidth = max(size.width / 12, 1)
            for (index, originX) in stride(from: CGFloat.zero, to: size.width, by: stripeWidth).enumerated() {
                stripeColors[index % stripeColors.count].setFill()
                context.fill(CGRect(x: originX, y: 0, width: stripeWidth * 0.55, height: size.height))
            }

            let insetRect = CGRect(
                x: size.width * 0.12,
                y: size.height * 0.18,
                width: size.width * 0.76,
                height: size.height * 0.64
            )
            UIColor.white.withAlphaComponent(0.25).setFill()
            context.cgContext.fillEllipse(in: insetRect)
        }
    }

    private func makeDetailedBannerImage(size: CGSize) -> UIImage {
        let width = Int(size.width)
        let height = Int(size.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let texture = (x * 31 + y * 17 + (x * y) % 251) & 0xFF
                pixels[offset] = UInt8(texture)
                pixels[offset + 1] = UInt8((texture + x / 3 + y / 7) & 0xFF)
                pixels[offset + 2] = UInt8((texture + x / 5 + y / 2) & 0xFF)
                pixels[offset + 3] = 255
            }
        }

        let data = Data(pixels)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let provider = CGDataProvider(data: data as CFData)
        let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider!,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )!
        return UIImage(cgImage: cgImage)
    }

    private func makeAnimatedGIFData(frameCount: Int, size: CGSize) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ) else {
            return nil
        }

        CGImageDestinationSetProperties(
            destination,
            [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFLoopCount: 0
                ]
            ] as CFDictionary
        )

        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: 0.08
            ]
        ] as CFDictionary

        for frameIndex in 0..<frameCount {
            let image = makeAnimatedGIFFrame(
                size: size,
                frameIndex: frameIndex,
                frameCount: frameCount
            )
            guard let cgImage = image.cgImage else { return nil }
            CGImageDestinationAddImage(destination, cgImage, frameProperties)
        }

        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private func makeAnimatedGIFFrame(
        size: CGSize,
        frameIndex: Int,
        frameCount: Int
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            let cgContext = context.cgContext
            let progress = CGFloat(frameIndex) / CGFloat(max(frameCount - 1, 1))
            let colors = [
                UIColor(
                    hue: progress,
                    saturation: 0.76,
                    brightness: 0.94,
                    alpha: 1
                ).cgColor,
                UIColor(
                    hue: (progress + 0.33).truncatingRemainder(dividingBy: 1),
                    saturation: 0.82,
                    brightness: 0.72,
                    alpha: 1
                ).cgColor,
                UIColor(
                    hue: (progress + 0.67).truncatingRemainder(dividingBy: 1),
                    saturation: 0.68,
                    brightness: 0.88,
                    alpha: 1
                ).cgColor
            ] as CFArray

            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let gradient = CGGradient(
                colorsSpace: colorSpace,
                colors: colors,
                locations: [0, 0.52, 1]
            ) else {
                return
            }
            cgContext.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: size.width, y: size.height),
                options: []
            )

            for stripeIndex in 0..<18 {
                let stripeProgress = CGFloat(stripeIndex) / 18
                let x = (stripeProgress * size.width + progress * 120)
                    .truncatingRemainder(dividingBy: size.width + 80) - 40
                UIColor(
                    hue: (progress + stripeProgress * 0.28).truncatingRemainder(dividingBy: 1),
                    saturation: 0.52,
                    brightness: 1,
                    alpha: 0.46
                ).setFill()
                cgContext.fill(CGRect(
                    x: x,
                    y: 0,
                    width: 24,
                    height: size.height
                ))
            }

            UIColor.white.withAlphaComponent(0.22).setFill()
            cgContext.fillEllipse(in: CGRect(
                x: size.width * (0.16 + progress * 0.48),
                y: size.height * 0.28,
                width: size.width * 0.24,
                height: size.height * 0.36
            ))
        }
    }

    private func imageDimensions(for data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else {
            return nil
        }

        return CGSize(width: width, height: height)
    }
}
