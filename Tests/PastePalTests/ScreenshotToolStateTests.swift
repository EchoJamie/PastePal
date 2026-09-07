import PastePalLocalization
import XCTest
import AppKit
@testable import PastePal

final class ScreenshotToolStateTests: AppTestSupport {
    @MainActor func testInitialRegionTracksEveryMouseMoveWhileNoToolIsSelected() throws {
        _ = NSApplication.shared
        var result: CGRect?
        let session = ScreenshotSelection(frames: [ScreenshotFrame(bounds: CGRect(x: 0, y: 0, width: 300, height: 300), image: try XCTUnwrap(NSBitmapImageRep(data: pngData())?.cgImage))]) { result = $0 }
        defer { session.close() }
        session.handleDrag(.begin, at: CGPoint(x: 20, y: 30))
        session.handleDrag(.change, at: CGPoint(x: 21, y: 31))
        XCTAssertEqual(session.cursor(at: CGPoint(x: 21, y: 31)), .crosshair)
        session.handleDrag(.change, at: CGPoint(x: 100, y: 120))
        session.handleDrag(.end, at: CGPoint(x: 220, y: 230))
        XCTAssertNil(session.selectedTool)
        XCTAssertEqual(session.cursor(at: CGPoint(x: 100, y: 100)), .openHand)
        session.handleDrag(.begin, at: CGPoint(x: 50, y: 50))
        session.handleDrag(.change, at: CGPoint(x: 80, y: 80))
        session.handleDrag(.end, at: CGPoint(x: 90, y: 90))
        session.confirm(action: .clipboard)
        XCTAssertEqual(result, CGRect(x: 60, y: 70, width: 200, height: 200))
    }

    @MainActor func testDefaultIdleToggleOffAndExclusiveSelectionThroughButtons() throws {
        let session = try selection()
        defer { session.close() }
        let toolbar = ScreenshotAnnotationToolbar()
        toolbar.onTool = { tool in
            session.selectTool(tool)
            toolbar.update(tool: session.selectedTool, color: .red, canUndo: false)
        }
        XCTAssertNil(session.selectedTool)
        XCTAssertTrue(toolbar.toolButtons.values.allSatisfy { $0.state == .off })
        let point = CGPoint(x: 100, y: 100)
        XCTAssertEqual(session.cursor(at: point), .openHand)
        session.handleDrag(.begin, at: point); session.handleDrag(.end, at: CGPoint(x: 200, y: 200))
        XCTAssertTrue(session.annotations.isEmpty)
        for tool in ScreenshotAnnotationModel.Tool.allCases {
            toolbar.toolButtons[tool]?.performClick(nil)
            XCTAssertEqual(session.selectedTool, tool)
            XCTAssertEqual(toolbar.toolButtons.values.filter { $0.state == .on }.count, 1)
            XCTAssertEqual(toolbar.toolButtons[tool]?.accessibilityValue() as? String, L("使用中"))
            toolbar.toolButtons[tool]?.performClick(nil)
            XCTAssertNil(session.selectedTool)
            XCTAssertTrue(toolbar.toolButtons.values.allSatisfy { $0.state == .off })
            XCTAssertEqual(session.cursor(at: point), .openHand)
        }
        toolbar.toolButtons[.arrow]?.performClick(nil); toolbar.toolButtons[.pen]?.performClick(nil)
        XCTAssertEqual(session.selectedTool, .pen)
        XCTAssertEqual(toolbar.toolButtons[.arrow]?.state, .off)
        XCTAssertEqual(toolbar.toolButtons.values.filter { $0.state == .on }.count, 1)
    }

    @MainActor func testEachToolUsesItsCursorAndKeyboardToggleRestoresArrow() throws {
        let session = try selection(); defer { session.close() }
        let point = CGPoint(x: 100, y: 100)
        var cursors: [NSCursor] = []
        for tool in [ScreenshotAnnotationModel.Tool.arrow, .rectangle, .ellipse, .pen, .obscure] {
            session.selectTool(tool)
            let cursor = session.cursor(at: point)
            XCTAssertNotEqual(cursor, .arrow); XCTAssertNotEqual(cursor, .crosshair)
            XCTAssertEqual(cursor, ScreenshotCursors.drawing(tool: tool, effect: .pixelate))
            XCTAssertEqual(session.cursor(at: CGPoint(x: 310, y: 310)), .operationNotAllowed)
            cursors.append(cursor)
            session.selectTool(tool); XCTAssertEqual(session.cursor(at: point), .openHand)
        }
        XCTAssertEqual(Set(cursors.map(ObjectIdentifier.init)).count, cursors.count)
        _ = session.handleKey(try keyEvent(7, "x"))
        let mosaic = session.cursor(at: point)
        _ = session.handleKey(try keyEvent(32, "u"))
        XCTAssertEqual(session.selectedTool, .obscure); XCTAssertNotEqual(session.cursor(at: point), mosaic)
        _ = session.handleKey(try keyEvent(32, "u"))
        XCTAssertNil(session.selectedTool); XCTAssertEqual(session.cursor(at: point), .openHand)
        session.selectTool(.text); XCTAssertEqual(session.cursor(at: point), .iBeam)
    }

    @MainActor func testSwitchingToolCancelsUnfinishedGestureAndPreservesHistory() throws {
        let session = try selection(); defer { session.close() }
        session.selectTool(.rectangle)
        session.handleDrag(.begin, at: CGPoint(x: 20, y: 20)); session.handleDrag(.end, at: CGPoint(x: 80, y: 80))
        session.handleDrag(.begin, at: CGPoint(x: 100, y: 100)); session.handleDrag(.change, at: CGPoint(x: 160, y: 160))
        XCTAssertEqual(session.annotations.count, 2)
        session.selectTool(.pen)
        XCTAssertEqual(session.annotations.count, 1)
        _ = session.handleKey(try keyEvent(6, "z", modifiers: .command))
        XCTAssertTrue(session.annotations.isEmpty)
        _ = session.handleKey(try keyEvent(6, "z", modifiers: [.command, .shift]))
        XCTAssertEqual(session.annotations.count, 1); XCTAssertEqual(session.selectedTool, .pen)
    }

    func testChangingObscureEffectStrengthAndTextSizeSupportsUndo() {
        var model = ScreenshotAnnotationModel(); model.tool = .obscure
        model.begin(at: .zero); model.end(at: CGPoint(x: 60, y: 60))
        model.tool = .edit; model.selectAnnotation(at: CGPoint(x: 30, y: 30))
        model.changeObscure(style: .blur, strength: .strong)
        XCTAssertEqual(model.annotations[0].obscureStyle, .blur)
        XCTAssertEqual(model.annotations[0].obscureStrength, .strong)
        model.undo(); XCTAssertEqual(model.annotations[0].obscureStyle, .pixelate)
        XCTAssertEqual(model.annotations[0].obscureStrength, .medium)
        model.redo(); XCTAssertEqual(model.annotations[0].obscureStrength, .strong)
        model.addText("文字", at: CGPoint(x: 80, y: 80)); model.selectAnnotation(at: CGPoint(x: 85, y: 85))
        model.changeFontSize(.large); XCTAssertEqual(model.annotations[1].fontSize, 28)
        model.undo(); XCTAssertEqual(model.annotations[1].fontSize, 20)
    }

    func testHorizontalArrowBodyMovesAndEndpointResizes() {
        var model = ScreenshotAnnotationModel(); model.tool = .arrow
        model.begin(at: CGPoint(x: 30, y: 50)); model.end(at: CGPoint(x: 130, y: 50))
        model.tool = .edit
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 300)
        model.beginEdit(at: CGPoint(x: 80, y: 50), within: bounds)
        XCTAssertEqual(model.editInteraction(at: CGPoint(x: 80, y: 50)), .move)
        model.endEdit(at: CGPoint(x: 100, y: 70))
        guard case let .arrow(a, b, _, _) = model.annotations[0] else { return XCTFail("缺少箭头") }
        XCTAssertEqual(a, CGPoint(x: 50, y: 70)); XCTAssertEqual(b, CGPoint(x: 150, y: 70))
        model.beginEdit(at: b, within: bounds); model.endEdit(at: CGPoint(x: 180, y: 120))
        guard case let .arrow(start, end, _, _) = model.annotations[0] else { return XCTFail("缺少箭头") }
        XCTAssertEqual(start, a); XCTAssertEqual(end, CGPoint(x: 180, y: 120))
        model.undo(); XCTAssertEqual(model.annotations[0].bounds.height, 1)
    }

    @MainActor func testToolSwitchEndsRegionDragAndDefaultMoveStaysWithinDesktop() throws {
        let session = try selection(); defer { session.close() }
        session.handleDrag(.begin, at: CGPoint(x: 150, y: 150)); session.handleDrag(.change, at: CGPoint(x: 160, y: 160))
        session.selectTool(.pen); session.selectTool(.pen)
        XCTAssertNil(session.selectedTool)
        session.handleDrag(.end, at: CGPoint(x: 200, y: 200))
        XCTAssertEqual(session.cursor(at: CGPoint(x: 150, y: 150)), .openHand)
        var crop: CGRect?
        session.onSave = { crop = $0 }
        session.handleDrag(.begin, at: CGPoint(x: 20, y: 20)); session.handleDrag(.end, at: CGPoint(x: 60, y: 60))
        session.confirm(action: .save)
        XCTAssertEqual(crop, CGRect(x: 0, y: 0, width: 300, height: 300))
    }

    @MainActor func testContextOptionsShowOnlyApplicableControls() {
        let toolbar = ScreenshotAnnotationToolbar()
        toolbar.update(tool: nil, color: .red, canUndo: false)
        XCTAssertTrue(toolbar.colorButtons[.red]!.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(toolbar.widthControl.isHiddenOrHasHiddenAncestor)
        toolbar.update(tool: .text, color: .blue, canUndo: true)
        XCTAssertFalse(toolbar.colorButtons[.blue]!.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(toolbar.fontControl.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(toolbar.widthControl.isHiddenOrHasHiddenAncestor)
        toolbar.update(tool: .obscure, color: .blue, canUndo: true)
        XCTAssertTrue(toolbar.colorButtons[.blue]!.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(toolbar.effectControl.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(toolbar.strengthControl.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(toolbar.fontControl.isHiddenOrHasHiddenAncestor)
        toolbar.update(tool: .edit, color: .red, canUndo: true, selected: .text("A", at: .zero, color: .green, size: 28))
        XCTAssertEqual(toolbar.fontControl.selectedSegment, 2)
        XCTAssertFalse(toolbar.fontControl.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(toolbar.effectControl.isHiddenOrHasHiddenAncestor)
    }

    @MainActor func testNativeCanvasAndToolbarCursorHandoff() throws {
        _ = NSApplication.shared
        let frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = ScreenshotSelectionView(frame: frame, image: try XCTUnwrap(NSBitmapImageRep(data: pngData())?.cgImage))
        window.contentView = canvas; defer { window.contentView = nil; window.close() }
        let pencil = ScreenshotCursors.drawing(tool: .pen, effect: .pixelate)
        canvas.onCursor = { _ in pencil }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: CGPoint(x: 100, y: 100), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        canvas.mouseMoved(with: event); XCTAssertEqual(NSCursor.current, pencil)
        let toolbar = ScreenshotAnnotationToolbar()
        toolbar.cursorUpdate(with: event); XCTAssertEqual(NSCursor.current, .arrow)
        canvas.cursorUpdate(with: event); XCTAssertEqual(NSCursor.current, pencil)
        canvas.onCursor = { _ in .arrow }
        canvas.cursorUpdate(with: event); XCTAssertEqual(NSCursor.current, .arrow)
    }

    @MainActor func testExportBackKeepsSelectionAnnotationsAndUndoHistory() async throws {
        _ = NSApplication.shared
        let image = try XCTUnwrap(NSBitmapImageRep(data: pngData())?.cgImage)
        let monitor = ClipboardMonitor(settings: SettingsStore(defaults: defaults), pasteboard: board)
        let controller = ScreenshotController(monitor: monitor, pasteboard: board, permission: { true }, capture: {
            [ScreenshotFrame(bounds: CGRect(x: 0, y: 0, width: 300, height: 300), image: image)]
        })
        defer { controller.cancel() }
        let count = board.changeCount
        controller.start(); try await waitUntil { controller.selector != nil }
        let session = try XCTUnwrap(controller.selector)
        session.handleDrag(.begin, at: CGPoint(x: 10, y: 10)); session.handleDrag(.end, at: CGPoint(x: 250, y: 250))
        session.selectTool(.rectangle)
        session.handleDrag(.begin, at: CGPoint(x: 40, y: 40)); session.handleDrag(.end, at: CGPoint(x: 100, y: 100))
        session.confirm(action: .save)
        XCTAssertTrue(controller.isActive); XCTAssertTrue(session.isSuspended)
        let exporter = try XCTUnwrap(controller.exportPreview)
        XCTAssertTrue(descendants(of: exporter.window?.contentView).compactMap { $0 as? NSButton }.contains { $0.title == L("返回编辑") })
        exporter.close()
        XCTAssertNil(controller.exportPreview); XCTAssertFalse(session.isSuspended)
        XCTAssertTrue(controller.selector === session)
        XCTAssertEqual(session.annotations.count, 1); XCTAssertEqual(session.selectedTool, .rectangle)
        _ = session.handleKey(try keyEvent(6, "z", modifiers: .command)); XCTAssertTrue(session.annotations.isEmpty)
        _ = session.handleKey(try keyEvent(6, "z", modifiers: [.command, .shift])); XCTAssertEqual(session.annotations.count, 1)
        XCTAssertEqual(board.changeCount, count)
        session.confirm(action: .save); XCTAssertNotNil(controller.exportPreview)
        controller.cancel(); XCTAssertNil(controller.exportPreview); XCTAssertNil(controller.selector); XCTAssertFalse(controller.isActive)
    }

    @MainActor func testContextualToolbarsKeepVisibleControlsWithinBounds() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 720, height: 480), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        for tool in [nil] + ScreenshotAnnotationModel.Tool.allCases.map(Optional.some) {
            let toolbar = ScreenshotAnnotationToolbar()
            window.contentView?.addSubview(toolbar)
            toolbar.update(tool: tool, color: .yellow, canUndo: true, effect: .blur, strength: .strong, fontSize: .large)
            toolbar.layoutSubtreeIfNeeded()
            for control in descendants(of: toolbar) where !control.isHiddenOrHasHiddenAncestor && (control is NSButton || control is NSSegmentedControl) {
                XCTAssertTrue(toolbar.bounds.contains(control.convert(control.bounds, to: toolbar)), "工具选项不能溢出")
            }
            toolbar.removeFromSuperview()
        }
    }

    @MainActor private func selection() throws -> ScreenshotSelection {
        _ = NSApplication.shared
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 300)
        return ScreenshotSelection(frames: [ScreenshotFrame(bounds: bounds, image: try XCTUnwrap(NSBitmapImageRep(data: pngData())?.cgImage))], initialSelection: bounds) { _ in }
    }
}
