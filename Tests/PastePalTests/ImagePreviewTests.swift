import AppKit
import ClipboardCore
import XCTest
@testable import PastePal

final class ImagePreviewTests: AppTestSupport {
    @MainActor func testFitCentersImageAcrossViewportSizes() throws {
        for size in [NSSize(width: 600, height: 180), NSSize(width: 601, height: 181), NSSize(width: 1408, height: 364), NSSize(width: 1408, height: 331)] {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let scroll = PreviewImageView(image: NSImage(size: NSSize(width: 3200, height: 1800)))
            scroll.wantsLayer = true
            window.contentView = scroll
            window.layoutIfNeeded()
            scroll.layoutSubtreeIfNeeded()
            try assertImageFitsAndIsCentered(scroll)
            scroll.toggleZoom(at: .zero)
            XCTAssertEqual(scroll.magnification, 1, accuracy: 0.001)
            scroll.toggleZoom(at: .zero)
            try assertImageFitsAndIsCentered(scroll)
        }
    }

    @MainActor func testLargeImageKeepsPixelsAndSupportsZoomPanAndFitWithoutResizingPanel() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 3200, height: 1800, bitsPerComponent: 8, bytesPerRow: 12800, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3200, height: 1800))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 1600, y: 0, width: 1, height: 1800))
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let (model, panel) = try await makePanel([])
        defer { panel.dismiss() }
        _ = try model.store.record(ContentCodec.decode([Representation(type: "public.png", data: png)]), limit: 10)
        panel.prepareForDisplay()
        let window = try XCTUnwrap(panel.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1440, height: PanelLayout.height), display: false)
        window.layoutIfNeeded()
        panel.historyView.keyDown(with: try keyEvent(49, " "))
        try await waitUntil { panel.isPreviewVisible }
        window.layoutIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(descendants(of: panel.previewView).compactMap { $0 as? PreviewImageView }.first)
        scroll.layoutSubtreeIfNeeded()
        let canvas = try XCTUnwrap(scroll.documentView)
        XCTAssertEqual(scroll.image.size, NSSize(width: 3200, height: 1800))
        let decoded = try XCTUnwrap(scroll.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(decoded.width, 3200)
        let pixels = NSBitmapImageRep(cgImage: decoded)
        XCTAssertLessThan(try XCTUnwrap(pixels.colorAt(x: 1600, y: 900)?.usingColorSpace(.sRGB)).redComponent, 0.01)
        XCTAssertGreaterThan(try XCTUnwrap(pixels.colorAt(x: 1599, y: 900)?.usingColorSpace(.sRGB)).redComponent, 0.99)
        XCTAssertGreaterThan(scroll.frame.width, 760, "图片不受文本阅读宽度限制")
        XCTAssertEqual(scroll.magnification, scroll.fitScale, accuracy: 0.001)
        try assertImageFitsAndIsCentered(scroll)
        XCTAssertTrue(scroll.allowsMagnification)
        let frame = window.frame
        let point = canvas.convert(CGPoint(x: 1600, y: 900), to: nil)
        func mouse(_ type: NSEvent.EventType, _ location: NSPoint, clicks: Int = 1) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1))
        }
        canvas.mouseDown(with: try mouse(.leftMouseDown, point, clicks: 2))
        XCTAssertEqual(scroll.magnification, 1, accuracy: 0.001)
        let origin = scroll.contentView.bounds.origin
        canvas.mouseDown(with: try mouse(.leftMouseDown, point))
        let end = CGPoint(x: point.x - 100, y: point.y - 50)
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, end))
        canvas.mouseUp(with: try mouse(.leftMouseUp, end))
        XCTAssertEqual(scroll.contentView.bounds.origin.x, origin.x + 100, accuracy: 1)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, origin.y + 50, accuracy: 1)
        let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0))
        scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: wheel)))
        XCTAssertGreaterThan(scroll.magnification, 1)
        canvas.mouseDown(with: try mouse(.leftMouseDown, point, clicks: 2))
        XCTAssertEqual(scroll.magnification, scroll.fitScale, accuracy: 0.001)
        try assertImageFitsAndIsCentered(scroll)
        XCTAssertEqual(window.frame, frame)
        XCTAssertTrue(panel.isCollectionFocused)
        panel.historyView.keyDown(with: try keyEvent(53, ""))
        XCTAssertFalse(panel.isPreviewVisible)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor private func assertImageFitsAndIsCentered(_ scroll: PreviewImageView, file: StaticString = #filePath, line: UInt = #line) throws {
        let canvas = try XCTUnwrap(scroll.documentView, file: file, line: line)
        // 用显示像素判断对齐；原图坐标中的固定容差会随缩放比例改变实际精度。
        let image = scroll.convertToBacking(scroll.convert(canvas.bounds, from: canvas))
        let viewport = scroll.convertToBacking(scroll.convert(scroll.contentView.bounds, from: scroll.contentView))
        XCTAssertEqual(image.midX, viewport.midX, accuracy: 1, file: file, line: line)
        XCTAssertEqual(image.midY, viewport.midY, accuracy: 1, file: file, line: line)
        XCTAssertGreaterThanOrEqual(image.minX, viewport.minX - 1, file: file, line: line)
        XCTAssertLessThanOrEqual(image.maxX, viewport.maxX + 1, file: file, line: line)
        XCTAssertGreaterThanOrEqual(image.minY, viewport.minY - 1, file: file, line: line)
        XCTAssertLessThanOrEqual(image.maxY, viewport.maxY + 1, file: file, line: line)
    }
}
