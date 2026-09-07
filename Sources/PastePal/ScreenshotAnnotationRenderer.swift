import AppKit
import CoreText

enum ScreenshotAnnotationRenderer {
    // 调用方负责全局屏幕点坐标到目标像素的变换与选区裁剪。
    static func draw(annotations: [ScreenshotAnnotation], in context: CGContext, obscurer: ScreenshotObscureRenderer? = nil) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(1)
        context.setBlendMode(.normal)
        context.setLineWidth(3)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for annotation in annotations {
            switch annotation {
            case let .arrow(from, to, color, width):
                context.setLineWidth(width)
                let length = hypot(to.x - from.x, to.y - from.y)
                guard length.isFinite, length >= 2 else { continue }
                context.setStrokeColor(color.cgColor)
                let dx = (to.x - from.x) / length, dy = (to.y - from.y) / length
                let head = min(max(10, width * 4), length * 0.45)
                context.move(to: from)
                context.addLine(to: to)
                context.move(to: CGPoint(x: to.x - dx * head - dy * head * 0.55,
                                        y: to.y - dy * head + dx * head * 0.55))
                context.addLine(to: to)
                context.addLine(to: CGPoint(x: to.x - dx * head + dy * head * 0.55,
                                           y: to.y - dy * head - dx * head * 0.55))
                context.strokePath()
            case let .text(text, origin, color, size):
                guard origin.x.isFinite, origin.y.isFinite else { continue }
                let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor
                ]
                context.textMatrix = .identity
                for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                    let attributed = NSAttributedString(string: line, attributes: attributes)
                    context.textPosition = CGPoint(x: origin.x, y: origin.y - CGFloat(index) * (size + 5))
                    CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
                }
            case let .rectangle(rect, color, width), let .ellipse(rect, color, width):
                context.setLineWidth(width)
                guard !rect.isEmpty, rect.minX.isFinite, rect.minY.isFinite,
                      rect.maxX.isFinite, rect.maxY.isFinite else { continue }
                context.setStrokeColor(color.cgColor)
                if case .ellipse = annotation { context.strokeEllipse(in: rect) }
                else { context.stroke(rect) }
            case let .stroke(points, color, width):
                guard points.count > 1, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { continue }
                context.setLineWidth(width); context.setStrokeColor(color.cgColor)
                context.addLines(between: points); context.strokePath()
            case let .pixelate(rect, strength):
                obscurer?.draw(rect: rect, pixelate: true, strength: strength, in: context)
            case let .blur(rect, strength):
                obscurer?.draw(rect: rect, pixelate: false, strength: strength, in: context)

            }
        }
    }
}
