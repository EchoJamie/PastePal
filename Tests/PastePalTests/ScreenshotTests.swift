import XCTest
import AppKit
import ClipboardCore
import KeyboardShortcuts
@testable import PastePal

final class ScreenshotTests: AppTestSupport {
    @MainActor func testScreenshotUsesMonitorOnceAndAttributesOwnApplication() throws {
        let settings = SettingsStore(defaults: defaults)
        let monitor = ClipboardMonitor(settings: settings, pasteboard: board)
        let controller = ScreenshotController(monitor: monitor, pasteboard: board, permission: { false }, capture: { [] })
        var sources: [SourceApplication?] = []
        monitor.onCapture = { _, source in sources.append(source) }
        try controller.writePNG(pngData())
        monitor.poll(); monitor.poll()
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first??.bundleID, AppIdentity.bundleID)
        XCTAssertEqual(sources.first??.name, AppIdentity.displayName)
        XCTAssertNotNil(board.data(forType: .png))
    }

    @MainActor func testDeniedPermissionAndCancelLeaveClipboardUntouched() throws {
        try PasteboardIO.write(values("保留"), to: board)
        let count = board.changeCount
        let monitor = ClipboardMonitor(settings: SettingsStore(defaults: defaults), pasteboard: board)
        var permissionCalls = 0, captures = 0
        let controller = ScreenshotController(monitor: monitor, pasteboard: board, permission: { permissionCalls += 1; return false }, capture: { captures += 1; return [] })
        XCTAssertEqual(permissionCalls, 0)
        controller.start(); controller.cancel()
        XCTAssertEqual(permissionCalls, 1)
        XCTAssertEqual(captures, 0)
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(board.changeCount, count)
        XCTAssertEqual(board.string(forType: .string), "保留")
    }

    @MainActor func testCancelDuringCaptureDoesNotWriteOrKeepSessionActive() async throws {
        try PasteboardIO.write(values("原内容"), to: board)
        let count = board.changeCount
        let monitor = ClipboardMonitor(settings: SettingsStore(defaults: defaults), pasteboard: board)
        let controller = ScreenshotController(monitor: monitor, pasteboard: board, permission: { true }, capture: {
            try await Task.sleep(for: .seconds(1))
            return []
        })
        controller.start(); controller.cancel()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(board.changeCount, count)
    }

    @MainActor func testPausedScreenshotDoesNotBypassRecordingPolicy() throws {
        let settings = SettingsStore(defaults: defaults); settings.paused = true
        let monitor = ClipboardMonitor(settings: settings, pasteboard: board)
        var captures = 0; monitor.onCapture = { _, _ in captures += 1 }
        let controller = ScreenshotController(monitor: monitor, pasteboard: board, permission: { false }, capture: { [] })
        try controller.writePNG(pngData())
        XCTAssertEqual(captures, 0)
        XCTAssertNotNil(board.data(forType: .png))
    }

    func testNegativeScreenCoordinatesAndRetinaCrop() throws {
        let image = try XCTUnwrap(NSBitmapImageRep(data: pngData())?.cgImage)
        let frame = ScreenshotFrame(bounds: CGRect(x: -16, y: 100, width: 16, height: 10), image: image)
        XCTAssertEqual(frame.pixelCrop(for: CGRect(x: -12, y: 102, width: 4, height: 3)), CGRect(x: 8, y: 10, width: 8, height: 6))
        let other = ScreenshotFrame(bounds: CGRect(x: 0, y: 100, width: 32, height: 20), image: image)
        let result = try ScreenshotFrame.png(selection: CGRect(x: -8, y: 102, width: 16, height: 6), frames: [frame, other])
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: result))
        XCTAssertEqual(bitmap.pixelsWide, 32)
        XCTAssertEqual(bitmap.pixelsHigh, 12)
    }

    @MainActor func testGroupShortcutRejectsScreenshotCollision() {
        let shortcut = KeyboardShortcuts.Shortcut(.s, modifiers: [.control, .option])
        let store = GroupShortcutStore(defaults: defaults, globalShortcut: { nil }, screenshotShortcut: { shortcut })
        XCTAssertNotNil(store.validationError(for: shortcut, direction: .next))
    }
}
