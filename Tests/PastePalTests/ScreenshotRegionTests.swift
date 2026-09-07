import XCTest
import AppKit
@testable import PastePal

final class ScreenshotRegionTests: AppTestSupport {
    func testReleaseKeepsSelectionForAdjustment() {
        var model = ScreenshotRegionModel(desktopBounds: CGRect(x: -500, y: -200, width: 1000, height: 800))
        model.begin(at: CGPoint(x: -200, y: -100))
        model.end(at: CGPoint(x: 100, y: 200))
        XCTAssertEqual(model.selection, CGRect(x: -200, y: -100, width: 300, height: 300))
        XCTAssertFalse(model.isDragging)
        model.begin(at: CGPoint(x: -100, y: 0))
        model.end(at: CGPoint(x: 0, y: 100))
        XCTAssertEqual(model.selection, CGRect(x: -100, y: 0, width: 300, height: 300))
    }

    func testResizeEachCornerAndClampToDesktop() {
        for (start, end, expected) in [
            (CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 0), CGRect(x: 0, y: 0, width: 100, height: 100)),
            (CGPoint(x: 100, y: 100), CGPoint(x: 150, y: 160), CGRect(x: 10, y: 10, width: 140, height: 150)),
            (CGPoint(x: 10, y: 100), CGPoint(x: 0, y: 120), CGRect(x: 0, y: 10, width: 100, height: 110)),
            (CGPoint(x: 100, y: 10), CGPoint(x: 120, y: 0), CGRect(x: 10, y: 0, width: 110, height: 100))
        ] {
            var model = ScreenshotRegionModel(desktopBounds: CGRect(x: 0, y: 0, width: 200, height: 200))
            model.begin(at: CGPoint(x: 10, y: 10)); model.end(at: CGPoint(x: 100, y: 100))
            model.begin(at: start); model.end(at: end)
            XCTAssertEqual(model.selection, expected)
        }
        var model = ScreenshotRegionModel(desktopBounds: CGRect(x: 0, y: 0, width: 200, height: 200))
        model.begin(at: CGPoint(x: 10, y: 10)); model.end(at: CGPoint(x: 100, y: 100))
        model.begin(at: CGPoint(x: 50, y: 50)); model.end(at: CGPoint(x: 500, y: 500))
        XCTAssertEqual(model.selection, CGRect(x: 110, y: 110, width: 90, height: 90))
    }

    func testMixedRetinaScreensPreserveTopBottomColorsAcrossSeam() throws {
        func image(scale: Int, bottom: CGColor, top: CGColor) throws -> CGImage {
            let context = try XCTUnwrap(CGContext(data: nil, width: 4 * scale, height: 4 * scale, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(bottom); context.fill(CGRect(x: 0, y: 0, width: 4 * scale, height: 2 * scale))
            context.setFillColor(top); context.fill(CGRect(x: 0, y: 2 * scale, width: 4 * scale, height: 2 * scale))
            return try XCTUnwrap(context.makeImage())
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let red = CGColor(colorSpace: space, components: [1, 0, 0, 1])!, blue = CGColor(colorSpace: space, components: [0, 0, 1, 1])!
        let green = CGColor(colorSpace: space, components: [0, 1, 0, 1])!, yellow = CGColor(colorSpace: space, components: [1, 1, 0, 1])!
        let frames = [ScreenshotFrame(bounds: CGRect(x: -4, y: 10, width: 4, height: 4), image: try image(scale: 2, bottom: red, top: blue)),
                      ScreenshotFrame(bounds: CGRect(x: 0, y: 10, width: 4, height: 4), image: try image(scale: 1, bottom: green, top: yellow))]
        let data = try ScreenshotFrame.png(selection: CGRect(x: -2, y: 11, width: 4, height: 2), frames: frames)
        let result = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(result.pixelsWide, 8); XCTAssertEqual(result.pixelsHigh, 4)
        for (x, y, expected) in [(1, 0, [0.0, 0.0, 1.0]), (1, 3, [1.0, 0.0, 0.0]),
                                 (6, 0, [1.0, 1.0, 0.0]), (6, 3, [0.0, 1.0, 0.0])] {
            var pixel = [Int](repeating: 0, count: 4)
            result.getPixel(&pixel, atX: x, y: y)
            XCTAssertEqual(pixel, expected.map { Int($0 * 255) } + [255])
        }
    }

    @MainActor func testSelectionOnlyCompletesOnceOnExplicitConfirmation() throws {
        let image = try XCTUnwrap(NSBitmapImageRep(data: pngData())?.cgImage)
        var completions: [CGRect?] = []
        let session = ScreenshotSelection(frames: [ScreenshotFrame(bounds: CGRect(x: 0, y: 0, width: 320, height: 200), image: image)]) { completions.append($0) }
        session.handleDrag(.begin, at: CGPoint(x: 10, y: 10))
        session.handleDrag(.end, at: CGPoint(x: 100, y: 100))
        XCTAssertTrue(completions.isEmpty)
        session.confirm(); session.confirm(); session.cancel()
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions[0], CGRect(x: 10, y: 10, width: 90, height: 90))
    }

    @MainActor func testCancelDoesNotConfirmAndSessionIsReleased() throws {
        let image = try XCTUnwrap(NSBitmapImageRep(data: pngData())?.cgImage)
        var completions: [CGRect?] = []
        weak var released: ScreenshotSelection?
        do {
            let session = ScreenshotSelection(frames: [ScreenshotFrame(bounds: CGRect(x: 0, y: 0, width: 320, height: 200), image: image)]) { completions.append($0) }
            released = session
            session.handleDrag(.begin, at: CGPoint(x: 10, y: 10))
            session.handleDrag(.end, at: CGPoint(x: 100, y: 100))
            session.cancel(); session.confirm()
        }
        XCTAssertEqual(completions.count, 1)
        XCTAssertNil(completions[0])
        XCTAssertNil(released)
    }
}
