import PastePalLocalization
import AppKit

enum ScreenshotBackdrop: Int, CaseIterable {
    case original, light, dark, gradient
    var title: String {
        switch self { case .original: return L("原图"); case .light: return L("浅色"); case .dark: return L("深色"); case .gradient: return L("渐变") }
    }
}
struct ScreenshotBeautyOptions {
    var backdrop: ScreenshotBackdrop = .gradient
    var padding = 48
    var cornerRadius = 16
    var shadow = true
}
enum ScreenshotBeautifier {
    static func render(_ image: CGImage, options: ScreenshotBeautyOptions) throws -> CGImage {
        if options.backdrop == .original { return image }
        let padding = max(0, min(128, options.padding))
        let width = image.width + padding * 2, height = image.height + padding * 2
        guard width <= 32_768, height <= 32_768, width * height <= 100_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScreenshotFailure.tooLarge }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        switch options.backdrop {
        case .original: break
        case .light: context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [0.94, 0.94, 0.94, 1])!); context.fill(bounds)
        case .dark: context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [0.12, 0.12, 0.12, 1])!); context.fill(bounds)
        case .gradient:
            let colors = [CGColor(red: 0.31, green: 0.46, blue: 0.89, alpha: 1), CGColor(red: 0.74, green: 0.55, blue: 0.89, alpha: 1)]
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
            }
        }
        let rect = CGRect(x: padding, y: padding, width: image.width, height: image.height)
        let radius = min(CGFloat(max(0, options.cornerRadius)), min(rect.width, rect.height) / 2)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if options.shadow {
            context.saveGState(); context.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: CGColor(gray: 0, alpha: 0.32))
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.addPath(path); context.fillPath(); context.restoreGState()
        }
        context.addPath(path); context.clip(); context.draw(image, in: rect)
        guard let output = context.makeImage() else { throw ScreenshotFailure.encoding }
        return output
    }
}
