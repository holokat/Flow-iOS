import UIKit

enum AppHaptics {
    static func reactionTap() {
        DispatchQueue.main.async {
            let generator = UIImpactFeedbackGenerator(style: .rigid)
            generator.prepare()
            generator.impactOccurred(intensity: 1)
        }
    }

    static func reactionChargePulse(progress: CGFloat) {
        let clampedProgress = min(max(progress, 0), 1)
        let intensity = 0.24 + (clampedProgress * 0.58)

        DispatchQueue.main.async {
            let generator = UIImpactFeedbackGenerator(style: .soft)
            generator.prepare()
            generator.impactOccurred(intensity: intensity)
        }
    }

    static func reactionChargeCompleted() {
        DispatchQueue.main.async {
            let generator = UIImpactFeedbackGenerator(style: .heavy)
            generator.prepare()
            generator.impactOccurred(intensity: 1)
        }
    }

    static func liveReactionTick() {
        DispatchQueue.main.async {
            let generator = UIImpactFeedbackGenerator(style: .soft)
            generator.prepare()
            generator.impactOccurred(intensity: 0.4)
        }
    }
}
