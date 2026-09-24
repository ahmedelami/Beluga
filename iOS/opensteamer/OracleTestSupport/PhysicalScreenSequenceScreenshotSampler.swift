import UIKit

/// Converts a region of the final composited iPhone screenshot into the top-to-bottom RGBA rows
/// consumed by `PhysicalScreenSequenceFrame`.
enum PhysicalScreenSequenceScreenshotSampler {
    /// Returns the exact aspect-fit content rect inside the final composited video container.
    /// Sampling the container itself would include letterbox/pillarbox bars and can turn a healthy
    /// landscape stream into a false black-screen result on a portrait iPhone.
    static func aspectFitContentFrame(
        container: CGRect,
        sourceWidth: Int,
        sourceHeight: Int
    ) -> CGRect? {
        guard container.origin.x.isFinite,
              container.origin.y.isFinite,
              container.width.isFinite,
              container.height.isFinite,
              container.width > 0,
              container.height > 0,
              sourceWidth > 0,
              sourceHeight > 0 else {
            return nil
        }
        let width = CGFloat(sourceWidth)
        let height = CGFloat(sourceHeight)
        guard width.isFinite, height.isFinite else { return nil }
        let scale = min(container.width / width, container.height / height)
        guard scale.isFinite, scale > 0 else { return nil }
        let fittedWidth = width * scale
        let fittedHeight = height * scale
        guard fittedWidth.isFinite, fittedHeight.isFinite else { return nil }
        return CGRect(
            x: container.midX - fittedWidth / 2,
            y: container.midY - fittedHeight / 2,
            width: fittedWidth,
            height: fittedHeight
        )
    }

    static func sample(
        screenshot: UIImage,
        regionInPoints: CGRect,
        maximumDimension: Int = 360
    ) -> PhysicalScreenSequenceFrame? {
        guard maximumDimension >= 20 else { return nil }
        let image: UIImage
        if screenshot.imageOrientation == .up {
            image = screenshot
        } else {
            image = UIGraphicsImageRenderer(size: screenshot.size).image { _ in
                screenshot.draw(in: CGRect(origin: .zero, size: screenshot.size))
            }
        }
        guard let sourceImage = image.cgImage,
              image.size.width > 0,
              image.size.height > 0 else {
            return nil
        }

        let scaleX = CGFloat(sourceImage.width) / image.size.width
        let scaleY = CGFloat(sourceImage.height) / image.size.height
        let imageBounds = CGRect(
            x: 0,
            y: 0,
            width: sourceImage.width,
            height: sourceImage.height
        )
        let region = CGRect(
            x: regionInPoints.minX * scaleX,
            y: regionInPoints.minY * scaleY,
            width: regionInPoints.width * scaleX,
            height: regionInPoints.height * scaleY
        ).integral.intersection(imageBounds)
        guard region.width > 1,
              region.height > 1,
              let cropped = sourceImage.cropping(to: region) else {
            return nil
        }

        let outputScale = min(
            min(
                CGFloat(maximumDimension) / region.width,
                CGFloat(maximumDimension) / region.height
            ),
            1
        )
        let width = Int((region.width * outputScale).rounded())
        let height = Int((region.height * outputScale).rounded())
        guard width >= 20, height >= 20 else { return nil }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .high
            // `CGImage.cropping(to:)` and the bitmap rows already share top-to-bottom order.
            // Flipping here would invert the finder corners and make genuine pixels fail.
            context.draw(
                cropped,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            return true
        }
        guard rendered else { return nil }
        return PhysicalScreenSequenceFrame(rgba8: bytes, width: width, height: height)
    }
}
