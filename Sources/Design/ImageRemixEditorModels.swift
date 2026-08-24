import SwiftUI
import UIKit

enum ImageRemixTool: String, CaseIterable, Identifiable {
    case filters
    case subjects
    case draw
    case text
    case stickers
    case create

    var id: String { rawValue }

    var title: String {
        switch self {
        case .filters:
            return "Filters"
        case .subjects:
            return "Subject"
        case .draw:
            return "Draw"
        case .text:
            return "Text"
        case .stickers:
            return "Stickers"
        case .create:
            return "Create"
        }
    }

    var iconName: String {
        switch self {
        case .filters:
            return "sparkles"
        case .subjects:
            return "person.crop.rectangle"
        case .draw:
            return "scribble.variable"
        case .text:
            return "textformat"
        case .stickers:
            return "face.smiling"
        case .create:
            return "wand.and.stars"
        }
    }
}

enum ImageRemixFilterPreset: String, CaseIterable, Identifiable {
    case original
    case duotoneGradient
    case tritoneEditorial
    case metallicChrome
    case liquidMetalFlow
    case hologram
    case prismDispersion
    case softBloomGlow
    case neonGlow
    case glassFrostedBlur
    case lightSweep
    case filmGrainCinematic
    case vintageFilmFade
    case vhs90sTape
    case crtScanline
    case halftonePrint
    case posterizeQuantize
    case glitchClean
    case chromaticAberration
    case thermalHeatmap
    case pixelSortDataMelt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original:
            return "Original"
        case .duotoneGradient:
            return "Duotone Gradient"
        case .tritoneEditorial:
            return "Tritone Editorial"
        case .metallicChrome:
            return "Metallic Chrome"
        case .liquidMetalFlow:
            return "Liquid Metal Halo"
        case .hologram:
            return "Hologram"
        case .prismDispersion:
            return "Prism Dispersion"
        case .softBloomGlow:
            return "Soft Bloom Glow"
        case .neonGlow:
            return "Neon Glow"
        case .glassFrostedBlur:
            return "Glass / Frosted Blur"
        case .lightSweep:
            return "Light Sweep"
        case .filmGrainCinematic:
            return "Film Grain (Cinematic)"
        case .vintageFilmFade:
            return "Vintage Film Fade"
        case .vhs90sTape:
            return "VHS / 90s Tape"
        case .crtScanline:
            return "CRT Scanline"
        case .halftonePrint:
            return "Halftone Print"
        case .posterizeQuantize:
            return "Posterize / Color Quantize"
        case .glitchClean:
            return "Glitch (Clean Variant)"
        case .chromaticAberration:
            return "Chromatic Aberration"
        case .thermalHeatmap:
            return "Thermal / Heatmap"
        case .pixelSortDataMelt:
            return "Pixel Sort / Data Melt"
        }
    }

    var swatchGradient: LinearGradient {
        switch self {
        case .original:
            return LinearGradient(colors: [.white, .gray], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .duotoneGradient:
            return LinearGradient(colors: [Color(red: 0.06, green: 0.10, blue: 0.20), Color(red: 0.94, green: 0.79, blue: 0.34)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .tritoneEditorial:
            return LinearGradient(colors: [Color(red: 0.08, green: 0.12, blue: 0.22), Color(red: 0.58, green: 0.48, blue: 0.36), Color(red: 0.94, green: 0.90, blue: 0.82)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .metallicChrome:
            return LinearGradient(colors: [Color(red: 0.18, green: 0.20, blue: 0.24), Color(red: 0.76, green: 0.78, blue: 0.82), Color.white], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .liquidMetalFlow:
            return LinearGradient(colors: [Color(red: 0.14, green: 0.18, blue: 0.22), Color(red: 0.86, green: 0.88, blue: 0.92), Color(red: 0.40, green: 0.58, blue: 0.82)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .hologram:
            return LinearGradient(colors: [Color(red: 0.26, green: 0.95, blue: 0.98), Color(red: 0.88, green: 0.44, blue: 1.0)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .prismDispersion:
            return LinearGradient(colors: [Color(red: 0.37, green: 0.71, blue: 1.0), Color(red: 0.88, green: 0.42, blue: 1.0), Color(red: 0.98, green: 0.84, blue: 0.34)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .softBloomGlow:
            return LinearGradient(colors: [Color.white, Color(red: 0.98, green: 0.76, blue: 0.56)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .neonGlow:
            return LinearGradient(colors: [Color(red: 0.12, green: 0.98, blue: 1.0), Color(red: 1.0, green: 0.28, blue: 0.80)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .glassFrostedBlur:
            return LinearGradient(colors: [Color.white.opacity(0.95), Color(red: 0.70, green: 0.90, blue: 1.0)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .lightSweep:
            return LinearGradient(colors: [Color(red: 0.95, green: 0.84, blue: 0.48), .white], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .filmGrainCinematic:
            return LinearGradient(colors: [Color(red: 0.14, green: 0.14, blue: 0.17), Color(red: 0.52, green: 0.48, blue: 0.42)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .vintageFilmFade:
            return LinearGradient(colors: [Color(red: 0.50, green: 0.36, blue: 0.24), Color(red: 0.92, green: 0.86, blue: 0.74)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .vhs90sTape:
            return LinearGradient(colors: [Color(red: 0.88, green: 0.21, blue: 0.29), Color(red: 0.21, green: 0.57, blue: 1.0)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .crtScanline:
            return LinearGradient(colors: [Color(red: 0.06, green: 0.16, blue: 0.12), Color(red: 0.34, green: 0.98, blue: 0.58)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .halftonePrint:
            return LinearGradient(colors: [Color(red: 0.27, green: 0.75, blue: 0.93), Color(red: 0.99, green: 0.54, blue: 0.23)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .posterizeQuantize:
            return LinearGradient(colors: [Color(red: 0.28, green: 0.34, blue: 0.98), Color(red: 0.98, green: 0.32, blue: 0.40), Color(red: 1.0, green: 0.82, blue: 0.24)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .glitchClean:
            return LinearGradient(colors: [.cyan, .pink, .yellow], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .chromaticAberration:
            return LinearGradient(colors: [Color.red, Color.blue], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .thermalHeatmap:
            return LinearGradient(colors: [Color(red: 0.10, green: 0.22, blue: 1.0), Color(red: 0.18, green: 0.98, blue: 0.92), Color(red: 1.0, green: 0.82, blue: 0.12), Color(red: 1.0, green: 0.24, blue: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .pixelSortDataMelt:
            return LinearGradient(colors: [Color(red: 0.24, green: 0.22, blue: 0.96), Color(red: 0.96, green: 0.26, blue: 0.62), Color(red: 1.0, green: 0.64, blue: 0.24)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

enum ImageRemixPalette: String, CaseIterable, Identifiable {
    case polar
    case sunlight
    case coral
    case mint
    case sky
    case lavender
    case ember
    case ink

    var id: String { rawValue }

    var swiftUIColor: Color {
        switch self {
        case .polar:
            return .white
        case .sunlight:
            return Color(red: 0.98, green: 0.86, blue: 0.34)
        case .coral:
            return Color(red: 0.99, green: 0.46, blue: 0.46)
        case .mint:
            return Color(red: 0.54, green: 1.0, blue: 0.79)
        case .sky:
            return Color(red: 0.37, green: 0.87, blue: 1.0)
        case .lavender:
            return Color(red: 0.86, green: 0.68, blue: 1.0)
        case .ember:
            return Color(red: 1.0, green: 0.62, blue: 0.23)
        case .ink:
            return Color(red: 0.07, green: 0.08, blue: 0.11)
        }
    }

    var uiColor: UIColor {
        UIColor(swiftUIColor)
    }
}

enum ImageRemixTextPlacement: String, CaseIterable, Identifiable {
    case center
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .center:
            return "Center"
        case .topLeft:
            return "Top Left"
        case .topRight:
            return "Top Right"
        case .bottomLeft:
            return "Bottom Left"
        case .bottomRight:
            return "Bottom Right"
        }
    }

    var normalizedAnchorPoint: CGPoint {
        switch self {
        case .center:
            return CGPoint(x: 0.5, y: 0.5)
        case .topLeft:
            return CGPoint(x: 0.28, y: 0.18)
        case .topRight:
            return CGPoint(x: 0.72, y: 0.18)
        case .bottomLeft:
            return CGPoint(x: 0.28, y: 0.82)
        case .bottomRight:
            return CGPoint(x: 0.72, y: 0.82)
        }
    }

    var previewPoint: CGPoint {
        switch self {
        case .center:
            return CGPoint(x: 0.5, y: 0.5)
        case .topLeft:
            return CGPoint(x: 0.24, y: 0.24)
        case .topRight:
            return CGPoint(x: 0.76, y: 0.24)
        case .bottomLeft:
            return CGPoint(x: 0.24, y: 0.76)
        case .bottomRight:
            return CGPoint(x: 0.76, y: 0.76)
        }
    }

    var containerAlignment: Alignment {
        switch self {
        case .center:
            return .center
        case .topLeft:
            return .topLeading
        case .topRight:
            return .topTrailing
        case .bottomLeft:
            return .bottomLeading
        case .bottomRight:
            return .bottomTrailing
        }
    }

    var textFrameAlignment: Alignment {
        switch self {
        case .center:
            return .center
        case .topLeft, .bottomLeft:
            return .leading
        case .topRight, .bottomRight:
            return .trailing
        }
    }

    var textAlignment: TextAlignment {
        switch self {
        case .center:
            return .center
        case .topLeft, .bottomLeft:
            return .leading
        case .topRight, .bottomRight:
            return .trailing
        }
    }

    func canvasInsets(for canvasSize: CGSize) -> EdgeInsets {
        let horizontal = max(canvasSize.width * 0.06, 22)
        let vertical = max(canvasSize.height * 0.05, 20)
        return EdgeInsets(top: vertical, leading: horizontal, bottom: vertical, trailing: horizontal)
    }
}

struct ImageRemixStroke: Identifiable {
    let id = UUID()
    var points: [CGPoint]
    var palette: ImageRemixPalette
    var lineWidth: CGFloat
}

struct ImageRemixTextOverlay: Identifiable {
    let id = UUID()
    var text: String
    var palette: ImageRemixPalette
    var scale: CGFloat
    var position: CGPoint
    var placement: ImageRemixTextPlacement?
}

struct ImageRemixStickerOverlay: Identifiable {
    let id = UUID()
    var emoji: String
    var scale: CGFloat
    var position: CGPoint
}

struct ImageRemixEmojiEntry: Identifiable, Hashable {
    let emoji: String
    let keywords: String

    var id: String { emoji }

    func matches(searchTerm: String) -> Bool {
        let normalized = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return true }
        return emoji.contains(normalized) || keywords.contains(normalized)
    }

    static let featured: [ImageRemixEmojiEntry] = [
        entry("🔥", "fire hot flame lit"),
        entry("✨", "sparkles magic shine shimmer"),
        entry("👀", "eyes look watch"),
        entry("💥", "boom blast impact"),
        entry("😭", "cry sob tears"),
        entry("😎", "cool sunglasses vibe"),
        entry("🫧", "bubbles dreamy"),
        entry("🪩", "disco party sparkle"),
        entry("🌈", "rainbow colorful pride"),
        entry("⚡️", "lightning electric energy"),
        entry("🎉", "celebration confetti party"),
        entry("🛸", "ufo alien space")
    ]

    static let catalog: [ImageRemixEmojiEntry] = [
        entry("🔥", "fire hot flame lit energy"),
        entry("✨", "sparkles magic shimmer shine"),
        entry("💥", "boom blast impact explode"),
        entry("💫", "dizzy stars magic swirl"),
        entry("⭐️", "star favorite shine"),
        entry("🌟", "glowing star shine bright"),
        entry("⚡️", "lightning electric charge power"),
        entry("☄️", "comet meteor space"),
        entry("🌈", "rainbow colorful pride sky"),
        entry("🫧", "bubbles dreamy underwater foam"),
        entry("☀️", "sun sunshine warm bright"),
        entry("🌙", "moon night crescent"),
        entry("❄️", "snow cold winter flake"),
        entry("🌊", "wave ocean water beach"),
        entry("🌸", "blossom flower pink spring"),
        entry("🌹", "rose flower romance"),
        entry("🌼", "daisy flower bloom"),
        entry("🌻", "sunflower flower summer"),
        entry("🍀", "clover luck green"),
        entry("🌵", "cactus desert"),
        entry("🪴", "plant leaves home"),
        entry("🦋", "butterfly flutter"),
        entry("🐝", "bee honey buzz"),
        entry("🐸", "frog silly green"),
        entry("🦄", "unicorn magical fantasy"),
        entry("🐶", "dog puppy pet"),
        entry("🐱", "cat kitty pet"),
        entry("👀", "eyes look watch stare"),
        entry("🧠", "brain smart idea thinking"),
        entry("💎", "diamond gem luxury"),
        entry("👑", "crown king queen royalty"),
        entry("🕶️", "sunglasses cool shades"),
        entry("📼", "vhs tape retro nineties"),
        entry("📸", "camera photo picture"),
        entry("🎬", "clapper film movie cinema"),
        entry("🎞️", "film strip movie reel"),
        entry("🎧", "headphones music audio"),
        entry("🎤", "microphone sing karaoke"),
        entry("🎹", "piano keyboard music"),
        entry("🎸", "guitar rock music"),
        entry("🥁", "drum beat music"),
        entry("💿", "disc cd music retro"),
        entry("🪩", "disco ball dance party"),
        entry("🪄", "magic wand spell"),
        entry("🛸", "ufo alien spaceship"),
        entry("🚀", "rocket launch space"),
        entry("🪐", "planet saturn space"),
        entry("🌍", "earth globe world"),
        entry("🎉", "party celebration confetti"),
        entry("🎊", "confetti celebration party"),
        entry("🎈", "balloon party float"),
        entry("🎁", "gift present box"),
        entry("🎀", "bow ribbon cute"),
        entry("🥳", "party face celebrate"),
        entry("😎", "cool sunglasses chill"),
        entry("😄", "smile happy grin"),
        entry("😁", "grin smile happy"),
        entry("😂", "laugh tears funny"),
        entry("🤣", "rolling laugh hilarious"),
        entry("😊", "blush smile sweet"),
        entry("😍", "heart eyes love"),
        entry("😘", "kiss love hearts"),
        entry("🥹", "teary grateful soft"),
        entry("😭", "cry sob tears sad"),
        entry("🥲", "smile cry bittersweet"),
        entry("😅", "sweat smile relief"),
        entry("😮‍💨", "exhale sigh relief"),
        entry("😴", "sleep tired snooze"),
        entry("🫠", "melting awkward oops"),
        entry("🤯", "mind blown shocked"),
        entry("😵‍💫", "dizzy spiral overwhelmed"),
        entry("😡", "angry mad rage"),
        entry("😤", "huff annoyed frustrated"),
        entry("🥶", "freezing cold icy"),
        entry("🥵", "hot sweating"),
        entry("🤠", "cowboy yeehaw western"),
        entry("🤡", "clown chaos silly"),
        entry("👻", "ghost spooky"),
        entry("💀", "skull dead funny"),
        entry("☠️", "skull crossbones danger"),
        entry("👽", "alien outer space"),
        entry("🤖", "robot tech future"),
        entry("❤️", "heart love red"),
        entry("🩷", "pink heart love"),
        entry("🧡", "orange heart love"),
        entry("💛", "yellow heart love"),
        entry("💚", "green heart love"),
        entry("🩵", "light blue heart love"),
        entry("💙", "blue heart love"),
        entry("💜", "purple heart love"),
        entry("🖤", "black heart love"),
        entry("🤍", "white heart love"),
        entry("🤎", "brown heart love"),
        entry("💔", "broken heart heartbreak"),
        entry("❤️‍🔥", "heart on fire passion"),
        entry("💕", "two hearts love"),
        entry("💖", "sparkle heart love"),
        entry("💘", "heart arrow crush"),
        entry("🫶", "heart hands love"),
        entry("👏", "clap applause"),
        entry("🙌", "raise hands celebrate"),
        entry("🙏", "pray thanks hope"),
        entry("👍", "thumbs up yes like"),
        entry("👎", "thumbs down no dislike"),
        entry("✌️", "peace victory two"),
        entry("🤞", "cross fingers luck"),
        entry("👌", "ok hand perfect"),
        entry("💅", "nails sass glam"),
        entry("☕️", "coffee espresso drink"),
        entry("🍕", "pizza slice food"),
        entry("🍔", "burger food"),
        entry("🍟", "fries snack food"),
        entry("🍓", "strawberry fruit sweet"),
        entry("🍒", "cherries fruit sweet"),
        entry("🍑", "peach fruit"),
        entry("🍸", "cocktail martini drink"),
        entry("🍷", "wine drink"),
        entry("🥂", "cheers toast glasses"),
        entry("🏁", "finish racing flag"),
        entry("🏆", "trophy winner victory"),
        entry("⚽️", "soccer football ball"),
        entry("🏀", "basketball sports"),
        entry("💯", "hundred score hype"),
        entry("✅", "check yes done"),
        entry("❌", "x no wrong"),
        entry("⚠️", "warning caution alert"),
        entry("🚨", "alarm siren alert"),
        entry("🔮", "crystal ball future"),
        entry("🪞", "mirror reflection"),
        entry("🧸", "teddy cute toy"),
        entry("🛼", "roller skate retro"),
        entry("🌐", "internet web globe")
    ]

    private static func entry(_ emoji: String, _ keywords: String) -> ImageRemixEmojiEntry {
        ImageRemixEmojiEntry(emoji: emoji, keywords: keywords.lowercased())
    }
}
