import XCTest
import AppKit
@testable import PastePal

final class ScreenshotPinnedInteractionTests: AppTestSupport {
    func testZoomStepsPreserveAspectRatioAndMinimumHitArea() {
        var zoom = ScreenshotPinnedZoom(originalSize: CGSize(width: 1200, height: 600))
        XCTAssertEqual(zoom.scale, 1)
        XCTAssertEqual(zoom.windowSize, CGSize(width: 1200, height: 600))
        XCTAssertGreaterThan(zoom.scales.count, 40)
        for _ in 0..<200 { _ = zoom.scroll(delta: -1, precise: false) }
        XCTAssertEqual(zoom.imageSize.width, 80, accuracy: 0.001)
        XCTAssertEqual(zoom.imageSize.width / zoom.imageSize.height, 2)
        XCTAssertGreaterThanOrEqual(zoom.windowSize.height, 44)
        for _ in 0..<200 { _ = zoom.scroll(delta: 1, precise: false) }
        XCTAssertEqual(zoom.scale, 2.5)
        XCTAssertFalse(zoom.scroll(delta: 1, precise: false))
        zoom.reset(); XCTAssertEqual(zoom.scale, 1)
        var thin = ScreenshotPinnedZoom(originalSize: CGSize(width: 3000, height: 2))
        for _ in 0..<200 { _ = thin.scroll(delta: -1, precise: false) }
        XCTAssertGreaterThanOrEqual(thin.windowSize.width, 44)
        XCTAssertGreaterThanOrEqual(thin.windowSize.height, 44)
    }

    func testPreciseScrollingAccumulatesAndZoomKeepsMouseAnchor() {
        var zoom = ScreenshotPinnedZoom(originalSize: CGSize(width: 400, height: 200))
        XCTAssertFalse(zoom.scroll(delta: 5, precise: true))
        XCTAssertFalse(zoom.scroll(delta: 5, precise: true))
        XCTAssertTrue(zoom.scroll(delta: 2, precise: true))
        XCTAssertEqual(zoom.scale, 1.05, accuracy: 0.001)
        let old = CGRect(x: -800, y: 200, width: 400, height: 200)
        let anchor = CGPoint(x: -700, y: 250)
        let frame = zoom.frame(anchoredAt: anchor, in: old)
        XCTAssertEqual((anchor.x - frame.minX) / frame.width, 0.25, accuracy: 0.001)
        XCTAssertEqual((anchor.y - frame.minY) / frame.height, 0.25, accuracy: 0.001)
        zoom.resetScroll()
        XCTAssertFalse(zoom.scroll(delta: 2, precise: true))
        XCTAssertFalse(zoom.scroll(delta: .infinity, precise: true))
    }

    @MainActor func testBorderlessPinPreservesCapturePositionAndDoubleClickClosesOnlyPin() throws {
        _ = NSApplication.shared
        let source = try XCTUnwrap(NSBitmapImageRep(data: pngData())?.cgImage)
        let rect = CGRect(x: -600, y: 120, width: 320, height: 200)
        let pin = ScreenshotPinnedImageController(image: source, originalFrame: rect)
        defer { pin.close() }
        let window = try XCTUnwrap(pin.window)
        XCTAssertFalse(window.styleMask.contains(.titled))
        XCTAssertFalse(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.frame, rect)
        XCTAssertEqual(pin.zoom.originalSize, rect.size)
        XCTAssertEqual(pin.zoom.scale, 1)
        XCTAssertFalse(window.isOpaque); XCTAssertFalse(window.hasShadow)
        XCTAssertEqual(window.level, .floating)
        XCTAssertEqual(window.contentView?.subviews.count, 0)
        var closed = 0
        pin.onClose = { closed += 1 }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 30, y: 30),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 2, pressure: 1))
        window.contentView?.mouseDown(with: event)
        XCTAssertEqual(closed, 1)
    }
}
