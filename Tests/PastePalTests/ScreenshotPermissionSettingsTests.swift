import PastePalLocalization
import XCTest
import AppKit
@testable import PastePal

final class ScreenshotPermissionSettingsTests: AppTestSupport {
    @MainActor func testDisabledCaptureDoesNotRequestAndUserRequestDoesNotCaptureOrRepeat() throws {
        _ = NSApplication.shared
        let settings = SettingsStore(defaults: defaults)
        let model = try AppModel(directory: directory, settings: settings, pasteboard: board)
        var requests = 0
        let before = board.changeCount
        let controller = SettingsController(model: model, screenPermissionCheck: { false }, screenPermissionRequest: { requests += 1; return false })
        defer { controller.close() }
        let content = try XCTUnwrap(controller.window?.contentView)
        let sidebar = try XCTUnwrap(views(content).compactMap { $0 as? NSTableView }.first { $0.accessibilityLabel() == L("设置分类") })
        sidebar.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        let request = try XCTUnwrap(views(content).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == L("请求屏幕录制权限") })
        XCTAssertFalse(request.isEnabled)
        _ = request.sendAction(request.action, to: request.target)
        XCTAssertEqual(requests, 0)
        sidebar.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let enabled = try XCTUnwrap(views(content).compactMap { $0 as? NSButton }.first { $0.title == L("启用区域截屏") })
        enabled.state = .on; _ = enabled.sendAction(enabled.action, to: enabled.target)
        sidebar.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        XCTAssertEqual(requests, 0)
        XCTAssertTrue(request.isEnabled)
        request.performClick(nil)
        XCTAssertEqual(requests, 1)
        XCTAssertFalse(request.isEnabled)
        _ = request.sendAction(request.action, to: request.target)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(board.changeCount, before)
        XCTAssertTrue(settings.screenshotEnabled)
    }
    @MainActor func testAlreadyGrantedDoesNotRequestAgain() throws {
        _ = NSApplication.shared
        let settings = SettingsStore(defaults: defaults); settings.screenshotEnabled = true
        let model = try AppModel(directory: directory, settings: settings, pasteboard: board)
        var requests = 0
        let controller = SettingsController(model: model, screenPermissionCheck: { true }, screenPermissionRequest: { requests += 1; return true })
        defer { controller.close() }
        let content = try XCTUnwrap(controller.window?.contentView)
        let sidebar = try XCTUnwrap(views(content).compactMap { $0 as? NSTableView }.first { $0.accessibilityLabel() == L("设置分类") })
        sidebar.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        let request = try XCTUnwrap(views(content).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == L("请求屏幕录制权限") })
        XCTAssertFalse(request.isEnabled)
        _ = request.sendAction(request.action, to: request.target)
        XCTAssertEqual(requests, 0)
    }
    @MainActor private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { views($0) } }
}
