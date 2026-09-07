import PastePalLocalization
import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
import ClipboardCore
@testable import PastePal

final class WindowResourceLifecycleTests: AppTestSupport {
    @MainActor func testClosedWindowsReleaseRefreshAndPreviewState() async throws {
        _ = NSApplication.shared
        let model = try AppModel(directory: directory, settings: SettingsStore(defaults: defaults), pasteboard: board)
        _ = try model.store.record(ContentCodec.decode(values("预览内容")), limit: 10)
        model.refresh()
        try await waitUntil { model.entries.count == 1 }

        let settings = SettingsController(model: model)
        settings.showWindow(nil)
        XCTAssertTrue(settings.hasRefreshTimer)
        settings.close()
        XCTAssertFalse(settings.hasRefreshTimer)
        settings.showWindow(nil)
        XCTAssertTrue(settings.hasRefreshTimer)
        settings.close()

        let panel = PanelController(model: model)
        panel.show()
        panel.historyView.keyDown(with: try keyEvent(49, " "))
        try await waitUntil { panel.hasPreviewController }
        panel.previewWindow?.close()
        try await waitUntil { !panel.hasPreviewController }
        panel.dismiss()
        XCTAssertTrue(panel.visibleEntryIDs.isEmpty)
    }

    @MainActor func testHiddenSettingsStopPollingAndScreenshotErrorRestoresIt() async throws {
        _ = NSApplication.shared
        let store = SettingsStore(defaults: defaults)
        store.screenshotEnabled = true
        let model = try AppModel(directory: directory, settings: store, pasteboard: board, paste: PasteCoordinator(permission: { true }))
        var permissionChecks = 0
        let settings = SettingsController(model: model, screenPermissionCheck: { permissionChecks += 1; return true })
        defer { settings.close() }
        settings.showWindow(nil)
        let sidebar = try XCTUnwrap(descendants(of: settings.window?.contentView).compactMap { $0 as? NSTableView }.first { $0.accessibilityLabel() == L("设置分类") })
        sidebar.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        XCTAssertTrue(settings.hasRefreshTimer)
        settings.hide()
        settings.hide()
        XCTAssertFalse(settings.window?.isVisible ?? true)
        XCTAssertFalse(settings.hasRefreshTimer)
        let checksWhileHidden = permissionChecks
        try await Task.sleep(for: .milliseconds(2200))
        XCTAssertEqual(permissionChecks, checksWhileHidden)
        settings.showScreenshotError("合成错误")
        XCTAssertTrue(settings.window?.isVisible ?? false)
        XCTAssertTrue(settings.hasRefreshTimer)
        XCTAssertGreaterThan(permissionChecks, checksWhileHidden)
        XCTAssertEqual(sidebar.selectedRow, 3)
    }

    @MainActor func testOnlyDynamicSettingsPagesPollWithoutReloadingExcludedApps() async throws {
        _ = NSApplication.shared
        let store = SettingsStore(defaults: defaults)
        store.screenshotEnabled = true
        store.excludedApps = ["synthetic.one"]
        let model = try AppModel(directory: directory, settings: store, pasteboard: board, paste: PasteCoordinator(permission: { true }))
        var permissionChecks = 0
        let settings = SettingsController(model: model, screenPermissionCheck: { permissionChecks += 1; return true })
        defer { settings.close() }
        settings.showWindow(nil)
        let sidebar = try XCTUnwrap(descendants(of: settings.window?.contentView).compactMap { $0 as? NSTableView }.first { $0.accessibilityLabel() == L("设置分类") })
        for category in [1, 2, 4] {
            sidebar.selectRowIndexes(IndexSet(integer: category), byExtendingSelection: false)
            XCTAssertFalse(settings.hasRefreshTimer)
        }
        sidebar.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertTrue(settings.hasRefreshTimer)
        sidebar.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        settings.window?.resignKey()
        XCTAssertTrue(settings.hasRefreshTimer, "可见但非主窗口仍需刷新动态状态")
        let excluded = try XCTUnwrap(descendants(of: settings.window?.contentView).compactMap { $0 as? NSTableView }.first { $0.accessibilityLabel() == L("不记录的应用") })
        XCTAssertEqual(excluded.numberOfRows, 1)
        store.excludedApps = ["synthetic.one", "synthetic.two"]
        let beforeTick = permissionChecks
        try await Task.sleep(for: .milliseconds(2200))
        XCTAssertGreaterThan(permissionChecks, beforeTick)
        XCTAssertEqual(excluded.numberOfRows, 1, "周期刷新不重载排除应用表")
        sidebar.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
        sidebar.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        XCTAssertEqual(excluded.numberOfRows, 2, "切页时刷新完整内容")
    }

    @MainActor func testExternalOrderOutAndApplicationHideResumeRefresh() async throws {
        _ = NSApplication.shared
        let model = try AppModel(directory: directory, settings: SettingsStore(defaults: defaults), pasteboard: board, paste: PasteCoordinator(permission: { true }))
        let settings = SettingsController(model: model, screenPermissionCheck: { false })
        defer { NSApp.unhide(nil); settings.close() }
        settings.showWindow(nil)
        settings.window?.orderOut(nil)
        try await waitUntil { !settings.hasRefreshTimer }
        XCTAssertFalse(settings.hasRefreshTimer, "外部orderOut后停Timer")
        settings.window?.makeKeyAndOrderFront(nil)
        try await waitUntil { settings.hasRefreshTimer }
        XCTAssertTrue(settings.hasRefreshTimer, "外部orderFront后恢复Timer")
        NSApp.hide(nil)
        try await waitUntil { NSApp.isHidden && !settings.hasRefreshTimer }
        XCTAssertTrue(NSApp.isHidden, "测试进程成功隐藏")
        XCTAssertFalse(settings.hasRefreshTimer, "应用隐藏后停Timer")
        NSApp.unhide(nil)
        try await waitUntil { !NSApp.isHidden && settings.hasRefreshTimer }
        XCTAssertFalse(NSApp.isHidden, "测试进程已恢复")
        XCTAssertTrue(settings.hasRefreshTimer, "应用恢复后启动Timer")
    }

    func testCardCacheDownsamplesDecodedImages() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let width = 1_200, height = 800
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.4, green: 0.2, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let file = directory.appendingPathComponent("large.png")
        try (data as Data).write(to: file)

        let image = try XCTUnwrap(CardImageCache().image(at: file, maximumPixelSize: 480))
        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), 480)
    }
}
