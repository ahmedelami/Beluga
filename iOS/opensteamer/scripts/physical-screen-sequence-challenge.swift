import AppKit
import Foundation

// Build with the shared protocol source:
// `swiftc -parse-as-library PhysicalScreenSequenceProtocol.swift \
// physical-screen-sequence-challenge.swift -o <binary>`
// Run:   <binary> <heartbeat-path> <32-lowercase-hex-run-nonce>
//
// This accessory process creates a noninteractive, centered challenge on every display. The
// parent test runner owns its lifetime. A screenshot oracle must see the actual displayed cells
// on the iPhone; the heartbeat only identifies which symbol the Mac was asked to display.
// Exit 64 means invalid arguments; exit 65 means no display was available. Heartbeat write
// failure terminates the challenge instead of leaving an unverifiable static window behind.

private enum SequencePattern {
    static let holdSeconds: TimeInterval = 2.5
    static let cellInsetFraction: CGFloat = 0.04

    // Rows are numbered from the top, matching the orientation of an iPhone screenshot.
    static let topLeft = NSColor(calibratedRed: 1, green: 0, blue: 1, alpha: 1)
    static let topRight = NSColor(calibratedRed: 0, green: 1, blue: 1, alpha: 1)
    static let bottomLeft = NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 1)
    static let bottomRight = NSColor(calibratedRed: 1, green: 0.5, blue: 0, alpha: 1)
    static let zero = NSColor(calibratedRed: 0, green: 0, blue: 1, alpha: 1)
    static let one = NSColor(calibratedRed: 1, green: 1, blue: 0, alpha: 1)

    static func color(row: Int, column: Int, payload: UInt16) -> NSColor {
        switch (row, column) {
        case (0, 0): return topLeft
        case (0, 3): return topRight
        case (3, 0): return bottomLeft
        case (3, 3): return bottomRight
        default:
            let ordinal = (0..<row).reduce(0) { count, priorRow in
                count + (0..<PhysicalScreenSequenceProtocol.gridCount).filter {
                    !isCorner(row: priorRow, column: $0)
                }.count
            } + (0..<column).filter { !isCorner(row: row, column: $0) }.count
            return (payload & (1 << (11 - ordinal))) == 0 ? zero : one
        }
    }

    private static func isCorner(row: Int, column: Int) -> Bool {
        (row == 0 || row == 3) && (column == 0 || column == 3)
    }
}

@MainActor
private final class SequenceChallengeView: NSView {
    var payload: UInt16 = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()

        let cellWidth = bounds.width / CGFloat(PhysicalScreenSequenceProtocol.gridCount)
        let cellHeight = bounds.height / CGFloat(PhysicalScreenSequenceProtocol.gridCount)
        let insetX = cellWidth * SequencePattern.cellInsetFraction
        let insetY = cellHeight * SequencePattern.cellInsetFraction
        for row in 0..<PhysicalScreenSequenceProtocol.gridCount {
            for column in 0..<PhysicalScreenSequenceProtocol.gridCount {
                SequencePattern.color(row: row, column: column, payload: payload).setFill()
                NSRect(
                    x: CGFloat(column) * cellWidth + insetX,
                    y: bounds.maxY - CGFloat(row + 1) * cellHeight + insetY,
                    width: cellWidth - 2 * insetX,
                    height: cellHeight - 2 * insetY
                ).fill()
            }
        }
    }
}

@main
@MainActor
private struct PhysicalScreenSequenceChallenge {
    static func main() {
        guard CommandLine.arguments.count == 3,
              !CommandLine.arguments[1].isEmpty,
              PhysicalScreenSequenceProtocol.isValidNonce(CommandLine.arguments[2]) else {
            FileHandle.standardError.write(
                Data("usage: physical-screen-sequence-challenge heartbeat-path 32-lowercase-hex-nonce\n".utf8)
            )
            exit(64)
        }

        let heartbeatURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let nonce = CommandLine.arguments[2]
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        var windows: [NSWindow] = []
        var views: [SequenceChallengeView] = []
        for screen in NSScreen.screens {
            let size = NSSize(width: screen.frame.width * 0.72, height: screen.frame.height * 0.72)
            let frame = NSRect(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
            let window = NSWindow(
                contentRect: frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            let view = SequenceChallengeView(frame: NSRect(origin: .zero, size: size))
            window.contentView = view
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.ignoresMouseEvents = true
            window.isOpaque = true
            window.hasShadow = false
            window.orderFrontRegardless()
            windows.append(window)
            views.append(view)
        }
        guard !windows.isEmpty else { exit(65) }

        var counter: UInt64 = 0
        func publish() {
            let index = Int(counter % UInt64(PhysicalScreenSequenceProtocol.symbolCount))
            let payload = PhysicalScreenSequenceProtocol.payload(nonce: nonce, index: index)
            for view in views {
                view.payload = payload
                view.displayIfNeeded()
            }
            do {
                let heartbeat = "nonce=\(nonce)\nindex=\(index)\ncounter=\(counter)\n"
                try Data(heartbeat.utf8).write(to: heartbeatURL, options: .atomic)
            } catch {
                FileHandle.standardError.write(Data("heartbeat write failed: \(error)\n".utf8))
                application.terminate(nil)
            }
        }

        publish()
        Timer.scheduledTimer(withTimeInterval: SequencePattern.holdSeconds, repeats: true) { _ in
            MainActor.assumeIsolated {
                counter &+= 1
                publish()
            }
        }
        application.run()
        _ = windows
    }

}
