import AppKit
import CoreImage

final class ScreenshotObscureRenderer {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private let image: CGImage
    private let bounds: CGRect
    private let cache = NSCache<NSString, CGImage>()
    init(image: CGImage, bounds: CGRect) {
        self.image = image; self.bounds = bounds
        cache.totalCostLimit = 24 * 1024 * 1024
    }
    func draw(rect: CGRect, pixelate: Bool, strength: ScreenshotObscureStrength = .medium, in context: CGContext) {
        let visible = rect.intersection(bounds)
        guard !visible.isEmpty, !visible.isNull, bounds.width > 0, bounds.height > 0 else { return }
        let sx = CGFloat(image.width) / bounds.width, sy = CGFloat(image.height) / bounds.height
        let pixels = CGRect(x: (visible.minX - bounds.minX) * sx, y: (bounds.maxY - visible.maxY) * sy,
                            width: visible.width * sx, height: visible.height * sy).integral
        let key = "\(pixels)-\(pixelate)-\(strength.rawValue)" as NSString
        var result = cache.object(forKey: key)
        if result == nil, let crop = image.cropping(to: pixels) {
            let input = CIImage(cgImage: crop)
            let filtered = input.clampedToExtent().applyingFilter(pixelate ? "CIPixellate" : "CIGaussianBlur",
                parameters: pixelate ? [kCIInputScaleKey: strength.rawValue * sx] : [kCIInputRadiusKey: strength.rawValue * 0.75 * sx])
            result = Self.context.createCGImage(filtered, from: input.extent)
            if let result { cache.setObject(result, forKey: key, cost: result.bytesPerRow * result.height) }
        }
        guard let result else {
            context.saveGState(); context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(visible); context.restoreGState()
            return
        }
        let destination = CGRect(x: bounds.minX + pixels.minX / sx, y: bounds.maxY - pixels.maxY / sy,
                                 width: pixels.width / sx, height: pixels.height / sy)
        context.saveGState(); context.clip(to: visible); context.interpolationQuality = .none
        context.draw(result, in: destination); context.restoreGState()
    }
}
