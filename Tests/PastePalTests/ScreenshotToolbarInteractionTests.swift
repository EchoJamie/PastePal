import XCTest
import AppKit
@testable import PastePal

final class ScreenshotToolbarInteractionTests: AppTestSupport {
    @MainActor func testIconToolsPaletteSelectionAndUndoAvailability() throws {
        _ = NSApplication.shared
        let toolbar = ScreenshotAnnotationToolbar()
        var selectedTool: ScreenshotAnnotationModel.Tool?
        var selectedColor: ScreenshotAnnotationColor?
        toolbar.onTool = { selectedTool = $0; toolbar.update(tool: $0, color: .red, canUndo: true) }
        toolbar.onColor = { selectedColor = $0; toolbar.update(tool: .rectangle, color: $0, canUndo: true) }
        XCTAssertEqual(toolbar.toolButtons.count, 7);
        XCTAssertFalse(ScreenshotAnnotationModel.Tool.allCases.contains { $0.shortcut == "R" || $0.title == "打码" }); XCTAssertEqual(toolbar.colorButtons.count, 6)
        for tool in ScreenshotAnnotationModel.Tool.allCases {
            let button = try XCTUnwrap(toolbar.toolButtons[tool])
            XCTAssertNotNil(button.image); XCTAssertTrue(button.title.isEmpty)
            XCTAssertEqual(button.accessibilityLabel(), tool.title)
            XCTAssertTrue(button.toolTip?.contains(tool.shortcut) == true)
        }
        XCTAssertFalse(toolbar.undoButton.isEnabled)
        XCTAssertFalse(toolbar.colorButtons[.red]!.isEnabled)
        toolbar.toolButtons[.rectangle]?.performClick(nil)
        XCTAssertEqual(selectedTool, .rectangle)
        XCTAssertEqual(toolbar.toolButtons[.rectangle]?.state, .on)
        XCTAssertEqual(toolbar.toolButtons[.edit]?.state, .off)
        toolbar.colorButtons[.blue]?.performClick(nil)
        XCTAssertEqual(selectedColor, .blue)
        XCTAssertEqual(toolbar.colorButtons[.blue]?.state, .on)
        XCTAssertTrue(toolbar.undoButton.isEnabled)
        toolbar.update(tool: .obscure, color: .blue, canUndo: true)
        XCTAssertTrue(toolbar.colorButtons.values.allSatisfy { !$0.isEnabled })
        toolbar.onTool = nil; toolbar.onColor = nil
    }

    @MainActor func testRectangleShortcutAnnotatesWithoutResizingSelectionAndCanUndo() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let frame = ScreenshotFrame(bounds: CGRect(x: -100, y: 0, width: 100, height: 100), image: try XCTUnwrap(context.makeImage()))
        var confirmed: CGRect?
        let selection = ScreenshotSelection(frames: [frame]) { confirmed = $0 }
        defer { selection.close() }
        selection.handleDrag(.begin, at: CGPoint(x: -90, y: 10))
        selection.handleDrag(.end, at: CGPoint(x: -10, y: 90))
        XCTAssertNil(selection.handleKey(try keyEvent(11, "b")))
        selection.selectColor(.yellow)
        selection.handleDrag(.begin, at: CGPoint(x: -80, y: 20))
        selection.handleDrag(.end, at: CGPoint(x: -30, y: 60))
        guard case let .rectangle(rect, color, _) = selection.annotations.first else { return XCTFail("应创建矩形标注") }
        XCTAssertEqual(rect, CGRect(x: -80, y: 20, width: 50, height: 40)); XCTAssertEqual(color, .yellow)
        XCTAssertNil(selection.handleKey(try keyEvent(6, "z", modifiers: .command)))
        XCTAssertTrue(selection.annotations.isEmpty)
        selection.handleDrag(.begin, at: CGPoint(x: -80, y: 20)); selection.handleDrag(.end, at: CGPoint(x: -30, y: 60))
        XCTAssertNil(selection.handleKey(try keyEvent(36, "\r")))
        XCTAssertEqual(confirmed, CGRect(x: -90, y: 10, width: 80, height: 80))
    }

    @MainActor func testEveryOverlayAcceptsFirstPressAndRoutesWindowCoordinates() throws {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 40, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        for origin in [CGPoint(x: 0, y: 0), CGPoint(x: -1000, y: 300)] {
            let window = NSWindow(contentRect: CGRect(origin: origin, size: CGSize(width: 500, height: 300)), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let view = ScreenshotSelectionView(frame: CGRect(x: 0, y: 0, width: 500, height: 300), image: image)
            window.contentView = view
            defer { window.contentView = nil; window.close() }
            var points: [CGPoint] = []
            view.onDrag = { _, point in points.append(point) }
            XCTAssertTrue(view.acceptsFirstMouse(for: nil))
            view.updateTrackingAreas()
            XCTAssertTrue(view.trackingAreas.contains { $0.options.contains(.activeAlways) && $0.options.contains(.cursorUpdate) })
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: CGPoint(x: 30, y: 40), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                if type == .leftMouseDown { view.mouseDown(with: event) }
                else if type == .leftMouseDragged { view.mouseDragged(with: event) }
                else { view.mouseUp(with: event) }
            }
            XCTAssertEqual(points, Array(repeating: CGPoint(x: window.frame.minX + 30, y: window.frame.minY + 40), count: 3))
        }
    }
}
