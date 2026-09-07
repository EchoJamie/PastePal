import XCTest
import AppKit
import KeyboardShortcuts
@testable import PastePal

final class PanelShortcutRoutingTests: AppTestSupport {
    @MainActor func testReboundSearchAndGroupActionsRemoveOldKeysAndUpdateHints() async throws {
        let (model, panel) = try await makePanel(["内容"])
        defer { panel.dismiss() }
        panel.window?.makeKeyAndOrderFront(nil)
        _ = try model.store.createGroup(name: "工作")
        model.refresh(); try await waitUntil { model.groups.count == 1 }
        let store = AppShortcutStore(defaults: defaults, globalShortcuts: { [] })
        XCTAssertNil(store.setShortcut(.init(.f, modifiers: [.command, .shift]), for: .beginSearch))
        XCTAssertNil(store.setShortcut(.init(.g, modifiers: [.command, .shift]), for: .addToGroup))
        let window = try XCTUnwrap(panel.window)
        XCTAssertFalse(window.performKeyEquivalent(with: try keyEvent(3, "f", modifiers: .command)))
        XCTAssertFalse(panel.historyView.performKeyEquivalent(with: try keyEvent(5, "g", modifiers: .command)))
        XCTAssertFalse(panel.isGroupJoinVisible)
        XCTAssertEqual(panel.interactionMode, .cards)
        XCTAssertTrue(panel.shortcutHintControl.toolTip?.contains(store.display(for: .addToGroup)) == true)
        window.sendEvent(try keyEvent(5, "g", modifiers: [.command, .shift]))
        XCTAssertTrue(panel.isGroupJoinVisible)
        window.sendEvent(try keyEvent(53, ""))
        window.sendEvent(try keyEvent(3, "f", modifiers: [.command, .shift]))
        XCTAssertEqual(panel.interactionMode, .search)
        let editor = try XCTUnwrap(panel.searchControl.currentEditor() as? NSTextView)
        editor.setMarkedText("候选", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(window.performKeyEquivalent(with: try keyEvent(3, "f", modifiers: [.command, .shift])))
        XCTAssertTrue(editor.hasMarkedText())
        editor.unmarkText()
        panel.cancelSearch()
        panel.showGroupEditor(groupID: nil)
        XCTAssertFalse(window.performKeyEquivalent(with: try keyEvent(3, "f", modifiers: [.command, .shift])))
        XCTAssertNotNil(panel.groupCreationView)
        XCTAssertNil(board.string(forType: .string))
    }

    @MainActor func testReboundPositionUsesConfiguredCardAndRefreshesVisibleLabel() async throws {
        let (model, panel) = try await makePanel(["第一内容", "第二内容"])
        defer { panel.dismiss() }
        panel.window?.makeKeyAndOrderFront(nil)
        let store = AppShortcutStore(defaults: defaults, globalShortcuts: { [] })
        XCTAssertNil(store.setShortcut(.init(.one, modifiers: [.command, .shift]), for: .usePosition1))
        panel.window?.contentView?.layoutSubtreeIfNeeded()
        let item = try XCTUnwrap(panel.historyView.item(at: IndexPath(item: 0, section: 0)) as? CardItem)
        XCTAssertEqual(item.card.positionShortcut, store.display(for: .usePosition1))
        XCTAssertFalse(panel.historyView.performKeyEquivalent(with: try keyEvent(18, "1", modifiers: .command)))
        XCTAssertNil(board.string(forType: .string))
        let expected = try XCTUnwrap(model.entries.first { $0.id == panel.visibleEntryIDs.first }?.text)
        model.paste.invalidate(); model.onFeedback = nil
        panel.window?.sendEvent(try keyEvent(18, "1", modifiers: [.command, .shift]))
        try await waitUntil { board.string(forType: .string) == expected }
    }

    @MainActor func testReboundPlainTextDoesNotLeaveOptionReturnActive() async throws {
        let (model, panel) = try await makePanel(["纯文本"])
        defer { panel.dismiss() }
        panel.window?.makeKeyAndOrderFront(nil)
        let store = AppShortcutStore(defaults: defaults, globalShortcuts: { [] })
        XCTAssertNil(store.setShortcut(.init(.return, modifiers: .control), for: .usePlainText))
        panel.historyView.keyDown(with: try keyEvent(36, "\r", modifiers: .option))
        XCTAssertNil(board.string(forType: .string))
        XCTAssertTrue(panel.shortcutHintControl.toolTip?.contains(store.display(for: .usePlainText)) == true)
        model.paste.invalidate(); model.onFeedback = nil
        panel.window?.sendEvent(try keyEvent(76, "\r", modifiers: .control))
        try await waitUntil { board.string(forType: .string) == "纯文本" }
    }

    @MainActor func testSettingsAndQuitCombinationsRemainAvailableToMainMenuDuringGroupEditing() async throws {
        let (_, panel) = try await makePanel(["保留"])
        defer { panel.dismiss() }
        panel.window?.makeKeyAndOrderFront(nil)
        let previousMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMenu }
        let menu = NSMenu()
        let owner = ShortcutMenuTarget()
        for (title, key) in [("测试设置", ","), ("测试退出", "q")] {
            let item = NSMenuItem(title: title, action: #selector(ShortcutMenuTarget.record(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = .command
            item.target = owner
            menu.addItem(item)
        }
        NSApp.mainMenu = menu
        panel.showGroupEditor(groupID: nil)
        let window = try XCTUnwrap(panel.window)
        for (code, characters) in [(UInt16(43), ","), (UInt16(12), "q")] {
            let event = try keyEvent(code, characters, modifiers: .command)
            let handled = window.performKeyEquivalent(with: event)
            if !handled { XCTAssertTrue(menu.performKeyEquivalent(with: event)) }
        }
        XCTAssertEqual(owner.actions, ["测试设置", "测试退出"])
        XCTAssertNotNil(panel.groupCreationView)
        XCTAssertNil(board.string(forType: .string))
    }
}

private final class ShortcutMenuTarget: NSObject {
    var actions: [String] = []
    @objc func record(_ sender: NSMenuItem) { actions.append(sender.title) }
}
