import PastePalLocalization
import XCTest
import AppKit
import ClipboardCore
import KeyboardShortcuts
@testable import PastePal

final class SettingsNavigationTests: XCTestCase {
    @MainActor func testCategorySwitchingPreservesUncommittedRetentionInput() async throws {
        _ = NSApplication.shared
        let suite = "PastePal.SettingsNavigationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("count", forKey: "historyRetentionMode")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(directory: directory, settings: SettingsStore(defaults: defaults), pasteboard: board)
        let controller = SettingsController(model: model)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        XCTAssertEqual(content.bounds.size, NSSize(width: 920, height: 600))
        let sidebar = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first { $0.accessibilityLabel() == L("设置分类") })
        XCTAssertEqual(sidebar.numberOfRows, 5)
        XCTAssertTrue(labels(content).contains(L("常规")))
        sidebar.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let shortcutLabels = labels(content)
        let usageHeadings = [L("历史"), L("分组"), L("截图")]
        XCTAssertFalse(usageHeadings.contains(where: shortcutLabels.contains))
        XCTAssertEqual(descendants(content).compactMap { $0 as? SettingsShortcutRecorder }.count, AppShortcutAction.allCases.count)
        sidebar.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
        let usageLabels = labels(content)
        XCTAssertTrue(usageHeadings.allSatisfy(usageLabels.contains))
        XCTAssertTrue(usageLabels.contains(L("预览所选内容")))
        XCTAssertTrue(descendants(content).compactMap { $0 as? SettingsShortcutRecorder }.isEmpty)
        sidebar.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        XCTAssertFalse(labels(content).contains(L("登录时启动")))
        let mode = try XCTUnwrap(descendants(content).compactMap { $0 as? NSPopUpButton }.first)
        let quantity = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == L("未分组历史保留数量") })
        XCTAssertEqual(mode.itemTitles, [L("天"), L("条")])
        XCTAssertEqual(mode.indexOfSelectedItem, 1)
        XCTAssertTrue(quantity.isEnabled)
        quantity.stringValue = "45"
        XCTAssertEqual(model.settings.retentionMode, .count)
        XCTAssertEqual(model.settings.limit, 10000)
        sidebar.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        sidebar.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        XCTAssertEqual(quantity.stringValue, "45")
        XCTAssertEqual(mode.indexOfSelectedItem, 1)
        window.setContentSize(NSSize(width: 720, height: 360))
        content.layoutSubtreeIfNeeded()
        XCTAssertFalse(controller.hasRefreshTimer)
        controller.close()
    }
    @MainActor func testSwitchingEveryCategoryPreservesDefaultAndUserSizedWindow() async throws {
        _ = NSApplication.shared
        let suite = "PastePal.SettingsWindowSizeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(directory: directory, settings: SettingsStore(defaults: defaults), pasteboard: board)
        let controller = SettingsController(model: model)
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        let sidebar = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first { $0.accessibilityLabel() == L("设置分类") })
        for size in [NSSize(width: 920, height: 600), NSSize(width: 1040, height: 700), NSSize(width: 760, height: 430)] {
            window.setContentSize(size)
            let expected = window.frame
            for category in [1, 2, 3, 4, 0, 4, 3, 1, 0] {
                sidebar.selectRowIndexes(IndexSet(integer: category), byExtendingSelection: false)
                content.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 30_000_000)
                content.layoutSubtreeIfNeeded()
                XCTAssertEqual(window.frame, expected, "分类 \(category) 改变了窗口尺寸 \(size)")
                XCTAssertEqual(content.bounds.size, size)
            }
        }
    }
    @MainActor func testUsageReadsCurrentBindingsAndExpandsCustomizedPositions() throws {
        _ = NSApplication.shared
        let suite = "PastePal.UsageBindingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let board = NSPasteboard.withUniqueName()
        defer { defaults.removePersistentDomain(forName: suite); board.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(directory: directory, settings: SettingsStore(defaults: defaults), pasteboard: board)
        let controller = SettingsController(model: model, screenPermissionCheck: { false }, screenPermissionRequest: { false })
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        let sidebar = try XCTUnwrap(descendants(content).compactMap { $0 as? NSTableView }.first { $0.accessibilityLabel() == L("设置分类") })
        sidebar.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
        XCTAssertTrue(labels(content).contains("⌘1–9"))
        XCTAssertTrue(labels(content).contains(L("未启用")))
        XCTAssertTrue(labels(content).contains(KeyboardShortcuts.getShortcut(for: .showHistory)?.description ?? L("未设置")))

        sidebar.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let store = AppShortcutStore(defaults: defaults, globalShortcuts: { [] })
        let search = KeyboardShortcuts.Shortcut(.y, modifiers: [.command, .option])
        let ninth = KeyboardShortcuts.Shortcut(.u, modifiers: [.command, .option])
        XCTAssertNil(store.setShortcut(search, for: .beginSearch))
        XCTAssertNil(store.setShortcut(ninth, for: .usePosition9))
        model.settings.screenshotEnabled = true
        sidebar.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
        let current = labels(content)
        XCTAssertTrue(current.contains(search.description))
        XCTAssertFalse(current.contains(AppShortcutAction.beginSearch.defaultShortcut.description))
        XCTAssertFalse(current.contains("⌘1–9"))
        XCTAssertTrue(current.contains(ninth.description))
        for action in AppShortcutAction.allCases where action.position != nil {
            XCTAssertEqual(current.filter { $0 == action.title }.count, 1)
        }
        XCTAssertTrue(current.contains(L("开始截屏")))
        XCTAssertFalse(current.contains(L("未启用")))
        XCTAssertFalse(controller.hasRefreshTimer)
    }
    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
    @MainActor private func labels(_ view: NSView) -> [String] {
        descendants(view).compactMap { ($0 as? NSTextField)?.stringValue ?? ($0 as? NSButton)?.title }
    }
}

final class SettingsPersistenceTests: AppTestSupport {
    func testSettingsPersistPauseLimitAndExclusions() {
        let first = SettingsStore(defaults: defaults)
        XCTAssertEqual(first.limit, 10000)
        first.paused = true; first.limit = 5; first.excludedApps = ["com.example.private"]
        let reopened = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertTrue(reopened.paused); XCTAssertEqual(reopened.limit, 5); XCTAssertEqual(reopened.excludedApps, ["com.example.private"])
    }
}
