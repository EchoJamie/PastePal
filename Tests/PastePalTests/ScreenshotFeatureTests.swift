import PastePalLocalization
import XCTest
import AppKit
@testable import PastePal

final class ScreenshotFeatureTests: AppTestSupport {
    func testEditMoveResizeStyleDeleteAndUndoRedo() {
        var model = ScreenshotAnnotationModel()
        model.tool = .rectangle
        model.begin(at: CGPoint(x: 30, y: 30)); model.end(at: CGPoint(x: 100, y: 100))
        model.tool = .edit; model.selectAnnotation(at: CGPoint(x: 30, y: 60))
        let limits = CGRect(x: 0, y: 0, width: 300, height: 300)
        model.beginEdit(at: CGPoint(x: 60, y: 60), within: limits)
        model.endEdit(at: CGPoint(x: 80, y: 90))
        XCTAssertEqual(model.annotations[0].bounds, CGRect(x: 50, y: 60, width: 70, height: 70))
        model.beginEdit(at: CGPoint(x: 120, y: 130), within: limits)
        model.endEdit(at: CGPoint(x: 160, y: 180))
        XCTAssertEqual(model.annotations[0].bounds, CGRect(x: 50, y: 60, width: 110, height: 120))
        model.styleSelected(color: .blue, width: .thick)
        XCTAssertEqual(model.annotations[0].annotationColor, .blue)
        XCTAssertEqual(model.annotations[0].strokeWidth, 6)
        model.deleteSelected(); XCTAssertTrue(model.annotations.isEmpty)
        model.undo(); XCTAssertEqual(model.annotations[0].annotationColor, .blue)
        model.undo(); XCTAssertEqual(model.annotations[0].annotationColor, .red)
        model.undo(); XCTAssertEqual(model.annotations[0].bounds.size, CGSize(width: 70, height: 70))
        model.redo(); XCTAssertEqual(model.annotations[0].bounds.size, CGSize(width: 110, height: 120))
        model.addText("新内容", at: .zero); XCTAssertFalse(model.canRedo)
    }

    func testTopmostSelectionTextEditingAndCancelledMove() {
        var model = ScreenshotAnnotationModel()
        model.addText("旧文字", at: CGPoint(x: 40, y: 40))
        model.addText("顶部文字", at: CGPoint(x: 40, y: 40))
        model.tool = .edit; model.selectAnnotation(at: CGPoint(x: 45, y: 45))
        XCTAssertEqual(model.selectedIndex, 1)
        model.replaceSelectedText("新文字")
        guard case .text("新文字", _, _, _) = model.annotations[1] else { return XCTFail("应修改原标注") }
        let original = model.annotations[1].bounds
        model.beginEdit(at: CGPoint(x: 45, y: 45), within: CGRect(x: 0, y: 0, width: 400, height: 400))
        model.updateEdit(to: CGPoint(x: 100, y: 90)); XCTAssertNotEqual(model.annotations[1].bounds, original)
        model.undo(); XCTAssertEqual(model.annotations[1].bounds, original)
        model.replaceSelectedText(""); XCTAssertEqual(model.annotations.count, 1)
        model.undo(); XCTAssertEqual(model.annotations.count, 2)
    }

    @MainActor func testEditingCursorsFollowResizeAndMove() throws {
        _ = NSApplication.shared
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 300)
        let selection = ScreenshotSelection(frames: [ScreenshotFrame(bounds: bounds, image: try sampleImage())], initialSelection: bounds) { _ in }
        defer { selection.close() }
        selection.selectTool(.rectangle)
        selection.handleDrag(.begin, at: CGPoint(x: 50, y: 50)); selection.handleDrag(.end, at: CGPoint(x: 200, y: 200))
        selection.selectTool(.edit)
        selection.handleDrag(.begin, at: CGPoint(x: 50, y: 100)); selection.handleDrag(.end, at: CGPoint(x: 50, y: 100))
        XCTAssertEqual(selection.cursor(at: CGPoint(x: 50, y: 50)), .frameResize(position: .bottomLeft, directions: .all))
        XCTAssertEqual(selection.cursor(at: CGPoint(x: 100, y: 100)), .openHand)
        selection.handleDrag(.begin, at: CGPoint(x: 100, y: 100))
        XCTAssertEqual(selection.cursor(at: .zero), .closedHand)
        selection.handleDrag(.end, at: CGPoint(x: 120, y: 120))
        XCTAssertEqual(selection.annotations[0].bounds.origin, CGPoint(x: 70, y: 70))
    }

    func testPixelateAndBlurBurnRetinaPixelsClipBoundsAndLeaveOutsideUntouched() throws {
        let image = try sampleImage()
        let bounds = CGRect(x: -40, y: 60, width: 64, height: 48)
        let frame = ScreenshotFrame(bounds: bounds, image: image)
        let region = CGRect(x: -48, y: 68, width: 64, height: 32)
        let original = NSBitmapImageRep(cgImage: image)
        for effect in [ScreenshotAnnotation.pixelate(region), .blur(region)] {
            let result = try XCTUnwrap(NSBitmapImageRep(data: ScreenshotFrame.png(selection: bounds, frames: [frame], annotations: [effect])))
            var changed = 0
            for x in 32..<80 {
                let before = try XCTUnwrap(original.colorAt(x: x, y: 40)?.usingColorSpace(.sRGB))
                let after = try XCTUnwrap(result.colorAt(x: x, y: 40)?.usingColorSpace(.sRGB))
                if abs(before.redComponent - after.redComponent) > 0.1 { changed += 1 }
                XCTAssertEqual(after.alphaComponent, 1, accuracy: 0.01)
            }
            XCTAssertGreaterThan(changed, 10)
            XCTAssertEqual(original.colorAt(x: 4, y: 4), result.colorAt(x: 4, y: 4))
        }
    }

    func testBeautyOutputDimensionsBackgroundAndOriginal() throws {
        let image = try sampleImage()
        let original = try ScreenshotBeautifier.render(image, options: ScreenshotBeautyOptions(backdrop: .original))
        XCTAssertTrue(original === image)
        let decorated = try ScreenshotBeautifier.render(image, options: ScreenshotBeautyOptions(backdrop: .dark, padding: 20, cornerRadius: 16, shadow: false))
        XCTAssertEqual(decorated.width, 168); XCTAssertEqual(decorated.height, 136)
        let bitmap = NSBitmapImageRep(cgImage: decorated)
        XCTAssertEqual(decorated.colorSpace?.name, CGColorSpace.sRGB)
        let pixels = try XCTUnwrap(decorated.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(pixels))
        XCTAssertEqual(Double(bytes[2 * decorated.bytesPerRow + 2 * 4]) / 255, 0.12, accuracy: 0.01)
        XCTAssertEqual(Double(bytes[20 * decorated.bytesPerRow + 20 * 4]) / 255, 0.12, accuracy: 0.01)
        let center = try XCTUnwrap(bitmap.colorAt(x: 84, y: 68)?.usingColorSpace(.sRGB))
        let source = try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: 64, y: 48)?.usingColorSpace(.sRGB))
        XCTAssertEqual(center.redComponent, source.redComponent, accuracy: 0.01)
    }

    @MainActor func testSavePNGPreservesRenderedImage() throws {
        let image = try ScreenshotBeautifier.render(sampleImage(), options: ScreenshotBeautyOptions())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try ScreenshotExportController.write(image, to: url)
        let result = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: url)))
        XCTAssertEqual(result.pixelsWide, image.width); XCTAssertEqual(result.pixelsHigh, image.height)
    }

    @MainActor func testPinAndSaveDoNotWriteClipboardAndCloseIndependently() throws {
        _ = NSApplication.shared
        board.setString("保留", forType: .string)
        let count = board.changeCount
        let monitor = ClipboardMonitor(settings: SettingsStore(defaults: defaults), pasteboard: board)
        let controller = ScreenshotController(monitor: monitor, pasteboard: board)
        let previous = Set(NSApp.windows.map(ObjectIdentifier.init))
        defer { NSApp.windows.filter { !previous.contains(ObjectIdentifier($0)) }.forEach { $0.close() } }
        try controller.deliverPNG(pngData(), action: .pin)
        try controller.deliverPNG(pngData(), action: .save)
        let windows = NSApp.windows.filter { !previous.contains(ObjectIdentifier($0)) }
        XCTAssertEqual(windows.filter { $0.title.hasPrefix(L("贴图")) }.count, 1)
        XCTAssertEqual(windows.filter { $0.title == L("美化并保存") }.count, 1)
        XCTAssertEqual(windows.first { $0.title.hasPrefix(L("贴图")) }?.level, .floating)
        windows.first { $0.title.hasPrefix(L("贴图")) }?.close()
        XCTAssertTrue(windows.first { $0.title == L("美化并保存") }?.isVisible == true)
        XCTAssertEqual(board.changeCount, count); XCTAssertEqual(board.string(forType: .string), "保留")
    }

    @MainActor func testWindowPickerChoosesFrontmostOnlyOnceAndConvertsNegativeCoordinates() throws {
        XCTAssertEqual(ScreenshotWindowCapture.appKitBounds(CGRect(x: -800, y: -200, width: 600, height: 400), primaryTop: 900), CGRect(x: -800, y: 700, width: 600, height: 400))
        var picked: [CGWindowID] = []
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 300)
        let picker = ScreenshotSelection(frames: [ScreenshotFrame(bounds: bounds, image: try sampleImage())], windowCandidates: [
            ScreenshotWindowCandidate(id: 7, title: "前", bounds: CGRect(x: 50, y: 50, width: 100, height: 100)),
            ScreenshotWindowCandidate(id: 9, title: "后", bounds: bounds)
        ], onPickWindow: { picked.append($0) }) { _ in XCTFail("窗口选择不直接导出") }
        defer { picker.close() }
        picker.handleDrag(.end, at: CGPoint(x: 80, y: 80)); picker.handleDrag(.end, at: CGPoint(x: 200, y: 200))
        XCTAssertEqual(picked, [7])
    }

    @MainActor func testMissingWindowsReportsErrorWithoutCapturingOrWriting() async throws {
        var captures = 0, errors: [String] = []
        let count = board.changeCount
        let monitor = ClipboardMonitor(settings: SettingsStore(defaults: defaults), pasteboard: board)
        let controller = ScreenshotController(monitor: monitor, pasteboard: board, permission: { true }, capture: { captures += 1; return [] }, listWindows: { [] })
        controller.onError = { errors.append($0) }; controller.start(mode: .window)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(controller.isActive); XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(captures, 0); XCTAssertEqual(board.changeCount, count)
    }

    @MainActor func testExportPreviewFitsMinimumWindowSize() throws {
        _ = NSApplication.shared
        let exporter = ScreenshotExportController(image: try sampleImage())
        let window = try XCTUnwrap(exporter.window)
        defer { exporter.close() }
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(CGSize(width: 760, height: 480))
        let view = try XCTUnwrap(window.contentView); view.layoutSubtreeIfNeeded()
        XCTAssertNotNil(exporter.renderedImage)
        for child in view.subviews { XCTAssertTrue(view.bounds.contains(child.frame), "预览和操作不能溢出窗口") }
    }

    private func sampleImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 128, height: 96, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for x in 0..<128 {
            context.setFillColor(CGColor(gray: x % 8 < 4 ? 0.05 : 0.95, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 1, height: 96))
        }
        return try XCTUnwrap(context.makeImage())
    }
}
