import CoreImage
import CoreImage.CIFilterBuiltins
import Photos
import SwiftUI
import UIKit

struct ImageRemixUploadEncoding {
    let data: Data
    let mimeType: String
    let fileExtension: String

    init?(image: UIImage) {
        if image.flowHasAlphaChannel, let data = image.pngData() {
            self.data = data
            self.mimeType = "image/png"
            self.fileExtension = "png"
        } else if let data = image.jpegData(compressionQuality: 0.94) {
            self.data = data
            self.mimeType = "image/jpeg"
            self.fileExtension = "jpg"
        } else {
            return nil
        }
    }
}

private extension UIImage {
    var flowHasAlphaChannel: Bool {
        guard let alphaInfo = cgImage?.alphaInfo else { return false }
        switch alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast:
            return true
        case .none, .noneSkipFirst, .noneSkipLast, .alphaOnly:
            return alphaInfo == .alphaOnly
        @unknown default:
            return false
        }
    }
}

enum ImageRemixFilterProcessor {
    private static let context = CIContext(options: nil)

    static func renderedImage(for preset: ImageRemixFilterPreset, from image: UIImage) -> UIImage {
        let baseImage = image.flowNormalizedUp()
        guard let ciImage = CIImage(image: baseImage) else {
            return baseImage
        }

        switch preset {
        case .original:
            return baseImage

        case .duotoneGradient:
            return duotoneGradientImage(from: ciImage, baseImage: baseImage)
        case .tritoneEditorial:
            return tritoneEditorialImage(from: ciImage, baseImage: baseImage)
        case .metallicChrome:
            return metallicChromeImage(from: ciImage, baseImage: baseImage)
        case .liquidMetalFlow:
            return liquidMetalFlowImage(from: ciImage, baseImage: baseImage)
        case .hologram:
            return hologramImage(from: ciImage, baseImage: baseImage)
        case .prismDispersion:
            return prismDispersionImage(from: ciImage, baseImage: baseImage)
        case .softBloomGlow:
            return softBloomGlowImage(from: ciImage, baseImage: baseImage)
        case .neonGlow:
            return neonGlowImage(from: ciImage, baseImage: baseImage)
        case .glassFrostedBlur:
            return glassFrostedBlurImage(from: ciImage, baseImage: baseImage)
        case .lightSweep:
            return lightSweepImage(from: ciImage, baseImage: baseImage)
        case .filmGrainCinematic:
            return filmGrainCinematicImage(from: ciImage, baseImage: baseImage)
        case .vintageFilmFade:
            return vintageFilmFadeImage(from: ciImage, baseImage: baseImage)
        case .vhs90sTape:
            return vhs90sTapeImage(from: ciImage, baseImage: baseImage)
        case .crtScanline:
            return crtScanlineImage(from: ciImage, baseImage: baseImage)
        case .halftonePrint:
            return halftonePrintImage(from: ciImage, baseImage: baseImage)
        case .posterizeQuantize:
            return posterizeQuantizeImage(from: ciImage, baseImage: baseImage)
        case .glitchClean:
            return glitchCleanImage(from: ciImage, baseImage: baseImage)
        case .chromaticAberration:
            return chromaticAberrationImage(from: ciImage, baseImage: baseImage)
        case .thermalHeatmap:
            return thermalHeatmapImage(from: ciImage, baseImage: baseImage)
        case .pixelSortDataMelt:
            return pixelSortDataMeltImage(from: ciImage, baseImage: baseImage)
        }
    }

    private static func duotoneGradientImage(from ciImage: CIImage, baseImage: UIImage) -> UIImage {
        let toned = ciImage
            .applyingPhotoEffect(.mono)
            .applyingColorControls(saturation: 0, brightness: 0.03, contrast: 1.18)
        let mapped = colorMapped(toned, colors: [
            UIColor(red: 0.05, green: 0.08, blue: 0.18, alpha: 1),
            UIColor(red: 0.98, green: 0.76, blue: 0.32, alpha: 1)
        ]) ?? toned
        let duotoneBase = renderedUIImage(from: mapped) ?? baseImage
        return overlay(on: duotoneBase) { context, size in
            drawLinearGradient(
                in: context,
                colors: [
                    UIColor.clear,
                    UIColor(red: 0.18, green: 0.70, blue: 1.0, alpha: 0.12),
                    UIColor(red: 1.0, green: 0.60, blue: 0.24, alpha: 0.18),
                    UIColor.clear
                ],
                locations: [0, 0.26, 0.74, 1],
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: size.width, y: size.height),
                blendMode: .softLight
            )
        }
    }

    private static func tritoneEditorialImage(from ciImage: CIImage, baseImage: UIImage) -> UIImage {
        let toned = ciImage
            .applyingPhotoEffect(.tonal)
            .applyingColorControls(saturation: 0.18, brightness: 0.02, contrast: 1.22)
        let mapped = colorMapped(toned, colors: [
            UIColor(red: 0.06, green: 0.10, blue: 0.18, alpha: 1),
            UIColor(red: 0.56, green: 0.48, blue: 0.38, alpha: 1),
            UIColor(red: 0.95, green: 0.91, blue: 0.84, alpha: 1)
        ]) ?? toned
        let editorialBase = renderedUIImage(from: mapped) ?? baseImage
        return overlay(on: editorialBase) { context, size in
            drawLinearGradient(
                in: context,
                colors: [
                    UIColor(red: 0.98, green: 0.82, blue: 0.64, alpha: 0.10),
                    UIColor.clear
                ],
                locations: [0, 1],
                start: CGPoint(x: size.width * 0.1, y: 0),
                end: CGPoint(x: size.width * 0.85, y: size.height),
                blendMode: .screen
            )
            drawFilmGrain(in: context, size: size, alpha: 0.025, spacing: 4.8)
        }
    }

    private static func metallicChromeImage(from ciImage: CIImage, baseImage: UIImage) -> UIImage {
        let monochrome = ciImage
            .applyingPhotoEffect(.mono)
            .applyingGammaAdjust(power: 0.78)
            .applyingColorControls(saturation: 0, brightness: 0.05, contrast: 1.42)
        let mapped = colorMapped(monochrome, colors: [
            UIColor(red: 0.02, green: 0.03, blue: 0.05, alpha: 1),
            UIColor(red: 0.32, green: 0.35, blue: 0.40, alpha: 1),
            UIColor(red: 0.76, green: 0.79, blue: 0.83, alpha: 1),
            UIColor.white
        ]) ?? monochrome
        let chromeBase = renderedUIImage(from: mapped) ?? baseImage
        return overlay(on: chromeBase) { context, size in
            drawLinearGradient(
                in: context,
                colors: [
                    UIColor.clear,
                    UIColor.white.withAlphaComponent(0.42),
                    UIColor.clear
                ],
                locations: [0.18, 0.52, 0.86],
                start: CGPoint(x: size.width * 0.08, y: size.height),
                end: CGPoint(x: size.width * 0.78, y: 0),
                blendMode: .screen
            )
            drawLinearGradient(
                in: context,
                colors: [
                    UIColor(red: 0.36, green: 0.46, blue: 0.62, alpha: 0.18),
                    UIColor.clear
                ],
                locations: [0, 1],
                start: CGPoint(x: 0, y: size.height * 0.9),
                end: CGPoint(x: size.width, y: size.height * 0.15),
                blendMode: .softLight
            )
        }
    }

    private static func liquidMetalFlowImage(from ciImage: CIImage, baseImage: UIImage) -> UIImage {
        let chromeBase = metallicChromeImage(from: ciImage, baseImage: baseImage)
        return overlay(on: chromeBase) { context, size in
            drawHorizontalDisplacement(
                from: chromeBase,
                in: context,
                size: size,
                stripHeight: max(size.height / 54, 10),
                maxShift: max(size.width * 0.014, 4.5),
                alpha: 0.95,
                blendMode: .normal,
                phase: 0.8,
                frequency: 0.58,
                yRange: 0.0...1.0
            )
            drawLinearGradient(
                in: context,
                colors: [
                    UIColor.clear,
                    UIColor.white.withAlphaComponent(0.22),
                    UIColor.clear
                ],
                locations: [0.08, 0.42, 0.82],
                start: CGPoint(x: size.width * 0.2, y: size.height),
                end: CGPoint(x: size.width * 0.95, y: 0),
                blendMode: .screen
            )
        }
    }

    private static func hologramImage(from ciImage: CIImage, baseImage: UIImage) -> UIImage {
        let vivid = ciImage
            .applyingColorControls(saturation: 1.28, brightness: 0.03, contrast: 1.16)
            .applyingHueAdjust(angle: 0.32)
        let hologramBase = renderedUIImage(from: vivid) ?? baseImage
        return overlay(on: hologramBase) { context, size in
            drawLinearGradient(
                in: context,
                colors: [
                    UIColor(red: 0.18, green: 0.96, blue: 1.0, alpha: 0.52),
                    UIColor(red: 0.86, green: 0.48, blue: 1.0, alpha: 0.38),
                    UIColor.white.withAlphaComponent(0.14)
                ],
                locations: [0, 0.55, 1],
                start: .zero,
                end: CGPoint(x: size.width, y: size.height),
                blendMode: .screen
            )
            drawScanlines(in: context, size: size, alpha: 0.09, spacing: 6)
        }
    }

    private static func prismDispersionImage(from ciImage: CIImage, baseImage: UIImage) -> UIImage {
        let crisp = ciImage
            .applyingColorControls(saturation: 1.06, brightness: 0.02, contrast: 1.18)
            .applyingBloom(radius: 5.5, intensity: 0.12)
        let prismBase = renderedUIImage(from: crisp) ?? baseImage
        return overlay(on: prismBase) { context, size in
            tinted(prismBase, color: UIColor(red: 1.0, green: 0.24, blue: 0.20, alpha: 0.18))
                .draw(at: CGPoint(x: -5, y: 0), blendMode: .screen, alpha: 1)
            tinted(prismBase, color: UIColor(red: 0.18, green: 0.84, blue: 1.0, alpha: 0.18))
                .draw(at: CGPoint(x: 5, y: 0), blendMode: .screen, alpha: 1)
            tinted(prismBase, color: UIColor(red: 1.0, green: 0.92, blue: 0.25, alpha: 0.12))
                .draw(at: CGPoint(x: 0, y: -2), blendMode: .screen, alpha: 1)
            drawLinearGradient(
                in: context,
                colors: [
                    UIColor.clear,
                    UIColor.white.withAlphaComponent(0.12),
                    UIColor.clear
                ],
                locations: [0.12, 0.54, 0.9],
                start: CGPoint(x: size.width * 0.05, y: size.height),
                end: CGPoint(x: size.width * 0.88, y: 0),
                blendMode: .screen
            )
        }
    }

    private static func softBloomGlowImage(from ciImage: CIImage, baseImage: UIImage) -> UIImage {
        let glow = ciImage
            .applyingColorControls(saturation: 1.02, brightness: 0.03, contrast: 1.08)
            .applyingBloom(radius: 20, intensity: 0.72)
        let bloomedBase = renderedUIImage(from: glow) ?? baseImage
        return overlay(on: bloomedBase) { context, size in
            drawRadialGlow(
                in: context,
                size: size,
                center: CGPoint(x: size.width * 0.52, y: size.height * 0.44),
                colors: [
                    UIColor.white.withAlphaComponent(0.12),
                    UIColor(red: 1.0, green: 0.82, blue: 0.70, alpha: 0.08),
                    UIColor.clear
                ],
                radius: max(size.width, size.height) * 0.72,
                blendMode: .screen
            )
        }
    }

    private static func neonGlowImage(from ciImage: CIImage, baseImage: UIImage) -> UIImage {
        let punchy = ciImage
            .applyingColorControls(saturation: 1.34, brightness: 0.03, contrast: 1.2)
            .applyingBloom(radius: 18, intensity: 0.86)
        let neonBase = renderedUIImage(from: punchy) ?? baseImage
        return overlay(on: neonBase) { context, size in
            tinted(neonBase, color: UIColor(red: 0.12, green: 0.98, blue: 1.0, alpha: 0.16))
                .draw(at: CGPoint(x: -4, y: 0), blendMode: .screen, alpha: 1)
            tinted(neonBase, color: UIColor(red: 1.0, green: 0.24, blue: 0.74, alpha: 0.16))
                .draw(at: CGPoint(x: 4, y: 0), blendMode: .screen, alpha: 1)
            drawRadialGlow(
                in: context,
                size: size,
                center: CGPoint(x: size.width * 0.5, y: size.height * 0.5),
                colors: [
                    UIColor(red: 0.14, green: 0.92, blue: 1.0, alpha: 0.08),
                    UIColor.clear
                ],
                radius: max(size.width, size.height) * 0.85,
                blendMode: .screen
            )
        }
    }

    private static func glassFrostedBlurImage(from ciImage: CIImage, baseImage: UIImage) -> UIImage {
        let frosted = ciImage
            .applyingGaussianBlur(radius: 10)
            .applyingColorControls(saturation: 0.88, brightness: 0.06, contrast: 0.94)
        let glassBase = renderedUIImage(from: frosted) ?? baseImage
        return overlay(on: glassBase) { context, size in
            baseImage.draw(in: CGRect(origin: .zero, size: size), blendMode: .softLight, alpha: 0.16)
            drawLinearGradient(
                in: context,
                colors: [
                    UIColor.white.withAlphaComponent(0.18),
                    UIColor(red: 0.72, green: 0.88, blue: 1.0, alpha: 0.08),
                    UIColor.clear
                ],
                locations: [0, 0.38, 1],
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: size.width, y: size.height),
                blendMode: .screen
            )
        }
    }

    private static func lightSweepImage(from ciImage: CIImage, baseImage: UIImage) -> UIImage {
        let polished = ciImage
            .applyingColorControls(saturation: 1.02, brightness: 0.01, contrast: 1.12)
        let sweepBase = renderedUIImage(from: polished) ?? baseImage
        return overlay(on: sweepBase) { context, size in
            drawLinearGradient(
                in: context,
                colors: [
                    UIColor.clear,
                    UIColor.white.withAlphaComponent(0.46),
                    UIColor.clear
                ],
                locations: [0.18, 0.48, 0.78],
                start: CGPoint(x: size.width * 0.15, y: size.height),
                end: CGPoint(x: size.width * 0.82, y: 0),
                blendMode: .screen
            )
            drawLinearGradient(
                in: context,
                colors: [
                    UIColor.clear,
                    UIColor(red: 1.0, green: 0.84, blue: 0.44, alpha: 0.14),
                    UIColor.clear
                ],
                locations: [0.1, 0.46, 0.84],
                start: CGPoint(x: size.width * 0.2, y: size.height),
                end: CGPoint(x: size.width * 0.88, y: 0),
                blendMode: .softLight
            )
        }
    }

    private static func filmGrainCinematicImage(from ciImage: CIImage, baseImage: UIImage) -> UIImage {
        let graded = ciImage
            .applyingColorControls(saturation: 0.94, brightness: -0.01, contrast: 1.14)
            .applyingExposureAdjust(ev: -0.02)
        let grainBase = renderedUIImage(from: graded) ?? baseImage
        return overlay(on: grainBase) { context, size in
            drawFilmGrain(in: context, size: size, alpha: 0.06, spacing: 4.2)
            drawRadialGlow(
                in: context,
                size: size,
                center: CGPoint(x: size.width * 0.5, y: size.height * 0.5),
                colors: [
                    UIColor.clear,
                    UIColor.clear,
                    UIColor.black.withAlphaComponent(0.22)
                ],
                radius: max(size.width, size.height) * 0.82,
                blendMode: .multiply
            )
        }
    }

    private static func vintageFilmFadeImage(from ciImage: CIImage, baseImage: UIImage) -> UIImage {
        let faded = ciImage
            .applyingColorControls(saturation: 0.72, brightness: 0.06, contrast: 0.88)
            .applyingSepia(intensity: 0.14)
        let vintageBase = renderedUIImage(from: faded) ?? baseImage
        return overlay(on: vintageBase) { context, size in
            drawLinearGradient(
                in: context,
                colors: [
                    UIColor(red: 1.0, green: 0.92, blue: 0.78, alpha: 0.16),
                    UIColor.clear
                ],
                locations: [0, 1],
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: size.width, y: size.height),
                blendMode: .screen
            )
            drawFilmGrain(in: context, size: size, alpha: 0.035, spacing: 5.2)
        }
    }

    private static func vhs90sTapeImage(from ciImage: CIImage, baseImage: UIImage) -> UIImage {
        let adjusted = ciImage
            .applyingColorControls(saturation: 1.12, brightness: -0.01, contrast: 1.08)
            .applyingExposureAdjust(ev: 0.05)
        let vhsBase = renderedUIImage(from: adjusted) ?? baseImage
        return overlay(on: vhsBase) { context, size in
            let redGhost = tinted(vhsBase, color: UIColor(red: 1.0, green: 0.2, blue: 0.26, alpha: 0.24))
            let blueGhost = tinted(vhsBase, color: UIColor(red: 0.20, green: 0.54, blue: 1.0, alpha: 0.22))
            redGhost.draw(at: CGPoint(x: -6, y: 0), blendMode: .screen, alpha: 1)
            blueGhost.draw(at: CGPoint(x: 6, y: 0), blendMode: .screen, alpha: 1)
            drawScanlines(in: context, size: size, alpha: 0.12, spacing: 4.5)
            context.setBlendMode(.plusLighter)
            UIColor.white.withAlphaComponent(0.08).setFill()
            context.fill(CGRect(x: 0, y: size.height * 0.78, width: size.width, height: 2))
        }
    }

    private static func crtScanlineImage(from ciImage: CIImage, baseImage: UIImage) -> UIImage {
        let crt = ciImage
            .applyingColorControls(saturation: 0.98, brightness: 0.01, contrast: 1.08)
        let crtBase = renderedUIImage(from: crt) ?? baseImage
        return overlay(on: crtBase) { context, size in
            drawScanlines(in: context, size: size, alpha: 0.1, spacing: 3.3)
            context.saveGState()
            context.setBlendMode(.screen)
            stride(from: 0.0, through: size.width, by: 3).forEach { x in
                let tint = x.truncatingRemainder(dividingBy: 9)
                let color: UIColor
                switch tint {
                case 0..<3:
                    color = UIColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 0.018)
                case 3..<6:
                    color = UIColor(red: 0.18, green: 1.0, blue: 0.4, alpha: 0.018)
                default:
                    color = UIColor(red: 0.18, green: 0.64, blue: 1.0, alpha: 0.018)
                }
                color.setFill()
                context.fill(CGRect(x: x, y: 0, width: 1, height: size.height))
            }
            context.restoreGState()
        }
    }

    private static func halftonePrintImage(from ciImage: CIImage, baseImage: UIImage) -> UIImage {
        let halftone = CIFilter.cmykHalftone()
        halftone.inputImage = ciImage
        halftone.width = 7
        halftone.sharpness = 0.92
        halftone.center = CGPoint(x: ciImage.extent.midX, y: ciImage.extent.midY)
        let colorized = (halftone.outputImage ?? ciImage)
            .applyingColorControls(saturation: 1.1, brightness: 0.02, contrast: 1.08)
        return renderedUIImage(from: colorized) ?? baseImage
    }

    private static func posterizeQuantizeImage(from ciImage: CIImage, baseImage: UIImage) -> UIImage {
        let posterized = ciImage
            .applyingColorPosterize(levels: 6)
            .applyingColorControls(saturation: 1.08, brightness: 0.01, contrast: 1.16)
        return renderedUIImage(from: posterized) ?? baseImage
    }

    private static func glitchCleanImage(from ciImage: CIImage, baseImage: UIImage) -> UIImage {
        let punchy = ciImage
            .applyingColorControls(saturation: 1.16, brightness: 0.01, contrast: 1.18)
        let glitchBase = renderedUIImage(from: punchy) ?? baseImage
        return overlay(on: glitchBase) { context, size in
            let sliceHeight = max(size.height / 18, 14)
            for index in 0..<5 {
                let y = CGFloat(index) * sliceHeight * 1.8 + size.height * 0.08
                let height = max(sliceHeight * 0.68, 10)
                let shift = CGFloat((index % 3) - 1) * 8
                glitchBase.draw(
                    in: CGRect(x: shift, y: y, width: size.width, height: height),
                    blendMode: .screen,
                    alpha: 0.14
                )
                let tint = index.isMultiple(of: 2)
                    ? UIColor.systemCyan.withAlphaComponent(0.06)
                    : UIColor.systemPink.withAlphaComponent(0.06)
                tint.setFill()
                context.fill(CGRect(x: 0, y: y, width: size.width, height: height))
            }
        }
    }

    private static func chromaticAberrationImage(from ciImage: CIImage, baseImage: UIImage) -> UIImage {
        let sharpened = ciImage
            .applyingColorControls(saturation: 1.08, brightness: 0, contrast: 1.14)
        let chromaBase = renderedUIImage(from: sharpened) ?? baseImage
        return overlay(on: chromaBase) { _, _ in
            tinted(chromaBase, color: UIColor(red: 1.0, green: 0.16, blue: 0.18, alpha: 0.24))
                .draw(at: CGPoint(x: -7, y: 0), blendMode: .screen, alpha: 1)
            tinted(chromaBase, color: UIColor(red: 0.18, green: 0.4, blue: 1.0, alpha: 0.24))
                .draw(at: CGPoint(x: 7, y: 0), blendMode: .screen, alpha: 1)
        }
    }

    private static func thermalHeatmapImage(from ciImage: CIImage, baseImage: UIImage) -> UIImage {
        let mono = ciImage
            .applyingPhotoEffect(.mono)
            .applyingColorControls(saturation: 0, brightness: 0.04, contrast: 1.24)
        let mapped = colorMapped(mono, colors: [
            UIColor(red: 0.04, green: 0.12, blue: 0.86, alpha: 1),
            UIColor(red: 0.10, green: 0.52, blue: 1.0, alpha: 1),
            UIColor(red: 0.12, green: 0.96, blue: 0.88, alpha: 1),
            UIColor(red: 0.28, green: 1.0, blue: 0.44, alpha: 1),
            UIColor(red: 1.0, green: 0.88, blue: 0.16, alpha: 1),
            UIColor(red: 1.0, green: 0.46, blue: 0.14, alpha: 1),
            UIColor(red: 1.0, green: 0.14, blue: 0.12, alpha: 1)
        ])?.applyingColorControls(saturation: 1.12, brightness: 0.02, contrast: 1.08) ?? mono
        return renderedUIImage(from: mapped) ?? baseImage
    }

    private static func pixelSortDataMeltImage(from ciImage: CIImage, baseImage: UIImage) -> UIImage {
        let base = renderedUIImage(from: ciImage.applyingColorControls(saturation: 1.1, brightness: 0.01, contrast: 1.08)) ?? baseImage
        return overlay(on: base) { context, size in
            drawHorizontalDisplacement(
                from: base,
                in: context,
                size: size,
                stripHeight: max(size.height / 42, 12),
                maxShift: max(size.width * 0.045, 14),
                alpha: 1,
                blendMode: .normal,
                phase: 1.2,
                frequency: 0.34,
                yRange: 0.18...1.0
            )
            drawLinearGradient(
                in: context,
                colors: [
                    UIColor(red: 1.0, green: 0.56, blue: 0.22, alpha: 0.08),
                    UIColor(red: 0.98, green: 0.18, blue: 0.64, alpha: 0.08),
                    UIColor.clear
                ],
                locations: [0, 0.42, 1],
                start: CGPoint(x: 0, y: size.height),
                end: CGPoint(x: size.width, y: 0),
                blendMode: .softLight
            )
        }
    }

    private static func renderedUIImage(from ciImage: CIImage?) -> UIImage? {
        guard let ciImage else { return nil }
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func overlay(on image: UIImage, draw: (CGContext, CGSize) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { rendererContext in
            let rect = CGRect(origin: .zero, size: image.size)
            image.draw(in: rect)
            draw(rendererContext.cgContext, image.size)
        }
    }

    private static func tinted(_ image: UIImage, color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            let rect = CGRect(origin: .zero, size: image.size)
            color.setFill()
            UIRectFill(rect)
            image.draw(in: rect, blendMode: .destinationIn, alpha: 1)
        }
    }

    private static func drawScanlines(in context: CGContext, size: CGSize, alpha: CGFloat, spacing: CGFloat) {
        context.saveGState()
        context.setBlendMode(.screen)
        context.setLineWidth(1)
        context.setStrokeColor(UIColor.white.withAlphaComponent(alpha).cgColor)
        stride(from: 0.0, through: size.height, by: spacing).forEach { y in
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.strokePath()
        context.restoreGState()
    }

    private static func colorMapped(_ ciImage: CIImage, colors: [UIColor]) -> CIImage? {
        guard let gradientImage = gradientMapImage(colors: colors) else { return nil }
        guard let filter = CIFilter(name: "CIColorMap") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(gradientImage, forKey: "inputGradientImage")
        return filter.outputImage
    }

    private static func gradientMapImage(colors: [UIColor]) -> CIImage? {
        guard colors.count >= 2 else { return nil }
        let size = CGSize(width: 256, height: 1)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let cgColors = colors.map { $0.cgColor } as CFArray
        let locations = evenlyDistributedLocations(count: colors.count)
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { rendererContext in
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: cgColors,
                locations: locations
            ) else {
                return
            }

            rendererContext.cgContext.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: size.width, y: 0),
                options: []
            )
        }
        return CIImage(image: image)
    }

    private static func drawLinearGradient(
        in context: CGContext,
        colors: [UIColor],
        locations: [CGFloat],
        start: CGPoint,
        end: CGPoint,
        blendMode: CGBlendMode
    ) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors.map(\.cgColor) as CFArray,
            locations: locations
        ) else {
            return
        }

        context.saveGState()
        context.setBlendMode(blendMode)
        context.drawLinearGradient(gradient, start: start, end: end, options: [])
        context.restoreGState()
    }

    private static func drawRadialGlow(
        in context: CGContext,
        size: CGSize,
        center: CGPoint,
        colors: [UIColor],
        radius: CGFloat,
        blendMode: CGBlendMode
    ) {
        let locations = evenlyDistributedLocations(count: colors.count)
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors.map { $0.cgColor } as CFArray,
            locations: locations
        ) else {
            return
        }

        context.saveGState()
        context.setBlendMode(blendMode)
        context.drawRadialGradient(
            gradient,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: radius,
            options: []
        )
        context.restoreGState()
    }

    private static func evenlyDistributedLocations(count: Int) -> [CGFloat] {
        guard count > 1 else { return [0] }
        let lastIndex = CGFloat(count - 1)
        return (0..<count).map { CGFloat($0) / lastIndex }
    }

    private static func drawFilmGrain(in context: CGContext, size: CGSize, alpha: CGFloat, spacing: CGFloat) {
        context.saveGState()
        context.setBlendMode(.overlay)

        for y in stride(from: 0.0, to: size.height, by: spacing) {
            for x in stride(from: 0.0, to: size.width, by: spacing) {
                let noise = deterministicNoise(x: x, y: y)
                let grainAlpha = max(0, noise - 0.54) * alpha * 1.8
                guard grainAlpha > 0 else { continue }
                let whiteValue = noise > 0.78 ? 1.0 : 0.0
                UIColor(white: whiteValue, alpha: grainAlpha).setFill()
                context.fill(CGRect(x: x, y: y, width: spacing * 0.56, height: spacing * 0.56))
            }
        }

        context.restoreGState()
    }

    private static func deterministicNoise(x: CGFloat, y: CGFloat) -> CGFloat {
        let value = sin((x * 12.9898) + (y * 78.233)) * 43758.5453
        return value - floor(value)
    }

    private static func drawHorizontalDisplacement(
        from image: UIImage,
        in context: CGContext,
        size: CGSize,
        stripHeight: CGFloat,
        maxShift: CGFloat,
        alpha: CGFloat,
        blendMode: CGBlendMode,
        phase: CGFloat,
        frequency: CGFloat,
        yRange: ClosedRange<CGFloat>
    ) {
        guard let cgImage = image.cgImage else { return }

        let scale = image.scale
        let sourceBounds = CGRect(x: 0, y: 0, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        let minY = size.height * yRange.lowerBound
        let maxY = size.height * yRange.upperBound

        context.saveGState()
        context.setBlendMode(blendMode)
        context.setAlpha(alpha)

        for stripeIndex in 0..<Int(ceil(size.height / stripHeight)) {
            let y = CGFloat(stripeIndex) * stripHeight
            guard y >= minY, y <= maxY else { continue }

            let height = min(stripHeight, size.height - y)
            let shift = sin(CGFloat(stripeIndex) * frequency + phase) * maxShift
                + cos(CGFloat(stripeIndex) * frequency * 0.47 + phase * 0.65) * maxShift * 0.34
            guard abs(shift) > 0.8 else { continue }

            let cropRect = CGRect(
                x: 0,
                y: y * scale,
                width: sourceBounds.width,
                height: height * scale
            ).integral.intersection(sourceBounds)
            guard let strip = cgImage.cropping(to: cropRect) else { continue }

            context.draw(strip, in: CGRect(x: shift, y: y, width: size.width, height: height))
        }

        context.restoreGState()
    }
}

enum ImageRemixPhotoLibrary {
    enum SaveError: LocalizedError {
        case failed

        var errorDescription: String? {
            "Couldn't save that image right now."
        }
    }

    static func requestWriteAuthorizationIfNeeded() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch current {
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                    continuation.resume(returning: status)
                }
            }
        default:
            return current
        }
    }

    static func save(image: UIImage) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: SaveError.failed)
                }
            }
        }
    }
}

private extension CIImage {
    func applyingColorControls(saturation: Float, brightness: Float, contrast: Float) -> CIImage {
        let filter = CIFilter.colorControls()
        filter.inputImage = self
        filter.saturation = saturation
        filter.brightness = brightness
        filter.contrast = contrast
        return filter.outputImage ?? self
    }

    func applyingHueAdjust(angle: Float) -> CIImage {
        let filter = CIFilter.hueAdjust()
        filter.inputImage = self
        filter.angle = angle
        return filter.outputImage ?? self
    }

    func applyingExposureAdjust(ev: Float) -> CIImage {
        let filter = CIFilter.exposureAdjust()
        filter.inputImage = self
        filter.ev = ev
        return filter.outputImage ?? self
    }

    func applyingGammaAdjust(power: Float) -> CIImage {
        let filter = CIFilter.gammaAdjust()
        filter.inputImage = self
        filter.power = power
        return filter.outputImage ?? self
    }

    func applyingBloom(radius: Float, intensity: Float) -> CIImage {
        let filter = CIFilter.bloom()
        filter.inputImage = self
        filter.radius = radius
        filter.intensity = intensity
        return filter.outputImage?.cropped(to: extent) ?? self
    }

    func applyingGaussianBlur(radius: Float) -> CIImage {
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = self
        filter.radius = radius
        return filter.outputImage?.cropped(to: extent) ?? self
    }

    func applyingColorPosterize(levels: Float) -> CIImage {
        let filter = CIFilter.colorPosterize()
        filter.inputImage = self
        filter.levels = levels
        return filter.outputImage ?? self
    }

    func applyingSepia(intensity: Float) -> CIImage {
        let filter = CIFilter.sepiaTone()
        filter.inputImage = self
        filter.intensity = intensity
        return filter.outputImage ?? self
    }

    func applyingPhotoEffect(_ effect: ImageRemixPhotoEffect) -> CIImage {
        switch effect {
        case .mono:
            let filter = CIFilter.photoEffectMono()
            filter.inputImage = self
            return filter.outputImage ?? self
        case .tonal:
            let filter = CIFilter.photoEffectTonal()
            filter.inputImage = self
            return filter.outputImage ?? self
        case .process:
            let filter = CIFilter.photoEffectProcess()
            filter.inputImage = self
            return filter.outputImage ?? self
        }
    }
}

private enum ImageRemixPhotoEffect {
    case mono
    case tonal
    case process
}

extension UIImage {
    func flowNormalizedUp() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    func flowPreparedForRemix(maxDimension: CGFloat) -> UIImage {
        let normalized = flowNormalizedUp()
        let longestSide = max(normalized.size.width, normalized.size.height)
        guard longestSide > maxDimension, longestSide > 0 else { return normalized }

        let resizeScale = maxDimension / longestSide
        let targetSize = CGSize(
            width: normalized.size.width * resizeScale,
            height: normalized.size.height * resizeScale
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            normalized.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}

extension String {
    var firstEmojiCluster: String? {
        for character in self {
            let cluster = String(character)
            if cluster.unicodeScalars.contains(where: { $0.properties.isEmoji || $0.properties.isEmojiPresentation }) {
                return cluster
            }
        }
        return nil
    }
}

extension CGPoint {
    func clampedToUnitSquare() -> CGPoint {
        CGPoint(
            x: x.clamped(to: 0...1),
            y: y.clamped(to: 0...1)
        )
    }
}

extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
