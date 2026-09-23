import XCTest

final class PhysicalScreenImageOracleTests: XCTestCase {
    func testBlackOrWhiteStatusPixelsCannotPassAsVisibleVideo() throws {
        let black = try XCTUnwrap(snapshot(red: 0, green: 0, blue: 0))
        let whiteText = try XCTUnwrap(snapshot(
            red: 0,
            green: 0,
            blue: 0,
            whitePixelCount: 120
        ))
        XCTAssertEqual(
            PhysicalScreenImageEvaluator.evaluate([black, whiteText, black]),
            .noVisibleChallenge
        )
    }

    func testStaticColorCannotPassChangingChallenge() throws {
        let blue = try XCTUnwrap(snapshot(red: 20, green: 35, blue: 225))
        XCTAssertEqual(
            PhysicalScreenImageEvaluator.evaluate([blue, blue, blue]),
            .challengeDidNotChange
        )
    }

    func testChangingChallengeMustRemainVisibleAtEverySample() throws {
        let red = try XCTUnwrap(snapshot(red: 225, green: 20, blue: 35))
        let green = try XCTUnwrap(snapshot(red: 30, green: 225, blue: 25))
        let black = try XCTUnwrap(snapshot(red: 0, green: 0, blue: 0))
        XCTAssertEqual(
            PhysicalScreenImageEvaluator.evaluate([red, green, red]),
            .visibleChangingChallenge
        )
        XCTAssertEqual(
            PhysicalScreenImageEvaluator.evaluate([red, black, green]),
            .noVisibleChallenge,
            "One black flash must fail even when the other screenshots look healthy."
        )
    }

    func testMalformedAndInsufficientSamplesFailClosed() throws {
        XCTAssertNil(PhysicalScreenImageSnapshot(rgba8: [0, 0, 0], width: 1, height: 1))
        let red = try XCTUnwrap(snapshot(red: 225, green: 20, blue: 35))
        XCTAssertEqual(
            PhysicalScreenImageEvaluator.evaluate([red, red]),
            .insufficientSamples
        )
    }

    private func snapshot(
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        whitePixelCount: Int = 0
    ) -> PhysicalScreenImageSnapshot? {
        let pixelCount = 32 * 32
        var bytes = [UInt8](repeating: 0, count: pixelCount * 4)
        for pixel in 0..<pixelCount {
            let offset = pixel * 4
            let isWhite = pixel < whitePixelCount
            bytes[offset] = isWhite ? 255 : red
            bytes[offset + 1] = isWhite ? 255 : green
            bytes[offset + 2] = isWhite ? 255 : blue
            bytes[offset + 3] = 255
        }
        return PhysicalScreenImageSnapshot(rgba8: bytes, width: 32, height: 32)
    }
}
