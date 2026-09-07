import AppKit

@MainActor enum ScreenshotCursors {
    private static var drawing: [String: NSCursor] = [:]
    static func drawing(tool: ScreenshotAnnotationModel.Tool, effect: ScreenshotObscureStyle) -> NSCursor {
        if tool == .text { return .iBeam }
        let symbol = tool == .obscure && effect == .blur ? "drop.halffull" : tool.symbol
        if let cursor = drawing[symbol] { return cursor }
        let image = NSImage(size: CGSize(width: 34, height: 34), flipped: false) { _ in
            let cross = NSBezierPath()
            cross.move(to: CGPoint(x: 2, y: 27)); cross.line(to: CGPoint(x: 12, y: 27))
            cross.move(to: CGPoint(x: 7, y: 22)); cross.line(to: CGPoint(x: 7, y: 32))
            NSColor.black.setStroke(); cross.lineWidth = 3; cross.stroke()
            NSColor.white.setStroke(); cross.lineWidth = 1; cross.stroke()
            NSColor.black.withAlphaComponent(0.8).setFill()
            NSBezierPath(roundedRect: CGRect(x: 13, y: 2, width: 20, height: 20), xRadius: 4, yRadius: 4).fill()
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [.white])) {
                glyph.draw(in: CGRect(x: 16, y: 5, width: 14, height: 14))
            }
            return true
        }
        let cursor = NSCursor(image: image, hotSpot: CGPoint(x: 7, y: 7)); drawing[symbol] = cursor
        return cursor
    }
}
