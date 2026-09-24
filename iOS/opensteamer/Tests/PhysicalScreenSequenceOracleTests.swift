import UIKit
import XCTest

#if SWIFT_PACKAGE
@testable import PhysicalOracle
#endif

final class PhysicalScreenSequenceOracleTests: XCTestCase {
    private let nonce = "0123456789abcdef0123456789abcdef"
    private let staleNonce = "fedcba9876543210fedcba9876543210"

    // Independent known-answer vectors for: two index bits followed by the first ten SHA-256 bits.
    private let payloads: [UInt16] = [0x1e7, 0x638, 0x901, 0xc33]
    private let stalePayloads: [UInt16] = [0x37e, 0x4de, 0xbe1, 0xd22]

    func testDecodesAllFourNonceBoundSymbolsAcrossOffsetsScalesAndColorDrift() throws {
        for index in 0..<4 {
            let image = renderChallenge(
                payload: payloads[index],
                width: 220 + index * 7,
                height: 164 + index * 5,
                grid: PixelRectangle(
                    x: 35 + index,
                    y: 25 + index,
                    width: 151 + index * 3,
                    height: 113 + index * 2
                ),
                colorDrift: index.isMultiple(of: 2)
            )
            let frame = try XCTUnwrap(image.frame())
            XCTAssertEqual(
                frame.decode(nonce: nonce),
                try symbol(index),
                "Failed to decode challenge index \(index)."
            )
        }
    }

    func testDecodesPaddedRowsAndAChallengeThatNearlyFillsTheCrop() throws {
        let image = renderChallenge(
            payload: payloads[3],
            width: 150,
            height: 120,
            bytesPerRow: 150 * 4 + 20,
            grid: PixelRectangle(x: 9, y: 7, width: 132, height: 106),
            colorDrift: true
        )
        XCTAssertEqual(
            try XCTUnwrap(image.frame()).decode(nonce: nonce),
            try symbol(3)
        )
    }

    func testKnownAnswerPayloadBitsAreReadRowMajorAndMSBFirst() throws {
        // Flipping each bit in turn must stop the frame from decoding as the original symbol.
        for bit in 0..<12 {
            let mutatedPayload = payloads[0] ^ (UInt16(1) << UInt16(bit))
            let image = renderChallenge(
                payload: mutatedPayload,
                width: 112,
                height: 88,
                grid: PixelRectangle(x: 16, y: 12, width: 80, height: 64)
            )
            XCTAssertNil(
                try XCTUnwrap(image.frame()).decode(nonce: nonce),
                "Bit \(bit) was not bound into the decoded payload."
            )
        }
    }

    func testBlackVividStaticAndMalformedGridImagesDoNotDecode() throws {
        let black = RenderedImage.solid(width: 96, height: 72, color: .black)
        let vivid = RenderedImage.solid(width: 96, height: 72, color: .yellow)
        let noGutters = renderChallenge(
            payload: payloads[1],
            width: 112,
            height: 88,
            grid: PixelRectangle(x: 16, y: 12, width: 80, height: 64),
            cellInsetPercent: 0
        )
        let wrongPayload = renderChallenge(
            payload: payloads[1] ^ 0x008,
            width: 112,
            height: 88,
            grid: PixelRectangle(x: 16, y: 12, width: 80, height: 64)
        )

        for image in [black, vivid, noGutters, wrongPayload] {
            XCTAssertNil(try XCTUnwrap(image.frame()).decode(nonce: nonce))
        }
    }

    func testStaleOtherNonceCannotDecodeOrAdvanceStrictTracker() throws {
        let staleImage = renderChallenge(
            payload: stalePayloads[2],
            width: 128,
            height: 96,
            grid: PixelRectangle(x: 18, y: 14, width: 92, height: 68)
        )
        let staleFrame = try XCTUnwrap(staleImage.frame())
        XCTAssertNil(staleFrame.decode(nonce: nonce))
        XCTAssertEqual(staleFrame.decode(nonce: staleNonce), try staleSymbol(2))

        var tracker = try XCTUnwrap(PhysicalScreenSequenceTracker(nonce: nonce))
        XCTAssertEqual(tracker.observe(staleFrame), .rejected)
    }

    func testWrongOrientationAndMirroringCannotDecode() throws {
        let image = renderChallenge(
            payload: payloads[1],
            width: 128,
            height: 96,
            grid: PixelRectangle(x: 18, y: 14, width: 92, height: 68)
        )
        XCTAssertNil(try XCTUnwrap(image.mirroredHorizontally().frame()).decode(nonce: nonce))
        XCTAssertNil(try XCTUnwrap(image.rotated180Degrees().frame()).decode(nonce: nonce))
        XCTAssertNil(try XCTUnwrap(image.rotated90DegreesClockwise().frame()).decode(nonce: nonce))
    }

    func testFinalScreenshotCropAndRGBAConversionPreserveFinderOrientation() throws {
        let source = renderChallenge(
            payload: payloads[2],
            width: 180,
            height: 140,
            grid: PixelRectangle(x: 25, y: 19, width: 130, height: 102),
            colorDrift: true
        )
        let screenshot = try XCTUnwrap(source.uiImage())
        let sampled = try XCTUnwrap(
            PhysicalScreenSequenceScreenshotSampler.sample(
                screenshot: screenshot,
                regionInPoints: CGRect(x: 0, y: 0, width: 180, height: 140),
                maximumDimension: 120
            )
        )
        XCTAssertEqual(sampled.decode(nonce: nonce), try symbol(2))
    }

    func testAspectFitContentFrameExcludesLandscapeLetterboxing() throws {
        let result = try XCTUnwrap(
            PhysicalScreenSequenceScreenshotSampler.aspectFitContentFrame(
                container: CGRect(x: 0, y: 0, width: 390, height: 844),
                sourceWidth: 1920,
                sourceHeight: 1080
            )
        )
        XCTAssertEqual(result.minX, 0, accuracy: 0.001)
        XCTAssertEqual(result.width, 390, accuracy: 0.001)
        XCTAssertEqual(result.height, 219.375, accuracy: 0.001)
        XCTAssertEqual(result.midY, 422, accuracy: 0.001)
    }

    func testAspectFitContentFrameExcludesPortraitPillarboxingAndPreservesOrigin() throws {
        let result = try XCTUnwrap(
            PhysicalScreenSequenceScreenshotSampler.aspectFitContentFrame(
                container: CGRect(x: 17, y: 29, width: 900, height: 400),
                sourceWidth: 1080,
                sourceHeight: 1920
            )
        )
        XCTAssertEqual(result.height, 400, accuracy: 0.001)
        XCTAssertEqual(result.width, 225, accuracy: 0.001)
        XCTAssertEqual(result.midX, 467, accuracy: 0.001)
        XCTAssertEqual(result.minY, 29, accuracy: 0.001)
    }

    func testAspectFitContentFrameExactFitAndInvalidInputsFailClosed() throws {
        XCTAssertEqual(
            PhysicalScreenSequenceScreenshotSampler.aspectFitContentFrame(
                container: CGRect(x: 7, y: 11, width: 320, height: 180),
                sourceWidth: 1280,
                sourceHeight: 720
            ),
            CGRect(x: 7, y: 11, width: 320, height: 180)
        )
        for invalid in [
            (CGRect(x: 0, y: 0, width: 0, height: 100), 1920, 1080),
            (CGRect(x: 0, y: 0, width: 100, height: 100), 0, 1080),
            (CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100), 1920, 1080),
        ] {
            XCTAssertNil(
                PhysicalScreenSequenceScreenshotSampler.aspectFitContentFrame(
                    container: invalid.0,
                    sourceWidth: invalid.1,
                    sourceHeight: invalid.2
                )
            )
        }
    }

    func testCroppedGridCannotBeReinterpretedAsACompleteChallenge() throws {
        let image = renderChallenge(
            payload: payloads[2],
            width: 168,
            height: 132,
            grid: PixelRectangle(x: 20, y: 16, width: 128, height: 100)
        )
        // This retains colorful portions of all 16 cells but removes every outer grid gutter.
        let cropped = try XCTUnwrap(
            image.cropped(to: PixelRectangle(x: 22, y: 18, width: 124, height: 96))
        )
        XCTAssertNil(try XCTUnwrap(cropped.frame()).decode(nonce: nonce))
    }

    func testMalformedFrameStorageFailsClosed() {
        XCTAssertNil(PhysicalScreenSequenceFrame(rgba8: [], width: 0, height: 1))
        XCTAssertNil(PhysicalScreenSequenceFrame(rgba8: [0, 0, 0], width: 1, height: 1))
        XCTAssertNil(
            PhysicalScreenSequenceFrame(
                rgba8: [UInt8](repeating: 0, count: 16),
                width: 2,
                height: 2,
                bytesPerRow: 7
            )
        )
        XCTAssertNil(
            PhysicalScreenSequenceFrame(
                rgba8: [UInt8](repeating: 0, count: 17),
                width: 2,
                height: 2,
                bytesPerRow: 8
            )
        )
        XCTAssertNil(
            PhysicalScreenSequenceFrame(
                rgba8: [],
                width: Int.max,
                height: 2
            )
        )
    }

    func testTrackerRequiresThreeDistinctOrderedSymbolsAndAllowsHeldFrames() throws {
        var tracker = try XCTUnwrap(PhysicalScreenSequenceTracker(nonce: nonce))
        XCTAssertEqual(tracker.observe(try symbol(0)), .collecting(distinctSymbolCount: 1))
        XCTAssertEqual(tracker.observe(try symbol(0)), .collecting(distinctSymbolCount: 1))
        XCTAssertEqual(tracker.observe(try symbol(1)), .collecting(distinctSymbolCount: 2))
        XCTAssertEqual(tracker.observe(try symbol(1)), .collecting(distinctSymbolCount: 2))
        XCTAssertEqual(tracker.observe(try symbol(2)), .satisfied)
    }

    func testTrackerAcceptsOrderedWraparoundAndConfigurableFourSymbolProof() throws {
        var wrapped = try XCTUnwrap(PhysicalScreenSequenceTracker(nonce: nonce))
        XCTAssertEqual(wrapped.observe(try symbol(2)), .collecting(distinctSymbolCount: 1))
        XCTAssertEqual(wrapped.observe(try symbol(3)), .collecting(distinctSymbolCount: 2))
        XCTAssertEqual(wrapped.observe(try symbol(0)), .satisfied)

        var allFour = try XCTUnwrap(
            PhysicalScreenSequenceTracker(nonce: nonce, requiredDistinctSymbolCount: 4)
        )
        for index in 0..<3 {
            XCTAssertNotEqual(allFour.observe(try symbol(index)), .satisfied)
        }
        XCTAssertEqual(allFour.observe(try symbol(3)), .satisfied)
    }

    func testStaticSkippedReversedAndMixedNonceSequencesCannotPass() throws {
        var staticTracker = try XCTUnwrap(PhysicalScreenSequenceTracker(nonce: nonce))
        for _ in 0..<8 {
            _ = staticTracker.observe(try symbol(1))
        }
        XCTAssertEqual(staticTracker.state, .collecting(distinctSymbolCount: 1))

        var skipped = try XCTUnwrap(PhysicalScreenSequenceTracker(nonce: nonce))
        _ = skipped.observe(try symbol(0))
        XCTAssertEqual(skipped.observe(try symbol(2)), .rejected)

        var reversed = try XCTUnwrap(PhysicalScreenSequenceTracker(nonce: nonce))
        _ = reversed.observe(try symbol(2))
        XCTAssertEqual(reversed.observe(try symbol(1)), .rejected)

        var mixedNonce = try XCTUnwrap(PhysicalScreenSequenceTracker(nonce: nonce))
        _ = mixedNonce.observe(try symbol(0))
        XCTAssertEqual(mixedNonce.observe(try staleSymbol(1)), .rejected)
    }

    func testTrackerContinuesValidatingAfterSatisfied() throws {
        var tracker = try XCTUnwrap(PhysicalScreenSequenceTracker(nonce: nonce))
        for index in 0...2 {
            _ = tracker.observe(try symbol(index))
        }
        XCTAssertEqual(tracker.state, .satisfied)
        XCTAssertEqual(tracker.observe(try symbol(0)), .rejected)

        var wrongNonce = try XCTUnwrap(PhysicalScreenSequenceTracker(nonce: nonce))
        for index in 0...2 {
            _ = wrongNonce.observe(try symbol(index))
        }
        XCTAssertEqual(wrongNonce.observe(try staleSymbol(3)), .rejected)
    }

    func testContinuityTrackerRequiresWrapBeyondFirstCycle() throws {
        var tracker = try XCTUnwrap(
            PhysicalScreenSequenceContinuityTracker(
                nonce: nonce,
                maximumSameSymbolHoldDuration: 4.25
            )
        )
        for index in 0..<4 {
            XCTAssertEqual(
                tracker.observe(try symbol(index), at: Double(index) * 2.5),
                .collecting(symbolRunCount: index + 1)
            )
        }
        XCTAssertEqual(tracker.observe(try symbol(0), at: 10), .satisfied)
        XCTAssertEqual(tracker.observe(try symbol(0), at: 12.5), .satisfied)
        XCTAssertEqual(tracker.maximumObservedSameSymbolHoldDuration, 2.5)
    }

    func testContinuityTrackerRejectsFreezeAfterCompleteCycle() throws {
        var tracker = try XCTUnwrap(
            PhysicalScreenSequenceContinuityTracker(
                nonce: nonce,
                maximumSameSymbolHoldDuration: 4.25
            )
        )
        for index in 0..<4 {
            _ = tracker.observe(try symbol(index), at: Double(index) * 2.5)
        }
        XCTAssertEqual(
            tracker.observe(try symbol(3), at: 11.76),
            .rejected,
            "A valid first cycle must not hide a frozen final symbol."
        )
    }

    func testContinuityTrackerRejectsWrongNonceNonMonotonicTimeAndBadConfiguration() throws {
        XCTAssertNil(
            PhysicalScreenSequenceContinuityTracker(
                nonce: nonce,
                requiredSymbolRunCount: 4,
                maximumSameSymbolHoldDuration: 4.25
            )
        )
        XCTAssertNil(
            PhysicalScreenSequenceContinuityTracker(
                nonce: nonce,
                maximumSameSymbolHoldDuration: .infinity
            )
        )

        var wrongNonce = try XCTUnwrap(
            PhysicalScreenSequenceContinuityTracker(
                nonce: nonce,
                maximumSameSymbolHoldDuration: 4.25
            )
        )
        XCTAssertEqual(wrongNonce.observe(try staleSymbol(0), at: 0), .rejected)

        var regressedTime = try XCTUnwrap(
            PhysicalScreenSequenceContinuityTracker(
                nonce: nonce,
                maximumSameSymbolHoldDuration: 4.25
            )
        )
        _ = regressedTime.observe(try symbol(0), at: 2)
        XCTAssertEqual(regressedTime.observe(try symbol(0), at: 1), .rejected)
    }

    func testSatisfiedFourSymbolProofRejectsStartsClearThenBlackTail() throws {
        var tracker = try XCTUnwrap(
            PhysicalScreenSequenceTracker(
                nonce: nonce,
                requiredDistinctSymbolCount: 4,
                maximumConsecutiveUndecodableFrames: 1
            )
        )
        for index in 0..<4 {
            _ = tracker.observe(try symbol(index))
        }
        XCTAssertEqual(tracker.state, .satisfied)
        XCTAssertEqual(tracker.observeUndecodableFrame(), .satisfied)
        XCTAssertEqual(
            tracker.observeUndecodableFrame(),
            .rejected,
            "A satisfied prefix must not hide a sustained black tail."
        )
    }

    func testBoundedUndecodableTransitionFramesAreExplicitAndFinite() throws {
        var tolerant = try XCTUnwrap(
            PhysicalScreenSequenceTracker(
                nonce: nonce,
                maximumConsecutiveUndecodableFrames: 1
            )
        )
        XCTAssertEqual(tolerant.observe(try symbol(0)), .collecting(distinctSymbolCount: 1))
        XCTAssertEqual(tolerant.observeUndecodableFrame(), .collecting(distinctSymbolCount: 1))
        XCTAssertEqual(tolerant.observe(try symbol(1)), .collecting(distinctSymbolCount: 2))
        XCTAssertEqual(tolerant.observeUndecodableFrame(), .collecting(distinctSymbolCount: 2))
        XCTAssertEqual(tolerant.observe(try symbol(2)), .satisfied)

        var overBudget = try XCTUnwrap(
            PhysicalScreenSequenceTracker(
                nonce: nonce,
                maximumConsecutiveUndecodableFrames: 1
            )
        )
        _ = overBudget.observe(try symbol(0))
        _ = overBudget.observeUndecodableFrame()
        XCTAssertEqual(overBudget.observeUndecodableFrame(), .rejected)
        XCTAssertEqual(overBudget.observe(try symbol(1)), .rejected)
    }

    func testFrameObservationUsesTheSameBoundedGapPolicy() throws {
        let frame0 = try XCTUnwrap(
            renderChallenge(
                payload: payloads[0],
                width: 104,
                height: 80,
                grid: PixelRectangle(x: 14, y: 10, width: 76, height: 60)
            ).frame()
        )
        let frame1 = try XCTUnwrap(
            renderChallenge(
                payload: payloads[1],
                width: 104,
                height: 80,
                grid: PixelRectangle(x: 14, y: 10, width: 76, height: 60)
            ).frame()
        )
        let frame2 = try XCTUnwrap(
            renderChallenge(
                payload: payloads[2],
                width: 104,
                height: 80,
                grid: PixelRectangle(x: 14, y: 10, width: 76, height: 60)
            ).frame()
        )
        let black = try XCTUnwrap(RenderedImage.solid(width: 104, height: 80, color: .black).frame())

        var tracker = try XCTUnwrap(
            PhysicalScreenSequenceTracker(
                nonce: nonce,
                maximumConsecutiveUndecodableFrames: 1
            )
        )
        _ = tracker.observe(frame0)
        _ = tracker.observe(black)
        _ = tracker.observe(frame1)
        XCTAssertEqual(tracker.observe(frame2), .satisfied)
    }

    func testInvalidNonceSymbolAndTrackerConfigurationAreRejected() {
        XCTAssertNil(PhysicalScreenSequenceSymbol(nonce: "ABCDEF", index: 0))
        XCTAssertNil(PhysicalScreenSequenceSymbol(nonce: nonce, index: -1))
        XCTAssertNil(PhysicalScreenSequenceSymbol(nonce: nonce, index: 4))
        XCTAssertNil(PhysicalScreenSequenceTracker(nonce: "not-a-valid-nonce"))
        XCTAssertNil(
            PhysicalScreenSequenceTracker(nonce: nonce, requiredDistinctSymbolCount: 2)
        )
        XCTAssertNil(
            PhysicalScreenSequenceTracker(nonce: nonce, requiredDistinctSymbolCount: 5)
        )
        XCTAssertNil(
            PhysicalScreenSequenceTracker(
                nonce: nonce,
                maximumConsecutiveUndecodableFrames: -1
            )
        )
    }

    func testBlackFrameWorstCaseSearchRemainsCheapEnoughForPhysicalSampling() throws {
        let black = try XCTUnwrap(
            RenderedImage.solid(width: 240, height: 180, color: .black).frame()
        )
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<20 {
            XCTAssertNil(black.decode(nonce: nonce))
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertLessThan(
            elapsed,
            1.0,
            "A worst-case miss must average under 50 ms on the unit-test host."
        )
    }

    private func symbol(_ index: Int) throws -> PhysicalScreenSequenceSymbol {
        try XCTUnwrap(PhysicalScreenSequenceSymbol(nonce: nonce, index: index))
    }

    private func staleSymbol(_ index: Int) throws -> PhysicalScreenSequenceSymbol {
        try XCTUnwrap(PhysicalScreenSequenceSymbol(nonce: staleNonce, index: index))
    }

    private func renderChallenge(
        payload: UInt16,
        width: Int,
        height: Int,
        bytesPerRow: Int? = nil,
        grid: PixelRectangle,
        colorDrift: Bool = false,
        cellInsetPercent: Int = 4
    ) -> RenderedImage {
        var image = RenderedImage(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow ?? width * 4,
            background: .black
        )
        var ordinal = 0
        for row in 0..<4 {
            for column in 0..<4 {
                let color: TestColor
                switch (row, column) {
                case (0, 0): color = .magenta
                case (0, 3): color = .cyan
                case (3, 0): color = .white
                case (3, 3): color = .orange
                default:
                    color = payload & (UInt16(1) << UInt16(11 - ordinal)) == 0
                        ? .blue
                        : .yellow
                    ordinal += 1
                }

                let cellMinimumX = grid.x + column * grid.width / 4
                let cellMaximumX = grid.x + (column + 1) * grid.width / 4
                let cellMinimumY = grid.y + row * grid.height / 4
                let cellMaximumY = grid.y + (row + 1) * grid.height / 4
                let insetX = cellInsetPercent == 0
                    ? 0
                    : max(1, (cellMaximumX - cellMinimumX) * cellInsetPercent / 100)
                let insetY = cellInsetPercent == 0
                    ? 0
                    : max(1, (cellMaximumY - cellMinimumY) * cellInsetPercent / 100)
                image.fill(
                    PixelRectangle(
                        x: cellMinimumX + insetX,
                        y: cellMinimumY + insetY,
                        width: cellMaximumX - cellMinimumX - 2 * insetX,
                        height: cellMaximumY - cellMinimumY - 2 * insetY
                    ),
                    color: colorDrift ? color.withVideoDrift : color
                )
            }
        }
        return image
    }
}

private struct PixelRectangle {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

private struct TestColor: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    static let black = TestColor(red: 8, green: 10, blue: 12, alpha: 255)
    static let magenta = TestColor(red: 255, green: 0, blue: 255, alpha: 255)
    static let cyan = TestColor(red: 0, green: 255, blue: 255, alpha: 255)
    static let white = TestColor(red: 255, green: 255, blue: 255, alpha: 255)
    static let orange = TestColor(red: 255, green: 128, blue: 0, alpha: 255)
    static let blue = TestColor(red: 0, green: 0, blue: 255, alpha: 255)
    static let yellow = TestColor(red: 255, green: 255, blue: 0, alpha: 255)

    var withVideoDrift: TestColor {
        func drift(_ channel: UInt8, floor: Int) -> UInt8 {
            UInt8(min(255, Int(channel) * 82 / 100 + floor))
        }
        return TestColor(
            red: drift(red, floor: 11),
            green: drift(green, floor: 8),
            blue: drift(blue, floor: 13),
            alpha: alpha
        )
    }
}

private struct RenderedImage {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    private(set) var bytes: [UInt8]

    init(width: Int, height: Int, bytesPerRow: Int, background: TestColor) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        fill(PixelRectangle(x: 0, y: 0, width: width, height: height), color: background)
    }

    static func solid(width: Int, height: Int, color: TestColor) -> RenderedImage {
        RenderedImage(
            width: width,
            height: height,
            bytesPerRow: width * 4,
            background: color
        )
    }

    func frame() -> PhysicalScreenSequenceFrame? {
        PhysicalScreenSequenceFrame(
            rgba8: bytes,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        )
    }

    func uiImage() -> UIImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.union(
                    CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            return nil
        }
        return UIImage(cgImage: image, scale: 1, orientation: .up)
    }

    mutating func fill(_ rectangle: PixelRectangle, color: TestColor) {
        guard rectangle.width > 0, rectangle.height > 0 else { return }
        for y in max(0, rectangle.y)..<min(height, rectangle.y + rectangle.height) {
            for x in max(0, rectangle.x)..<min(width, rectangle.x + rectangle.width) {
                setPixel(x: x, y: y, color: color)
            }
        }
    }

    func mirroredHorizontally() -> RenderedImage {
        transformed(width: width, height: height) { x, y in
            (width - 1 - x, y)
        }
    }

    func rotated180Degrees() -> RenderedImage {
        transformed(width: width, height: height) { x, y in
            (width - 1 - x, height - 1 - y)
        }
    }

    func rotated90DegreesClockwise() -> RenderedImage {
        var result = RenderedImage(
            width: height,
            height: width,
            bytesPerRow: height * 4,
            background: .black
        )
        for y in 0..<height {
            for x in 0..<width {
                result.setPixel(x: height - 1 - y, y: x, color: pixel(x: x, y: y))
            }
        }
        return result
    }

    func cropped(to rectangle: PixelRectangle) -> RenderedImage? {
        guard rectangle.x >= 0,
              rectangle.y >= 0,
              rectangle.width > 0,
              rectangle.height > 0,
              rectangle.x + rectangle.width <= width,
              rectangle.y + rectangle.height <= height else {
            return nil
        }
        var result = RenderedImage(
            width: rectangle.width,
            height: rectangle.height,
            bytesPerRow: rectangle.width * 4,
            background: .black
        )
        for y in 0..<rectangle.height {
            for x in 0..<rectangle.width {
                result.setPixel(
                    x: x,
                    y: y,
                    color: pixel(x: rectangle.x + x, y: rectangle.y + y)
                )
            }
        }
        return result
    }

    private func transformed(
        width transformedWidth: Int,
        height transformedHeight: Int,
        source: (_ x: Int, _ y: Int) -> (Int, Int)
    ) -> RenderedImage {
        var result = RenderedImage(
            width: transformedWidth,
            height: transformedHeight,
            bytesPerRow: transformedWidth * 4,
            background: .black
        )
        for y in 0..<transformedHeight {
            for x in 0..<transformedWidth {
                let sourceCoordinate = source(x, y)
                result.setPixel(
                    x: x,
                    y: y,
                    color: pixel(x: sourceCoordinate.0, y: sourceCoordinate.1)
                )
            }
        }
        return result
    }

    private func pixel(x: Int, y: Int) -> TestColor {
        let offset = y * bytesPerRow + x * 4
        return TestColor(
            red: bytes[offset],
            green: bytes[offset + 1],
            blue: bytes[offset + 2],
            alpha: bytes[offset + 3]
        )
    }

    private mutating func setPixel(x: Int, y: Int, color: TestColor) {
        let offset = y * bytesPerRow + x * 4
        bytes[offset] = color.red
        bytes[offset + 1] = color.green
        bytes[offset + 2] = color.blue
        bytes[offset + 3] = color.alpha
    }
}
