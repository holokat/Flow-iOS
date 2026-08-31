import CoreImage
import Foundation
import UIKit
import Vision

struct HaloSubjectSelection {
    let maskPreview: UIImage
    let cutout: UIImage
    let blurredBackground: UIImage
}

enum HaloSubjectSegmentationError: LocalizedError {
    case unavailable
    case invalidImage
    case subjectNotFound
    case renderingFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Subject selection requires iOS 27."
        case .invalidImage:
            return "Halo couldn't read that image."
        case .subjectNotFound:
            return "No clear subject was found at that point."
        case .renderingFailed:
            return "Halo couldn't prepare the subject selection."
        }
    }
}

enum HaloSubjectSegmentation {
    static func visionSeedPoint(fromCanvasPoint point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), 1),
            y: 1 - min(max(point.y, 0), 1)
        )
    }

    static func selectSubject(in image: UIImage, at canvasPoint: CGPoint) async throws -> HaloSubjectSelection {
        guard #available(iOS 27.0, *) else {
            throw HaloSubjectSegmentationError.unavailable
        }
        #if compiler(>=6.4)
        return try await selectSubject27(in: image, at: canvasPoint)
        #else
        throw HaloSubjectSegmentationError.unavailable
        #endif
    }

    #if compiler(>=6.4)
    @available(iOS 27.0, *)
    private static func selectSubject27(in image: UIImage, at canvasPoint: CGPoint) async throws -> HaloSubjectSelection {
        let normalizedImage = image.flowNormalizedUp()
        guard let sourceCGImage = normalizedImage.cgImage else {
            throw HaloSubjectSegmentationError.invalidImage
        }

        let seed = visionSeedPoint(fromCanvasPoint: canvasPoint)
        let request = GenerateIterativeSegmentationRequest(
            seedPoint: NormalizedPoint(x: seed.x, y: seed.y)
        )
        request.qualityLevel = .accurate

        if await request.assetStatus != .ready {
            try await request.downloadAssets()
        }

        guard let observation = try await request.perform(on: sourceCGImage),
              observation.confidence > 0 else {
            throw HaloSubjectSegmentationError.subjectNotFound
        }

        let maskCGImage = try observation.cgImage
        return try renderSelection(
            sourceCGImage: sourceCGImage,
            maskCGImage: maskCGImage,
            scale: normalizedImage.scale
        )
    }
    #endif

    private static func renderSelection(
        sourceCGImage: CGImage,
        maskCGImage: CGImage,
        scale: CGFloat
    ) throws -> HaloSubjectSelection {
        let context = CIContext(options: [.cacheIntermediates: false])
        let source = CIImage(cgImage: sourceCGImage)
        let sourceExtent = source.extent
        let rawMask = CIImage(cgImage: maskCGImage)
        let scaledMask = rawMask
            .transformed(
                by: CGAffineTransform(
                    scaleX: sourceExtent.width / max(rawMask.extent.width, 1),
                    y: sourceExtent.height / max(rawMask.extent.height, 1)
                )
            )
            .cropped(to: sourceExtent)

        let clearBackground = CIImage(color: .clear).cropped(to: sourceExtent)
        let cutout = source.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: clearBackground,
                kCIInputMaskImageKey: scaledMask
            ]
        )

        let blurred = source
            .clampedToExtent()
            .applyingGaussianBlur(sigma: max(sourceExtent.width, sourceExtent.height) * 0.018)
            .cropped(to: sourceExtent)
        let blurredBackground = source.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputBackgroundImageKey: blurred,
                kCIInputMaskImageKey: scaledMask
            ]
        )
        let maskPreview = scaledMask.applyingFilter("CIMaskToAlpha")

        guard let cutoutImage = render(cutout, context: context, scale: scale),
              let blurredBackgroundImage = render(blurredBackground, context: context, scale: scale),
              let maskPreviewImage = render(maskPreview, context: context, scale: scale) else {
            throw HaloSubjectSegmentationError.renderingFailed
        }

        return HaloSubjectSelection(
            maskPreview: maskPreviewImage,
            cutout: cutoutImage,
            blurredBackground: blurredBackgroundImage
        )
    }

    private static func render(_ image: CIImage, context: CIContext, scale: CGFloat) -> UIImage? {
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    }
}
