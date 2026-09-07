import PastePalLocalization
import Foundation
import CoreGraphics

enum ScreenshotAnnotationColor: String, CaseIterable {
    case red, yellow, blue, green, white, black

    var title: String {
        switch self {
        case .red: return L("红色")
        case .yellow: return L("黄色")
        case .blue: return L("蓝色")
        case .green: return L("绿色")
        case .white: return L("白色")
        case .black: return L("黑色")
        }
    }
    var cgColor: CGColor {
        let components: [CGFloat]
        switch self {
        case .red: components = [1, 0.18, 0.16, 1]
        case .yellow: components = [1, 0.8, 0, 1]
        case .blue: components = [0.1, 0.45, 1, 1]
        case .green: components = [0.15, 0.75, 0.3, 1]
        case .white: components = [1, 1, 1, 1]
        case .black: components = [0, 0, 0, 1]
        }
        return CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: components)!
    }
}

enum ScreenshotStrokeWidth: CGFloat, CaseIterable {
    case thin = 2, medium = 3, thick = 6
    var title: String { self == .thin ? L("细") : (self == .medium ? L("中") : L("粗")) }
}

enum ScreenshotObscureStyle: Int, CaseIterable {
    case pixelate, blur
    var title: String { self == .pixelate ? L("马赛克") : L("模糊") }
}
enum ScreenshotObscureStrength: CGFloat, CaseIterable {
    case light = 6, medium = 12, strong = 24
    var title: String { self == .light ? L("弱") : (self == .medium ? L("中") : L("强")) }
}
enum ScreenshotFontSize: CGFloat, CaseIterable {
    case small = 16, medium = 20, large = 28
    var title: String { "\(Int(rawValue))" }
}

enum ScreenshotAnnotation {
    case arrow(from: CGPoint, to: CGPoint, color: ScreenshotAnnotationColor = .red, width: CGFloat = 3)
    case text(String, at: CGPoint, color: ScreenshotAnnotationColor = .red, size: CGFloat = 20)
    case rectangle(CGRect, color: ScreenshotAnnotationColor = .red, width: CGFloat = 3)
    case ellipse(CGRect, color: ScreenshotAnnotationColor = .red, width: CGFloat = 3)
    case stroke([CGPoint], color: ScreenshotAnnotationColor = .red, width: CGFloat = 3)
    case pixelate(CGRect, strength: ScreenshotObscureStrength = .medium)
    case blur(CGRect, strength: ScreenshotObscureStrength = .medium)
}

struct ScreenshotAnnotationModel {
    enum Tool: Int, CaseIterable {
        case edit, arrow, rectangle, ellipse, pen, text, obscure
        var usesColor: Bool { self != .edit && self != .obscure }
        var usesStroke: Bool { self == .arrow || self == .rectangle || self == .ellipse || self == .pen }
        var title: String {
            switch self {
            case .edit: return L("选择标注")
            case .obscure: return L("遮挡")
            case .arrow: return L("箭头")
            case .text: return L("文字")
            case .rectangle: return L("矩形标注")
            case .ellipse: return L("椭圆")
            case .pen: return L("画笔")
            }
        }
        var symbol: String {
            switch self {
            case .edit: return "cursorarrow"
            case .obscure: return "square.grid.3x3.fill"
            case .arrow: return "arrow.up.right"
            case .text: return "textformat"
            case .rectangle: return "rectangle"
            case .ellipse: return "oval"
            case .pen: return "pencil"
            }
        }
        var shortcut: String {
            switch self {
            case .edit: return "M"
            case .obscure: return "X / U"
            case .arrow: return "A"
            case .text: return "T"
            case .rectangle: return "B"
            case .ellipse: return "E"
            case .pen: return "P"
            }
        }
    }

    var tool: Tool? = nil {
        didSet { if tool != oldValue { cancelGesture(); selectedIndex = nil } }
    }
    var color: ScreenshotAnnotationColor = .red {
        didSet { if color != oldValue { cancelGesture() } }
    }
    var lineWidth: ScreenshotStrokeWidth = .medium {
        didSet { if lineWidth != oldValue { cancelGesture() } }
    }
    var obscureStyle: ScreenshotObscureStyle = .pixelate
    var obscureStrength: ScreenshotObscureStrength = .medium
    var fontSize: ScreenshotFontSize = .medium
    mutating func toggleTool(_ next: Tool) { tool = tool == next ? nil : next }
    mutating func toggleObscure(_ style: ScreenshotObscureStyle) {
        cancelGesture()
        let deactivate = tool == .obscure && obscureStyle == style
        obscureStyle = style; tool = deactivate ? nil : .obscure
    }
    private var points: [CGPoint] = []
    private var undoStates: [[ScreenshotAnnotation]] = []
    private var redoStates: [[ScreenshotAnnotation]] = []
    private(set) var selectedIndex: Int?
    private var arrowEndpoint: Bool?
    private var editLimits: CGRect?
    private var editRegion: ScreenshotRegionModel?
    private var editPreview: ScreenshotAnnotation?
    private var committed: [ScreenshotAnnotation] = []
    private var start: CGPoint?
    private var preview: ScreenshotAnnotation?

    var annotations: [ScreenshotAnnotation] {
        var result = committed
        if let selectedIndex, let editPreview { result[selectedIndex] = editPreview }
        if let preview { result.append(preview) }
        return result
    }
    var canRedo: Bool { !redoStates.isEmpty }
    var canUndo: Bool { preview != nil || editPreview != nil || !undoStates.isEmpty }
    var selectedAnnotation: ScreenshotAnnotation? { selectedIndex.flatMap { annotations.indices.contains($0) ? annotations[$0] : nil } }
    var isEditingGesture: Bool { editRegion != nil || arrowEndpoint != nil }

    mutating func begin(at point: CGPoint) {
        cancelGesture()
        selectedIndex = nil
        guard point.isFinite, tool?.usesStroke == true || tool == .obscure else { return }
        start = point
        if tool == .pen { points = [point] }
    }

    mutating func update(to point: CGPoint) {
        guard let start, point.isFinite else { return }
        switch tool {
        case .arrow:
            preview = hypot(point.x - start.x, point.y - start.y) >= 2
                ? .arrow(from: start, to: point, color: color, width: lineWidth.rawValue) : nil
        case .pen:
            if let last = points.last, hypot(point.x - last.x, point.y - last.y) >= 0.75 { points.append(point) }
            preview = points.count > 1 ? .stroke(points, color: color, width: lineWidth.rawValue) : nil
        case .rectangle, .ellipse, .obscure:
            let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                              width: abs(point.x - start.x), height: abs(point.y - start.y))
            guard rect.width >= 1 && rect.height >= 1 else { preview = nil; return }
            switch tool {
            case .rectangle: preview = .rectangle(rect, color: color, width: lineWidth.rawValue)
            case .ellipse: preview = .ellipse(rect, color: color, width: lineWidth.rawValue)
            case .obscure: preview = obscureStyle == .pixelate ? .pixelate(rect, strength: obscureStrength) : .blur(rect, strength: obscureStrength)
            default: break
            }
        default: preview = nil
        }
    }

    mutating func end(at point: CGPoint) {
        guard point.isFinite else { cancelGesture(); return }
        update(to: point)
        if let preview { commit(committed + [preview]) }
        cancelGesture()
    }

    mutating func addText(_ text: String, at point: CGPoint) {
        guard point.isFinite, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        commit(committed + [.text(text, at: point, color: color, size: fontSize.rawValue)])
    }

    mutating func undo() {
        if start != nil || isEditingGesture { cancelGesture(); return }
        guard let previous = undoStates.popLast() else { return }
        redoStates.append(committed); committed = previous; selectedIndex = nil
    }
    mutating func redo() {
        cancelGesture()
        guard let next = redoStates.popLast() else { return }
        undoStates.append(committed); committed = next; selectedIndex = nil
    }
    mutating func cancelGesture() {
        start = nil; preview = nil; points.removeAll(); editRegion = nil; editPreview = nil; arrowEndpoint = nil; editLimits = nil
    }
    func hitIndex(at point: CGPoint) -> Int? { committed.indices.reversed().first { committed[$0].hit(at: point) } }
    mutating func selectAnnotation(at point: CGPoint) { selectedIndex = hitIndex(at: point) }
    func editInteraction(at point: CGPoint) -> ScreenshotRegionModel.Interaction? {
        if let editRegion { return editRegion.interaction(at: point) }
        if let selectedIndex, case let .arrow(a, b, _, _) = committed[selectedIndex] {
            if let endpoint = arrowEndpoint ?? (hypot(point.x - a.x, point.y - a.y) <= 7 ? true : (hypot(point.x - b.x, point.y - b.y) <= 7 ? false : nil)) {
                let p = endpoint ? a : b, other = endpoint ? b : a
                return .resize(p.x < other.x ? -1 : 1, p.y < other.y ? -1 : 1)
            }
            return selectedAnnotation?.bounds.insetBy(dx: -7, dy: -7).contains(point) == true ? .move : (hitIndex(at: point) == nil ? nil : .move)
        }
        if let selected = selectedAnnotation, selected.bounds.insetBy(dx: -7, dy: -7).contains(point) {
            guard selected.resizable else { return .move }
            var region = ScreenshotRegionModel(desktopBounds: selected.bounds)
            region.begin(at: selected.bounds.origin)
            region.end(at: CGPoint(x: selected.bounds.maxX, y: selected.bounds.maxY))
            return region.interaction(at: point)
        }
        return hitIndex(at: point) == nil ? nil : .move
    }
    mutating func beginEdit(at point: CGPoint, within limits: CGRect) {
        cancelGesture()
        if selectedAnnotation?.bounds.insetBy(dx: -7, dy: -7).contains(point) != true {
            selectAnnotation(at: point)
        }
        guard let selected = selectedAnnotation else { return }
        if case let .arrow(a, b, _, _) = selected {
            arrowEndpoint = hypot(point.x - a.x, point.y - a.y) <= 7 ? true : (hypot(point.x - b.x, point.y - b.y) <= 7 ? false : nil)
            if arrowEndpoint != nil { editLimits = limits; return }
        }
        var drag = ScreenshotRegionModel(desktopBounds: limits.union(selected.bounds))
        drag.begin(at: selected.bounds.origin); drag.end(at: CGPoint(x: selected.bounds.maxX, y: selected.bounds.maxY))
        if selected.resizable, case .arrow = selected { drag.beginMove(at: point) }
        else if selected.resizable { drag.begin(at: point) }
        else { drag.beginMove(at: point) }
        editRegion = drag
    }
    mutating func updateEdit(to point: CGPoint) {
        guard let selectedIndex else { return }
        if let arrowEndpoint, let editLimits, case let .arrow(a, b, color, width) = committed[selectedIndex] {
            let clipped = CGPoint(x: min(max(point.x, editLimits.minX), editLimits.maxX), y: min(max(point.y, editLimits.minY), editLimits.maxY))
            let from = arrowEndpoint ? clipped : a, to = arrowEndpoint ? b : clipped
            if hypot(to.x - from.x, to.y - from.y) >= 2 { editPreview = .arrow(from: from, to: to, color: color, width: width) }
            return
        }
        editRegion?.update(to: point)
        if let rect = editRegion?.selection, rect.width >= 1, rect.height >= 1 {
            editPreview = committed[selectedIndex].remapped(to: rect)
        }
    }
    mutating func endEdit(at point: CGPoint) {
        updateEdit(to: point)
        if let selectedIndex, let editPreview, editPreview.bounds != committed[selectedIndex].bounds {
            var next = committed; next[selectedIndex] = editPreview; commit(next)
        }
        cancelGesture()
    }
    mutating func deleteSelected() {
        guard let selectedIndex else { return }
        var next = committed; next.remove(at: selectedIndex); commit(next); self.selectedIndex = nil
    }
    mutating func replaceSelectedText(_ text: String) {
        guard let selectedIndex, case let .text(_, point, color, size) = committed[selectedIndex] else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { deleteSelected(); return }
        var next = committed; next[selectedIndex] = .text(text, at: point, color: color, size: size); commit(next)
    }
    mutating func styleSelected(color: ScreenshotAnnotationColor? = nil, width: ScreenshotStrokeWidth? = nil) {
        guard tool == .edit, let selectedIndex else { return }
        let current = committed[selectedIndex]
        guard (color != nil && current.annotationColor != nil && current.annotationColor != color)
            || (width != nil && current.strokeWidth != nil && current.strokeWidth != width?.rawValue) else { return }
        var next = committed; next[selectedIndex] = next[selectedIndex].styled(color: color, width: width?.rawValue); commit(next)
    }
    mutating func changeFontSize(_ size: ScreenshotFontSize) {
        fontSize = size
        guard tool == .edit, let selectedIndex, case let .text(text, point, color, current) = committed[selectedIndex], current != size.rawValue else { return }
        var next = committed; next[selectedIndex] = .text(text, at: point, color: color, size: size.rawValue); commit(next)
    }
    mutating func changeObscure(style: ScreenshotObscureStyle, strength: ScreenshotObscureStrength) {
        cancelGesture(); obscureStyle = style; obscureStrength = strength
        guard tool == .edit, let selectedIndex, let currentStyle = committed[selectedIndex].obscureStyle,
              currentStyle != style || committed[selectedIndex].obscureStrength != strength else { return }
        let bounds = committed[selectedIndex].bounds
        var next = committed; next[selectedIndex] = style == .pixelate ? .pixelate(bounds, strength: strength) : .blur(bounds, strength: strength); commit(next)
    }
    private mutating func commit(_ next: [ScreenshotAnnotation]) {
        undoStates.append(committed)
        if undoStates.count > 100 { undoStates.removeFirst() }
        redoStates.removeAll(); committed = next
    }

}

private extension CGPoint {
    var isFinite: Bool { x.isFinite && y.isFinite }
}
