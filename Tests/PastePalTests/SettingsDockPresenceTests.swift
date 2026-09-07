import PastePalLocalization
import XCTest
import AppKit
import ClipboardCore
@testable import PastePal

final class SettingsDockPresenceTests: AppTestSupport {
    @MainActor func testDockFollowsSettingsSessionAndReopenRestoresExistingWindow() async throws {
        _ = NSApplication.shared
        let originalPolicy = NSApp.activationPolicy()
        let model = try AppModel(directory: directory, settings: SettingsStore(defaults: defaults), pasteboard: board)
        let delegate = AppDelegate()
        let settings = delegate.settingsController(for: model)
        defer {
            NSApp.unhide(nil)
            settings.close()
            NSApp.setActivationPolicy(originalPolicy)
        }
        NSApp.setActivationPolicy(.accessory)
        XCTAssertFalse(settings.isPresented)
        settings.showWindow(nil)
        XCTAssertEqual(NSApp.activationPolicy(), .regular)
        XCTAssertTrue(settings.isPresented)
        let window = try XCTUnwrap(settings.window)
        XCTAssertTrue(window.isVisible)
        let sidebar = try XCTUnwrap(descendants(of: window.contentView).compactMap { $0 as? NSTableView }.first { $0.accessibilityLabel() == L("设置分类") })
        sidebar.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        let quantity = try XCTUnwrap(descendants(of: window.contentView).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == L("未分组历史保留数量") })
        quantity.stringValue = "45"
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        XCTAssertEqual(quantity.stringValue, "45", "点击 Dock 保留尚未提交的输入")
        sidebar.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
        window.resignKey()
        XCTAssertEqual(NSApp.activationPolicy(), .regular)

        window.orderOut(nil)
        XCTAssertTrue(settings.isPresented)
        XCTAssertEqual(NSApp.activationPolicy(), .regular)
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        try await waitUntil { window.isVisible }
        XCTAssertTrue(settings.window === window)
        XCTAssertTrue(delegate.settingsController(for: model) === settings)
        XCTAssertEqual(sidebar.selectedRow, 4)
        XCTAssertEqual(NSApp.activationPolicy(), .regular)

        settings.hide()
        XCTAssertFalse(settings.isPresented)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(NSApp.activationPolicy(), .accessory)
        settings.showScreenshotError("合成错误")
        XCTAssertTrue(settings.isPresented)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(NSApp.activationPolicy(), .regular)
        settings.close()
        XCTAssertFalse(settings.isPresented)
        XCTAssertEqual(NSApp.activationPolicy(), .accessory)
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        XCTAssertFalse(settings.isPresented)
        XCTAssertFalse(window.isVisible)
    }
}
