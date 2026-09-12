import Foundation

/// The gesture's displacement translates the selected window, regardless of where it began.
public enum FocusedWindowMoveGeometry {
    public static func proposedFrame(
        original: CGRect,
        start: CGPoint,
        end: CGPoint,
        displayBounds: CGRect
    ) -> CGRect? {
        let values = [original.minX, original.minY, original.width, original.height,
                      start.x, start.y, end.x, end.y,
                      displayBounds.minX, displayBounds.minY, displayBounds.width, displayBounds.height]
        guard values.allSatisfy(\.isFinite),
              original.size.width > 0, original.size.height > 0,
              displayBounds.size.width > 0, displayBounds.size.height > 0,
              displayBounds.width >= original.width, displayBounds.height >= original.height,
              original.minX >= displayBounds.minX, original.minY >= displayBounds.minY,
              original.maxX <= displayBounds.maxX, original.maxY <= displayBounds.maxY,
              start.x >= displayBounds.minX, start.x <= displayBounds.maxX,
              start.y >= displayBounds.minY, start.y <= displayBounds.maxY else { return nil }
        let x = original.minX + end.x - start.x
        let y = original.minY + end.y - start.y
        guard x.isFinite, y.isFinite else { return nil }
        return CGRect(
            origin: CGPoint(
                x: min(max(x, displayBounds.minX), displayBounds.maxX - original.width),
                y: min(max(y, displayBounds.minY), displayBounds.maxY - original.height)
            ),
            size: original.size
        )
    }
}
