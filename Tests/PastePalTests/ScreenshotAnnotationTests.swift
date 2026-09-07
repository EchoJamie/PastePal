import XCTest
import AppKit
@testable import PastePal

final class ScreenshotAnnotationTests: XCTestCase {
    func testRectangleUsesGestureColorAndUndoDoesNotChangeEarlierMarks() {
        var model = ScreenshotAnnotationModel()
        model.tool = .rectangle; model.color = .blue
        model.begin(at: CGPoint(x: 30, y: 40)); model.update(to: CGPoint(x: 10, y: 20))
        guard case let .rectangle(preview, previewColor, _) = model.annotations.first else { return XCTFail("缺少矩形预览") }
        XCTAssertEqual(preview, CGRect(x: 10, y: 20, width: 20, height: 20)); XCTAssertEqual(previewColor, .blue)
        model.end(at: CGPoint(x: 10, y: 20))
        model.color = .green; model.tool = .arrow
        model.begin(at: .zero); model.end(at: CGPoint(x: 10, y: 10))
        model.color = .yellow; model.addText("备注", at: .zero)
        guard case let .text(_, _, color, _) = model.annotations.last else { return XCTFail("缺少文字") }
        XCTAssertEqual(color, .yellow)
        model.undo(); model.undo()
        guard case let .rectangle(_, originalColor, _) = model.annotations.first else { return XCTFail("矩形应保留") }
        XCTAssertEqual(originalColor, .blue)
        model.tool = .rectangle; model.begin(at: .zero); model.end(at: CGPoint(x: 0.1, y: 0.1))
        XCTAssertEqual(model.annotations.count, 1)
        model.undo(); XCTAssertTrue(model.annotations.isEmpty)
    }

    func testRectangleExportKeepsInteriorWithMixedColors() throws {
        let context = try makeContext()
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        let frame = ScreenshotFrame(bounds: CGRect(x: -20, y: 100, width: 40, height: 40), image: try XCTUnwrap(context.makeImage()))
        let data = try ScreenshotFrame.png(selection: frame.bounds, frames: [frame], annotations: [
            .rectangle(CGRect(x: -15, y: 105, width: 20, height: 20), color: .blue),
            .arrow(from: CGPoint(x: -15, y: 133), to: CGPoint(x: 5, y: 133), color: .green)
        ])
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(bitmap.pixelsWide, 80); XCTAssertEqual(bitmap.pixelsHigh, 80)
        let border = try XCTUnwrap(bitmap.colorAt(x: 10, y: 50)?.usingColorSpace(.sRGB))
        XCTAssertEqual(border.blueComponent, 1, accuracy: 0.01)
        XCTAssertEqual(border.redComponent, 0.1, accuracy: 0.02)
        let interior = try XCTUnwrap(bitmap.colorAt(x: 30, y: 50)?.usingColorSpace(.sRGB))
        XCTAssertEqual(interior.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(interior.greenComponent, 1, accuracy: 0.01)
        let arrow = try XCTUnwrap(bitmap.colorAt(x: 25, y: 13)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(arrow.greenComponent, 0.65)
        XCTAssertGreaterThan(arrow.greenComponent - arrow.redComponent, 0.3)
        XCTAssertGreaterThan(arrow.greenComponent - arrow.blueComponent, 0.3)
        XCTAssertEqual(arrow.alphaComponent, 1, accuracy: 0.01)
    }

    func testPreviewCommitUndoAndToolChange() {
        var model = ScreenshotAnnotationModel()
        model.tool = .arrow
        model.begin(at: CGPoint(x: -10, y: 20))
        model.update(to: CGPoint(x: 10, y: 30))
        XCTAssertEqual(model.annotations.count, 1)
        model.end(at: CGPoint(x: 20, y: 40))
        XCTAssertEqual(model.annotations.count, 1)
        model.tool = .obscure
        model.begin(at: CGPoint(x: 10, y: 10))
        model.update(to: CGPoint(x: 0, y: 0))
        XCTAssertEqual(model.annotations.count, 2)
        model.undo()
        XCTAssertEqual(model.annotations.count, 1)
        model.addText("备注", at: .zero)
        model.undo()
        XCTAssertEqual(model.annotations.count, 1)
        model.begin(at: .zero)
        model.update(to: CGPoint(x: 5, y: 5))
        model.tool = nil
        XCTAssertEqual(model.annotations.count, 1)
        model.undo()
        XCTAssertFalse(model.canUndo)
    }

    func testInvalidAndEmptyGesturesAreNotCommitted() {
        var model = ScreenshotAnnotationModel()
        model.tool = .arrow
        model.begin(at: .zero)
        model.end(at: CGPoint(x: 0.1, y: 0.1))
        model.addText(" \n ", at: .zero)
        model.begin(at: .zero)
        model.update(to: CGPoint(x: 10, y: 10))
        model.end(at: CGPoint(x: CGFloat.nan, y: 0))
        XCTAssertTrue(model.annotations.isEmpty)
        model.tool = .obscure
        model.begin(at: CGPoint(x: 9, y: 8))
        model.end(at: CGPoint(x: 3, y: 2))
        guard case let .pixelate(rect, _) = model.annotations.first else { return XCTFail("缺少马赛克") }
        XCTAssertEqual(rect, CGRect(x: 3, y: 2, width: 6, height: 6))
    }

    func testTextRendersAboveBaselineAndArrowReachesEndpoint() throws {
        let context = try makeContext()
        ScreenshotAnnotationRenderer.draw(annotations: [.text("HI", at: CGPoint(x: 8, y: 30))], in: context)
        let above = (31..<50).contains { y in (8..<40).contains { pixel(context, x: $0, y: y)[3] > 0 } }
        let below = (0..<29).contains { y in (0..<80).contains { pixel(context, x: $0, y: y)[3] > 0 } }
        XCTAssertTrue(above)
        XCTAssertFalse(below)
        ScreenshotAnnotationRenderer.draw(annotations: [.arrow(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 10))], in: context)
        XCTAssertGreaterThan(pixel(context, x: 59, y: 10)[3], 0)
        XCTAssertEqual(pixel(context, x: 70, y: 10)[3], 0)
    }

    func testExportClipsGlobalCoordinatesWithAnnotation() throws {
        let context = try makeContext()
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        let frame = ScreenshotFrame(bounds: CGRect(x: -20, y: 100, width: 40, height: 40), image: try XCTUnwrap(context.makeImage()))
        let data = try ScreenshotFrame.png(selection: CGRect(x: -10, y: 110, width: 10, height: 10), frames: [frame], annotations: [
            .rectangle(CGRect(x: -12, y: 112, width: 6, height: 4), color: .black, width: 6)
        ])
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(bitmap.pixelsWide, 20)
        XCTAssertEqual(bitmap.pixelsHigh, 20)
        let black = try XCTUnwrap(bitmap.colorAt(x: 2, y: 10)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(black.redComponent, 0, accuracy: 0.001)
        XCTAssertEqual(black.alphaComponent, 1, accuracy: 0.001)
        let white = try XCTUnwrap(bitmap.colorAt(x: 15, y: 10)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(white.redComponent, 1, accuracy: 0.001)
    }

    private func makeContext() throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil, width: 80, height: 80, bitsPerComponent: 8, bytesPerRow: 320,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }

    private func pixel(_ context: CGContext, x: Int, y: Int) -> [UInt8] {
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        // 位图数据从顶行开始；测试传入的是左下原点像素坐标。
        let offset = (context.height - 1 - y) * context.bytesPerRow + x * 4
        return (0..<4).map { bytes[offset + $0] }
    }
}
