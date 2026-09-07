import XCTest
import AppKit
@testable import PastePal

final class ScreenshotPolishTests: AppTestSupport {
    func testPenWidthEllipseAndRedoBranching() {
        var model = ScreenshotAnnotationModel()
        model.tool = .pen; model.lineWidth = .thick; model.color = .blue
        model.begin(at: CGPoint(x: 10, y: 10))
        model.update(to: CGPoint(x: 20, y: 30)); model.end(at: CGPoint(x: 40, y: 20))
        guard case let .stroke(points, color, width) = model.annotations.first else { return XCTFail("缺少画笔路径") }
        XCTAssertEqual(points.count, 3); XCTAssertEqual(color, .blue); XCTAssertEqual(width, 6)
        model.tool = .ellipse; model.lineWidth = .thin
        model.begin(at: CGPoint(x: 50, y: 50)); model.end(at: CGPoint(x: 20, y: 10))
        guard case let .ellipse(rect, _, width) = model.annotations.last else { return XCTFail("缺少椭圆") }
        XCTAssertEqual(rect, CGRect(x: 20, y: 10, width: 30, height: 40)); XCTAssertEqual(width, 2)
        model.undo(); XCTAssertTrue(model.canRedo)
        model.redo(); XCTAssertEqual(model.annotations.count, 2); XCTAssertFalse(model.canRedo)
        model.undo()
        model.begin(at: .zero); model.end(at: .zero)
        XCTAssertTrue(model.canRedo, "无效手势保留重做历史")
        model.addText("新分支", at: .zero)
        XCTAssertFalse(model.canRedo)
    }

    func testEllipseAndPenAreBurnedIntoExport() throws {
        let context = try context(width: 100, height: 100)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let frame = ScreenshotFrame(bounds: CGRect(x: 0, y: 0, width: 100, height: 100), image: try XCTUnwrap(context.makeImage()))
        let png = try ScreenshotFrame.png(selection: frame.bounds, frames: [frame], annotations: [
            .ellipse(CGRect(x: 20, y: 20, width: 60, height: 60), color: .blue, width: 6),
            .stroke([CGPoint(x: 30, y: 50), CGPoint(x: 50, y: 50), CGPoint(x: 60, y: 40)], color: .red, width: 6)
        ])
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
        let ellipse = try XCTUnwrap(bitmap.colorAt(x: 20, y: 50)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(ellipse.blueComponent, 0.9); XCTAssertLessThan(ellipse.redComponent, 0.2)
        let pen = try XCTUnwrap(bitmap.colorAt(x: 40, y: 50)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(pen.redComponent, 0.9); XCTAssertLessThan(pen.blueComponent, 0.3)
        let untouched = try XCTUnwrap(bitmap.colorAt(x: 10, y: 10)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(untouched.blueComponent, 0.9)
    }

    @MainActor func testCursorsMatchRegionEdgesDraggingAndText() throws {
        _ = NSApplication.shared
        let image = try XCTUnwrap(context(width: 300, height: 300).makeImage())
        let selection = ScreenshotSelection(frames: [ScreenshotFrame(bounds: CGRect(x: 0, y: 0, width: 300, height: 300), image: image)]) { _ in }
        defer { selection.close() }
        XCTAssertEqual(selection.cursor(at: .zero), .crosshair)
        selection.handleDrag(.begin, at: CGPoint(x: 50, y: 50)); selection.handleDrag(.end, at: CGPoint(x: 250, y: 250))
        XCTAssertNil(selection.selectedTool)
        XCTAssertEqual(selection.cursor(at: CGPoint(x: 150, y: 150)), .openHand)
        XCTAssertEqual(selection.cursor(at: CGPoint(x: 150, y: 150)), .openHand)
        for (point, position) in [
            (CGPoint(x: 50, y: 50), NSCursor.FrameResizePosition.bottomLeft),
            (CGPoint(x: 150, y: 50), .bottom), (CGPoint(x: 250, y: 50), .bottomRight),
            (CGPoint(x: 50, y: 150), .left), (CGPoint(x: 250, y: 150), .right),
            (CGPoint(x: 50, y: 250), .topLeft), (CGPoint(x: 150, y: 250), .top), (CGPoint(x: 250, y: 250), .topRight)
        ] {
            XCTAssertEqual(selection.cursor(at: point), .frameResize(position: position, directions: .all))
        }
        selection.handleDrag(.begin, at: CGPoint(x: 150, y: 150))
        XCTAssertEqual(selection.cursor(at: CGPoint(x: 10, y: 10)), .closedHand, "拖动中保持手形，不切换为新选区")
        selection.handleDrag(.end, at: CGPoint(x: 150, y: 150))
        selection.selectTool(.text)
        XCTAssertEqual(selection.cursor(at: CGPoint(x: 150, y: 150)), .iBeam)
        XCTAssertEqual(selection.cursor(at: CGPoint(x: 10, y: 10)), .operationNotAllowed)
        XCTAssertNil(selection.handleKey(try keyEvent(14, "e")))
        selection.handleDrag(.begin, at: CGPoint(x: 80, y: 80)); selection.handleDrag(.end, at: CGPoint(x: 180, y: 180))
        guard case .ellipse = selection.annotations.first else { return XCTFail("E 应选择椭圆") }
        _ = selection.handleKey(try keyEvent(6, "z", modifiers: .command))
        XCTAssertTrue(selection.annotations.isEmpty)
        _ = selection.handleKey(try keyEvent(6, "z", modifiers: [.command, .shift]))
        XCTAssertEqual(selection.annotations.count, 1)
    }

    @MainActor func testToolbarWidthAndRedoActionsFollowSelection() throws {
        _ = NSApplication.shared
        let toolbar = ScreenshotAnnotationToolbar()
        var width: ScreenshotStrokeWidth?
        var redone = false
        toolbar.onWidth = { width = $0 }; toolbar.onRedo = { redone = true }
        toolbar.update(tool: .pen, color: .red, canUndo: true, canRedo: true, lineWidth: .thick)
        XCTAssertTrue(toolbar.widthControl.isEnabled)
        XCTAssertEqual(toolbar.widthControl.selectedSegment, 2)
        toolbar.widthControl.selectedSegment = 0
        toolbar.widthControl.sendAction(toolbar.widthControl.action!, to: toolbar.widthControl.target)
        XCTAssertEqual(width, .thin)
        toolbar.redoButton.performClick(nil); XCTAssertTrue(redone)
        toolbar.update(tool: .obscure, color: .red, canUndo: false)
        XCTAssertFalse(toolbar.widthControl.isEnabled); XCTAssertFalse(toolbar.redoButton.isEnabled)
    }

    private func context(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }
}
