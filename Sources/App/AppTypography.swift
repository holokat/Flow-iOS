import CoreText
import SwiftUI
import UIKit

extension AppFontSize {
    var uiContentSizeCategory: UIContentSizeCategory {
        switch self {
        case .small:
            return .small
        case .medium:
            return .medium
        case .large:
            return .large
        case .extraLarge:
            return .extraLarge
        }
    }
}

extension AppSettingsStore {
    func appFont(_ textStyle: UIFont.TextStyle, weight: UIFont.Weight = .regular) -> Font {
        Font(appUIFont(textStyle, weight: weight))
    }

    func appUIFont(_ textStyle: UIFont.TextStyle, weight: UIFont.Weight = .regular) -> UIFont {
        let metrics = UIFontMetrics(forTextStyle: textStyle)
        let baseFont = UIFont.systemFont(ofSize: textStyle.basePointSize, weight: weight)
        return metrics.scaledFont(for: baseFont)
    }

    func appFont(size: CGFloat, weight: UIFont.Weight = .regular) -> Font {
        Font(appUIFont(size: size, weight: weight))
    }

    func appUIFont(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        UIFont.systemFont(ofSize: size, weight: weight)
    }
}

extension AppFontOption {
    func previewFont(size: CGFloat, weight: UIFont.Weight = .regular) -> Font {
        Font(uiFont(size: size, weight: weight))
    }

    fileprivate func uiFont(
        textStyle: UIFont.TextStyle,
        weight: UIFont.Weight,
        contentSizeCategory: UIContentSizeCategory
    ) -> UIFont {
        let metrics = UIFontMetrics(forTextStyle: textStyle)
        let baseFont = uiFont(size: textStyle.basePointSize, weight: weight)
        let traitCollection = UITraitCollection(preferredContentSizeCategory: contentSizeCategory)
        return metrics.scaledFont(for: baseFont, compatibleWith: traitCollection)
    }

    fileprivate func uiFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        if usesSystemMonospacedDesign {
            return UIFont.monospacedSystemFont(ofSize: size, weight: weight)
        }

        AppFontRegistry.registerIfNeeded(for: self)

        guard let familyName else {
            return UIFont.systemFont(ofSize: size, weight: weight)
        }

        let descriptor = UIFontDescriptor(fontAttributes: [
            .family: familyName,
            .traits: [UIFontDescriptor.TraitKey.weight: weight]
        ])
        let font = UIFont(descriptor: descriptor, size: size)

        if font.familyName == familyName {
            return font
        }

        return UIFont.systemFont(ofSize: size, weight: weight)
    }
}

private enum AppFontRegistry {
    private static let lock = NSLock()
    private static var registeredResourceNames = Set<String>()

    static func registerIfNeeded(for option: AppFontOption, bundle: Bundle = .main) {
        for resourceFileName in option.resourceFileNames {
            register(resourceFileName: resourceFileName, bundle: bundle)
        }
    }

    private static func register(resourceFileName: String, bundle: Bundle) {
        lock.lock()
        if registeredResourceNames.contains(resourceFileName) {
            lock.unlock()
            return
        }
        lock.unlock()

        let resourceURL = bundle.url(
            forResource: resourceFileName.resourceNameWithoutExtension,
            withExtension: resourceFileName.resourceFileExtension
        )
        guard let resourceURL else { return }

        var registrationError: Unmanaged<CFError>?
        let didRegister = CTFontManagerRegisterFontsForURL(
            resourceURL as CFURL,
            .process,
            &registrationError
        )

        if didRegister || isAlreadyRegisteredError(registrationError?.takeRetainedValue()) {
            lock.lock()
            registeredResourceNames.insert(resourceFileName)
            lock.unlock()
        }
    }

    private static func isAlreadyRegisteredError(_ error: CFError?) -> Bool {
        guard let error else { return false }
        let domain = CFErrorGetDomain(error) as String
        let code = CFErrorGetCode(error)
        return domain == (kCTFontManagerErrorDomain as String)
            && code == CTFontManagerError.alreadyRegistered.rawValue
    }
}

private extension String {
    var resourceNameWithoutExtension: String {
        (self as NSString).deletingPathExtension
    }

    var resourceFileExtension: String {
        (self as NSString).pathExtension
    }
}

private extension UIFont.TextStyle {
    var basePointSize: CGFloat {
        switch self {
        case .largeTitle:
            return 34
        case .title1:
            return 28
        case .title2:
            return 22
        case .title3:
            return 20
        case .headline:
            return 17
        case .subheadline:
            return 15
        case .body:
            return 17
        case .callout:
            return 16
        case .footnote:
            return 13
        case .caption1:
            return 12
        case .caption2:
            return 11
        default:
            return 17
        }
    }
}
