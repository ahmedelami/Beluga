import CryptoKit
import Foundation

/// An immutable, tightly scoped copy of an RGBA screenshot used by the physical screen oracle.
///
/// The type deliberately has no UIKit/CoreGraphics dependency so the same matcher can be compiled
/// into both the unit-test and UI-test bundles. Callers may render/crop/downsample an
/// `XCUIScreenshot` however they prefer, then pass the resulting RGBA bytes here.
struct PhysicalScreenSequenceFrame: Sendable {
    private let rgba8: [UInt8]
    private let width: Int
    private let height: Int
    private let bytesPerRow: Int

    /// Creates a frame from tightly packed, top-to-bottom RGBA8 rows.
    init?(rgba8: [UInt8], width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        guard !rowOverflow else { return nil }
        self.init(
            rgba8: rgba8,
            width: width,
            height: height,
            bytesPerRow: rowBytes
        )
    }

    /// Creates a frame from top-to-bottom RGBA8 rows that may contain trailing row padding.
    init?(rgba8: [UInt8], width: Int, height: Int, bytesPerRow: Int) {
        guard width > 0, height > 0 else { return nil }
        let (minimumRowBytes, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        guard !rowOverflow, bytesPerRow >= minimumRowBytes else { return nil }
        let (requiredByteCount, countOverflow) = bytesPerRow.multipliedReportingOverflow(
            by: height
        )
        guard !countOverflow, rgba8.count == requiredByteCount else { return nil }

        self.rgba8 = rgba8
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
    }

    /// Decodes one correctly oriented, complete 4x4 challenge for `nonce` from this frame.
    ///
    /// The search accepts a centered or offset challenge at a range of scales. It samples well
    /// inside every cell, tolerates ordinary video-range/color drift, and verifies all ten grid
    /// gutter lines. A vivid image, a partial grid, or a rotated/mirrored grid therefore cannot
    /// satisfy the matcher merely by sharing a few colors with the challenge.
    func decode(nonce: String) -> PhysicalScreenSequenceSymbol? {
        guard PhysicalScreenSequenceProtocol.isValidNonce(nonce),
              width >= PhysicalScreenSequenceProtocol.minimumFrameDimension,
              height >= PhysicalScreenSequenceProtocol.minimumFrameDimension else {
            return nil
        }

        let payloadToIndices = Dictionary(
            grouping: 0..<PhysicalScreenSequenceProtocol.symbolCount,
            by: { PhysicalScreenSequenceProtocol.payload(nonce: nonce, index: $0) }
        )
        let candidateWidths = candidateLengths(total: width)
        let candidateHeights = candidateLengths(total: height)

        for candidateWidth in candidateWidths {
            let candidateXOrigins = candidateOrigins(
                total: width,
                candidateLength: candidateWidth
            )
            for candidateHeight in candidateHeights {
                let candidateYOrigins = candidateOrigins(
                    total: height,
                    candidateLength: candidateHeight
                )
                for originY in candidateYOrigins {
                    for originX in candidateXOrigins {
                        let rectangle = SearchRectangle(
                            x: originX,
                            y: originY,
                            width: candidateWidth,
                            height: candidateHeight
                        )
                        guard let decodedPayload = payload(at: rectangle),
                              let matchingIndices = payloadToIndices[decodedPayload],
                              matchingIndices.count == 1,
                              let index = matchingIndices.first,
                              verifiesCellInteriors(
                                  at: rectangle,
                                  payload: decodedPayload
                              ),
                              verifiesGridGutters(at: rectangle) else {
                            continue
                        }
                        return PhysicalScreenSequenceSymbol(nonce: nonce, index: index)
                    }
                }
            }
        }
        return nil
    }

    private func candidateLengths(total: Int) -> [Int] {
        let minimum = max(
            PhysicalScreenSequenceProtocol.minimumGridDimension,
            total * PhysicalScreenSequenceProtocol.minimumGridPercent / 100
        )
        let maximum = total * PhysicalScreenSequenceProtocol.maximumGridPercent / 100
        guard minimum <= maximum else { return [] }
        let step = max(1, total / 32)
        var values = Array(stride(from: minimum, through: maximum, by: step))
        if values.last != maximum {
            values.append(maximum)
        }
        let preferred = total * 72 / 100
        values.sort {
            let leftDistance = abs($0 - preferred)
            let rightDistance = abs($1 - preferred)
            return leftDistance == rightDistance ? $0 > $1 : leftDistance < rightDistance
        }
        return values
    }

    private func candidateOrigins(total: Int, candidateLength: Int) -> [Int] {
        let maximumOrigin = total - candidateLength
        guard maximumOrigin > 0 else { return [0] }
        let preferred = maximumOrigin / 2
        let maximumOffset = max(1, total * 4 / 100)
        let step = max(1, total * 2 / 100)
        var values: Set<Int> = []
        for offset in stride(from: -maximumOffset, through: maximumOffset, by: step) {
            values.insert(min(maximumOrigin, max(0, preferred + offset)))
        }
        values.insert(preferred)
        return values.sorted {
            let leftDistance = abs($0 - preferred)
            let rightDistance = abs($1 - preferred)
            return leftDistance == rightDistance ? $0 < $1 : leftDistance < rightDistance
        }
    }

    /// Reads the 12 noncorner cells row-major and reconstructs their MSB-first payload.
    private func payload(at rectangle: SearchRectangle) -> UInt16? {
        var payload: UInt16 = 0
        var ordinal = 0
        for row in 0..<PhysicalScreenSequenceProtocol.gridCount {
            for column in 0..<PhysicalScreenSequenceProtocol.gridCount {
                guard let color = classifiedPixel(
                    x: rectangle.cellCenterX(column: column),
                    y: rectangle.cellCenterY(row: row)
                ) else {
                    return nil
                }
                switch (row, column) {
                case (0, 0):
                    guard color == .magenta else { return nil }
                case (0, 3):
                    guard color == .cyan else { return nil }
                case (3, 0):
                    guard color == .white else { return nil }
                case (3, 3):
                    guard color == .orange else { return nil }
                default:
                    guard color == .blue || color == .yellow else { return nil }
                    if color == .yellow {
                        payload |= 1 << UInt16(11 - ordinal)
                    }
                    ordinal += 1
                }
            }
        }
        return payload
    }

    /// A center pixel alone is intentionally insufficient. This verifies a small 3x3 sample
    /// inside each cell, which rejects thin lines/icons while tolerating isolated codec noise.
    private func verifiesCellInteriors(
        at rectangle: SearchRectangle,
        payload: UInt16
    ) -> Bool {
        let offsetX = max(1, rectangle.width / 32)
        let offsetY = max(1, rectangle.height / 32)
        let offsets = [-1, 0, 1]
        var ordinal = 0

        for row in 0..<PhysicalScreenSequenceProtocol.gridCount {
            for column in 0..<PhysicalScreenSequenceProtocol.gridCount {
                let expected: PaletteColor
                switch (row, column) {
                case (0, 0): expected = .magenta
                case (0, 3): expected = .cyan
                case (3, 0): expected = .white
                case (3, 3): expected = .orange
                default:
                    expected = payload & (1 << UInt16(11 - ordinal)) == 0 ? .blue : .yellow
                    ordinal += 1
                }

                let centerX = rectangle.cellCenterX(column: column)
                let centerY = rectangle.cellCenterY(row: row)
                var matchingSampleCount = 0
                for yMultiplier in offsets {
                    for xMultiplier in offsets {
                        if classifiedPixel(
                            x: centerX + xMultiplier * offsetX,
                            y: centerY + yMultiplier * offsetY
                        ) == expected {
                            matchingSampleCount += 1
                        }
                    }
                }
                guard matchingSampleCount >= 7 else { return false }
            }
        }
        return true
    }

    /// The challenge renderer leaves a black inset around every cell. Requiring a dark line near
    /// all five horizontal and all five vertical cell boundaries proves that the outer cells are
    /// present and prevents a crop of the colorful interior from being reinterpreted as a grid.
    private func verifiesGridGutters(at rectangle: SearchRectangle) -> Bool {
        let horizontalSearchRadius = max(1, rectangle.width / 24)
        let verticalSearchRadius = max(1, rectangle.height / 24)

        for boundary in 0...PhysicalScreenSequenceProtocol.gridCount {
            let expectedX = rectangle.x + boundary * rectangle.width /
                PhysicalScreenSequenceProtocol.gridCount
            var foundDarkLine = false
            for x in max(rectangle.x, expectedX - horizontalSearchRadius)...min(
                rectangle.maximumX,
                expectedX + horizontalSearchRadius
            ) {
                var darkSamples = 0
                for row in 0..<PhysicalScreenSequenceProtocol.gridCount where isDarkPixel(
                    x: x,
                    y: rectangle.cellCenterY(row: row)
                ) {
                    darkSamples += 1
                }
                if darkSamples >= 3 {
                    foundDarkLine = true
                    break
                }
            }
            guard foundDarkLine else { return false }
        }

        for boundary in 0...PhysicalScreenSequenceProtocol.gridCount {
            let expectedY = rectangle.y + boundary * rectangle.height /
                PhysicalScreenSequenceProtocol.gridCount
            var foundDarkLine = false
            for y in max(rectangle.y, expectedY - verticalSearchRadius)...min(
                rectangle.maximumY,
                expectedY + verticalSearchRadius
            ) {
                var darkSamples = 0
                for column in 0..<PhysicalScreenSequenceProtocol.gridCount where isDarkPixel(
                    x: rectangle.cellCenterX(column: column),
                    y: y
                ) {
                    darkSamples += 1
                }
                if darkSamples >= 3 {
                    foundDarkLine = true
                    break
                }
            }
            guard foundDarkLine else { return false }
        }
        return true
    }

    private func classifiedPixel(x: Int, y: Int) -> PaletteColor? {
        guard let pixel = pixel(x: x, y: y), pixel.alpha >= 128 else { return nil }
        let maximum = max(pixel.red, pixel.green, pixel.blue)
        let minimum = min(pixel.red, pixel.green, pixel.blue)
        guard maximum >= 70 else { return nil }

        var candidates: [(color: PaletteColor, distance: Int)] = []
        candidates.reserveCapacity(PaletteColor.allCases.count)
        for color in PaletteColor.allCases {
            if color == .white {
                guard minimum >= 100, maximum - minimum <= 80 else { continue }
            } else {
                guard maximum - minimum >= 55 else { continue }
            }
            let normalizedRed = pixel.red * 255 / maximum
            let normalizedGreen = pixel.green * 255 / maximum
            let normalizedBlue = pixel.blue * 255 / maximum
            let distance = abs(normalizedRed - color.red)
                + abs(normalizedGreen - color.green)
                + abs(normalizedBlue - color.blue)
            if distance <= 105 {
                candidates.append((color, distance))
            }
        }
        candidates.sort { $0.distance < $1.distance }
        guard let best = candidates.first else { return nil }
        if candidates.count > 1, candidates[1].distance - best.distance < 18 {
            return nil
        }
        return best.color
    }

    private func isDarkPixel(x: Int, y: Int) -> Bool {
        guard let pixel = pixel(x: x, y: y), pixel.alpha >= 128 else { return false }
        return max(pixel.red, pixel.green, pixel.blue) <= 96
    }

    private func pixel(x: Int, y: Int) -> RGBPixel? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        let offset = y * bytesPerRow + x * 4
        return RGBPixel(
            red: Int(rgba8[offset]),
            green: Int(rgba8[offset + 1]),
            blue: Int(rgba8[offset + 2]),
            alpha: Int(rgba8[offset + 3])
        )
    }
}

/// One nonce-bound symbol decoded from an actual screenshot.
struct PhysicalScreenSequenceSymbol: Equatable, Sendable {
    let nonce: String
    let index: Int

    init?(nonce: String, index: Int) {
        guard PhysicalScreenSequenceProtocol.isValidNonce(nonce),
              (0..<PhysicalScreenSequenceProtocol.symbolCount).contains(index) else {
            return nil
        }
        self.nonce = nonce
        self.index = index
    }
}

/// Fail-closed temporal proof that nonce-bound screen symbols really advanced on the iPhone.
struct PhysicalScreenSequenceTracker: Sendable {
    enum State: Equatable, Sendable {
        case collecting(distinctSymbolCount: Int)
        case satisfied
        case rejected
    }

    let nonce: String
    let requiredDistinctSymbolCount: Int
    let maximumConsecutiveUndecodableFrames: Int
    private(set) var state: State = .collecting(distinctSymbolCount: 0)

    private var lastIndex: Int?
    private var distinctIndices: Set<Int> = []
    private var consecutiveUndecodableFrameCount = 0

    init?(
        nonce: String,
        requiredDistinctSymbolCount: Int = 3,
        maximumConsecutiveUndecodableFrames: Int = 0
    ) {
        guard PhysicalScreenSequenceProtocol.isValidNonce(nonce),
              (3...PhysicalScreenSequenceProtocol.symbolCount).contains(
                  requiredDistinctSymbolCount
              ),
              maximumConsecutiveUndecodableFrames >= 0 else {
            return nil
        }
        self.nonce = nonce
        self.requiredDistinctSymbolCount = requiredDistinctSymbolCount
        self.maximumConsecutiveUndecodableFrames = maximumConsecutiveUndecodableFrames
    }

    /// Decodes and observes a screenshot. Undecodable transition frames are accepted only up to
    /// the explicit consecutive-frame budget; the default budget is zero and therefore strict.
    @discardableResult
    mutating func observe(_ frame: PhysicalScreenSequenceFrame) -> State {
        observe(frame.decode(nonce: nonce))
    }

    /// Allows a failable frame initializer to feed the tracker without accidentally dropping a
    /// malformed sample. `nil` consumes the same bounded undecodable-frame budget.
    @discardableResult
    mutating func observe(_ frame: PhysicalScreenSequenceFrame?) -> State {
        guard let frame else { return observeUndecodableFrame() }
        return observe(frame)
    }

    /// Observes an already-decoded symbol. This is useful when a physical UI test owns a bounded
    /// screenshot retry policy and only wants the tracker to enforce nonce, order, and freshness.
    /// Validation continues after `.satisfied`; a later bad nonce or transition rejects the run.
    @discardableResult
    mutating func observe(_ symbol: PhysicalScreenSequenceSymbol) -> State {
        guard state != .rejected else { return state }
        guard symbol.nonce == nonce else {
            state = .rejected
            return state
        }

        consecutiveUndecodableFrameCount = 0
        if let lastIndex {
            if symbol.index == lastIndex {
                return state
            }
            guard symbol.index == (lastIndex + 1) % PhysicalScreenSequenceProtocol.symbolCount else {
                state = .rejected
                return state
            }
        }

        lastIndex = symbol.index
        distinctIndices.insert(symbol.index)
        if distinctIndices.count >= requiredDistinctSymbolCount {
            state = .satisfied
        } else {
            state = .collecting(distinctSymbolCount: distinctIndices.count)
        }
        return state
    }

    /// Explicitly records a frame that was captured but could not be decoded. This lets callers
    /// tolerate a small, audited number of codec-transition samples without silently omitting an
    /// unbounded black/stale interval.
    @discardableResult
    mutating func observeUndecodableFrame() -> State {
        guard state != .rejected else { return state }
        consecutiveUndecodableFrameCount += 1
        if consecutiveUndecodableFrameCount > maximumConsecutiveUndecodableFrames {
            state = .rejected
        }
        return state
    }

    /// Optional-symbol counterpart for `frame.decode(nonce:)` call sites.
    @discardableResult
    mutating func observe(_ symbol: PhysicalScreenSequenceSymbol?) -> State {
        guard let symbol else { return observeUndecodableFrame() }
        return observe(symbol)
    }
}

/// Time-aware continuation proof layered over the nonce/order tracker.
///
/// Four distinct symbols prove one cycle, but do not prove that the final display kept moving
/// afterward. Requiring at least five ordered symbol runs proves a wrap into the next cycle, and
/// the hold deadline rejects a valid symbol that freezes before or after that proof.
struct PhysicalScreenSequenceContinuityTracker: Sendable {
    enum State: Equatable, Sendable {
        case collecting(symbolRunCount: Int)
        case satisfied
        case rejected
    }

    let nonce: String
    let requiredSymbolRunCount: Int
    let maximumSameSymbolHoldDuration: TimeInterval
    private(set) var state: State = .collecting(symbolRunCount: 0)
    private(set) var maximumObservedSameSymbolHoldDuration: TimeInterval = 0

    private var lastIndex: Int?
    private var currentSymbolStartedAt: TimeInterval?
    private var lastObservationTime: TimeInterval?
    private var symbolRunCount = 0

    init?(
        nonce: String,
        requiredSymbolRunCount: Int = PhysicalScreenSequenceProtocol.symbolCount + 1,
        maximumSameSymbolHoldDuration: TimeInterval
    ) {
        guard PhysicalScreenSequenceProtocol.isValidNonce(nonce),
              requiredSymbolRunCount >= PhysicalScreenSequenceProtocol.symbolCount + 1,
              maximumSameSymbolHoldDuration.isFinite,
              maximumSameSymbolHoldDuration > 0 else {
            return nil
        }
        self.nonce = nonce
        self.requiredSymbolRunCount = requiredSymbolRunCount
        self.maximumSameSymbolHoldDuration = maximumSameSymbolHoldDuration
    }

    @discardableResult
    mutating func observe(
        _ symbol: PhysicalScreenSequenceSymbol,
        at observationTime: TimeInterval
    ) -> State {
        guard state != .rejected else { return state }
        guard symbol.nonce == nonce,
              observationTime.isFinite,
              observationTime >= 0,
              lastObservationTime.map({ observationTime >= $0 }) != false else {
            state = .rejected
            return state
        }
        lastObservationTime = observationTime

        if let lastIndex {
            if symbol.index == lastIndex {
                guard let currentSymbolStartedAt else {
                    state = .rejected
                    return state
                }
                let heldFor = observationTime - currentSymbolStartedAt
                maximumObservedSameSymbolHoldDuration = max(
                    maximumObservedSameSymbolHoldDuration,
                    heldFor
                )
                if heldFor > maximumSameSymbolHoldDuration {
                    state = .rejected
                }
                return state
            }
            guard symbol.index == (lastIndex + 1) % PhysicalScreenSequenceProtocol.symbolCount
            else {
                state = .rejected
                return state
            }
        }

        lastIndex = symbol.index
        currentSymbolStartedAt = observationTime
        symbolRunCount += 1
        state = symbolRunCount >= requiredSymbolRunCount
            ? .satisfied
            : .collecting(symbolRunCount: symbolRunCount)
        return state
    }
}

private struct SearchRectangle {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    var maximumX: Int { x + width - 1 }
    var maximumY: Int { y + height - 1 }

    func cellCenterX(column: Int) -> Int {
        min(maximumX, x + (2 * column + 1) * width / 8)
    }

    func cellCenterY(row: Int) -> Int {
        min(maximumY, y + (2 * row + 1) * height / 8)
    }
}

private struct RGBPixel {
    let red: Int
    let green: Int
    let blue: Int
    let alpha: Int
}

private enum PaletteColor: CaseIterable {
    case magenta
    case cyan
    case white
    case orange
    case blue
    case yellow

    var red: Int {
        switch self {
        case .magenta, .white, .orange, .yellow: return 255
        case .cyan, .blue: return 0
        }
    }

    var green: Int {
        switch self {
        case .cyan, .white, .yellow: return 255
        case .orange: return 128
        case .magenta, .blue: return 0
        }
    }

    var blue: Int {
        switch self {
        case .magenta, .cyan, .white, .blue: return 255
        case .orange, .yellow: return 0
        }
    }
}
