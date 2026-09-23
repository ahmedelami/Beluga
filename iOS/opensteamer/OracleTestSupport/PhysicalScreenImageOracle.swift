import Foundation

/// A small, privacy-safe summary of the center of the *composited iPhone screenshot* while the
/// physical Mac-screen challenge is running. It never stores the screenshot or its pixel bytes.
struct PhysicalScreenImageSnapshot: Equatable {
    let saturatedPixelCount: Int
    let pixelCount: Int
    let averageRed: Int
    let averageGreen: Int
    let averageBlue: Int

    init?(rgba8: [UInt8], width: Int, height: Int) {
        guard width > 0, height > 0,
              rgba8.count == width * height * 4 else {
            return nil
        }
        pixelCount = width * height
        var saturatedCount = 0
        var redTotal = 0
        var greenTotal = 0
        var blueTotal = 0
        for offset in stride(from: 0, to: rgba8.count, by: 4) {
            let red = Int(rgba8[offset])
            let green = Int(rgba8[offset + 1])
            let blue = Int(rgba8[offset + 2])
            let alpha = Int(rgba8[offset + 3])
            let brightest = max(red, green, blue)
            let darkest = min(red, green, blue)
            // The challenge has a vivid changing background. Black covers and white status text
            // do not satisfy this condition, even if metadata reports decoded/presented frames.
            if alpha >= 240, brightest >= 96, brightest - darkest >= 64 {
                saturatedCount += 1
                redTotal += red
                greenTotal += green
                blueTotal += blue
            }
        }
        saturatedPixelCount = saturatedCount
        averageRed = saturatedCount == 0 ? 0 : redTotal / saturatedCount
        averageGreen = saturatedCount == 0 ? 0 : greenTotal / saturatedCount
        averageBlue = saturatedCount == 0 ? 0 : blueTotal / saturatedCount
    }

    var saturatedFraction: Double {
        Double(saturatedPixelCount) / Double(pixelCount)
    }
}

enum PhysicalScreenImageEvaluator {
    enum Result: Equatable {
        case insufficientSamples
        case noVisibleChallenge
        case challengeDidNotChange
        case visibleChangingChallenge
    }

    static func evaluate(_ snapshots: [PhysicalScreenImageSnapshot]) -> Result {
        guard snapshots.count >= 3 else { return .insufficientSamples }
        guard snapshots.allSatisfy({ $0.saturatedFraction >= 0.20 }) else {
            return .noVisibleChallenge
        }
        let first = snapshots[0]
        let changed = snapshots.dropFirst().contains { sample in
            max(
                abs(sample.averageRed - first.averageRed),
                abs(sample.averageGreen - first.averageGreen),
                abs(sample.averageBlue - first.averageBlue)
            ) >= 24
        }
        return changed ? .visibleChangingChallenge : .challengeDidNotChange
    }
}
