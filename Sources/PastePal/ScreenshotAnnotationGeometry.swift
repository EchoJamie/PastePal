import AppKit

extension ScreenshotAnnotation {
    var bounds: CGRect {
        switch self {
        case let .arrow(a, b, _, _): return Self.enclosing([a, b])
        case let .text(text, origin, _, fontSize):
            let size = (text as NSString).size(withAttributes: [.font: NSFont(name: "Helvetica-Bold", size: fontSize) ?? NSFont.boldSystemFont(ofSize: fontSize)])
            return CGRect(x: origin.x, y: origin.y - 4, width: max(1, size.width), height: max(fontSize + 4, size.height))
        case let .rectangle(rect, _, _), let .ellipse(rect, _, _), let .pixelate(rect, _), let .blur(rect, _): return rect
        case let .stroke(points, _, _): return Self.enclosing(points)
        }
    }
    var editHandles: [CGPoint] {
        guard resizable else { return [] }
        if case let .arrow(a, b, _, _) = self { return [a, b] }
        return [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.minX, y: bounds.maxY), CGPoint(x: bounds.maxX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.maxY)]
    }
    var fontSize: CGFloat? { if case let .text(_, _, _, size) = self { return size }; return nil }
    var obscureStyle: ScreenshotObscureStyle? {
        switch self { case .pixelate: return .pixelate; case .blur: return .blur; default: return nil }
    }
    var obscureStrength: ScreenshotObscureStrength? {
        switch self { case let .pixelate(_, value), let .blur(_, value): return value; default: return nil }
    }
    var resizable: Bool { if case .text = self { return false }; return true }
    var annotationColor: ScreenshotAnnotationColor? {
        switch self {
        case let .arrow(_, _, color, _), let .text(_, _, color, _), let .rectangle(_, color, _), let .ellipse(_, color, _), let .stroke(_, color, _): return color
        default: return nil
        }
    }
    var strokeWidth: CGFloat? {
        switch self {
        case let .arrow(_, _, _, width), let .rectangle(_, _, width), let .ellipse(_, _, width), let .stroke(_, _, width): return width
        default: return nil
        }
    }
    func styled(color: ScreenshotAnnotationColor? = nil, width: CGFloat? = nil) -> Self {
        switch self {
        case let .arrow(a, b, c, w): return .arrow(from: a, to: b, color: color ?? c, width: width ?? w)
        case let .text(t, p, c, size): return .text(t, at: p, color: color ?? c, size: size)
        case let .rectangle(r, c, w): return .rectangle(r, color: color ?? c, width: width ?? w)
        case let .ellipse(r, c, w): return .ellipse(r, color: color ?? c, width: width ?? w)
        case let .stroke(p, c, w): return .stroke(p, color: color ?? c, width: width ?? w)
        default: return self
        }
    }
    func remapped(to target: CGRect) -> Self {
        let original = bounds
        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: target.minX + (p.x - original.minX) * target.width / original.width,
                    y: target.minY + (p.y - original.minY) * target.height / original.height)
        }
        switch self {
        case let .arrow(a, b, c, w): return .arrow(from: point(a), to: point(b), color: c, width: w)
        case let .text(t, p, c, size): return .text(t, at: point(p), color: c, size: size)
        case let .rectangle(_, c, w): return .rectangle(target, color: c, width: w)
        case let .ellipse(_, c, w): return .ellipse(target, color: c, width: w)
        case let .pixelate(_, strength): return .pixelate(target, strength: strength)
        case let .blur(_, strength): return .blur(target, strength: strength)
        case let .stroke(points, c, w): return .stroke(points.map(point), color: c, width: w)
        }
    }
    func hit(at p: CGPoint) -> Bool {
        let tolerance = max(6, (strokeWidth ?? 3) / 2 + 3)
        guard bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p) else { return false }
        switch self {
        case let .arrow(a, b, _, _): return Self.distance(p, a, b) <= tolerance
        case let .stroke(points, _, _): return zip(points, points.dropFirst()).contains { Self.distance(p, $0.0, $0.1) <= tolerance }
        case .rectangle:
            return !bounds.insetBy(dx: tolerance, dy: tolerance).contains(p)
        case .ellipse:
            let rx = bounds.width / 2, ry = bounds.height / 2
            let r = hypot((p.x - bounds.midX) / rx, (p.y - bounds.midY) / ry)
            return abs(r - 1) <= tolerance / min(rx, ry)
        default: return true
        }
    }
    private static func enclosing(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let minX = points.map(\.x).min() ?? first.x, maxX = points.map(\.x).max() ?? first.x
        let minY = points.map(\.y).min() ?? first.y, maxY = points.map(\.y).max() ?? first.y
        return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
    }
    private static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        let t = length == 0 ? 0 : min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
        return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
    }
}
