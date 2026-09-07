import Foundation

struct ScreenshotRegionModel {
    enum Interaction: Equatable {
        case create, move
        case resize(Int, Int)
    }
    private enum Drag {
        case create(CGPoint)
        case move(CGPoint, CGRect)
        case resize(CGPoint, CGRect, Int, Int)
    }
    private var drag: Drag?
    private(set) var selection: CGRect?
    private(set) var isDragging = false
    let desktopBounds: CGRect

    init(desktopBounds: CGRect) { self.desktopBounds = desktopBounds }

    func interaction(at point: CGPoint) -> Interaction {
        switch drag {
        case .create: return .create
        case .move: return .move
        case .resize(_, _, let x, let y): return .resize(x, y)
        case nil: break
        }
        guard let selection else { return .create }
        let x = abs(point.x - selection.minX) <= 7 ? -1 : (abs(point.x - selection.maxX) <= 7 ? 1 : 0)
        let y = abs(point.y - selection.minY) <= 7 ? -1 : (abs(point.y - selection.maxY) <= 7 ? 1 : 0)
        if selection.insetBy(dx: -7, dy: -7).contains(point), x != 0 || y != 0 { return .resize(x, y) }
        return selection.contains(point) ? .move : .create
    }

    mutating func begin(at point: CGPoint) {
        isDragging = true
        guard let selection else { drag = .create(point); return }
        switch interaction(at: point) {
        case .resize(let x, let y): drag = .resize(point, selection, x, y)
        case .move: drag = .move(point, selection)
        case .create: drag = .create(point)
        }
    }

    mutating func cancelDrag() { drag = nil; isDragging = false }

    mutating func beginMove(at point: CGPoint) {
        guard let selection else { return }
        isDragging = true; drag = .move(point, selection)
    }

    mutating func update(to rawPoint: CGPoint) {
        let point = CGPoint(x: min(max(rawPoint.x, desktopBounds.minX), desktopBounds.maxX),
                            y: min(max(rawPoint.y, desktopBounds.minY), desktopBounds.maxY))
        switch drag {
        case .create(let anchor):
            selection = Self.rect(anchor, point)
        case .move(let anchor, let original):
            let x = min(max(original.minX + point.x - anchor.x, desktopBounds.minX), desktopBounds.maxX - original.width)
            let y = min(max(original.minY + point.y - anchor.y, desktopBounds.minY), desktopBounds.maxY - original.height)
            selection = CGRect(origin: CGPoint(x: x, y: y), size: original.size)
        case .resize(_, let original, let x, let y):
            selection = Self.rect(CGPoint(x: x == -1 ? point.x : original.minX, y: y == -1 ? point.y : original.minY),
                                  CGPoint(x: x == 1 ? point.x : original.maxX, y: y == 1 ? point.y : original.maxY))
        case nil: break
        }
    }

    mutating func end(at point: CGPoint) {
        update(to: point); drag = nil; isDragging = false
        if let selection, selection.width < 1 || selection.height < 1 { self.selection = nil }
    }

    private static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
