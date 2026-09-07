import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
import ClipboardCore
@testable import PastePal

final class ClipboardCaptureTests: AppTestSupport {
    @MainActor func testMonitorActualPasteboardPauseExcludeAndResume() throws {
        let settings = SettingsStore(defaults: defaults)
        let monitor = ClipboardMonitor(settings: settings, pasteboard: board)
        var captured: [String] = []
        monitor.onCapture = { values, _ in captured.append(String(data: values[0].data, encoding: .utf8)!) }
        try PasteboardIO.write(values("A"), to: board); monitor.poll()
        settings.paused = true
        try PasteboardIO.write(values("暂停"), to: board); monitor.poll()
        XCTAssertEqual(board.string(forType: .string), "暂停")
        settings.paused = false; monitor.resetBaseline(); monitor.poll()
        if let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            settings.excludedApps = [id]
            try PasteboardIO.write(values("排除"), to: board); monitor.poll()
            XCTAssertEqual(board.string(forType: .string), "排除")
        }
        settings.excludedApps = []; monitor.resetBaseline()
        try PasteboardIO.write(values("B"), to: board); monitor.poll()
        XCTAssertEqual(captured, ["A", "B"])
    }

    @MainActor func testTimerRecordsSubsequentChangeAndDoesNotImportStartupClipboard() async throws {
        try PasteboardIO.write(values("启动前"), to: board)
        let monitor = ClipboardMonitor(settings: SettingsStore(defaults: defaults), pasteboard: board)
        var captured = 0
        monitor.onCapture = { _, _ in captured += 1 }
        monitor.start(); defer { monitor.stop() }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(captured, 0)
        try PasteboardIO.write(values("启动后"), to: board)
        try await waitUntil { captured == 1 }
    }
}
