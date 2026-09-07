import PastePalLocalization
import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
import ClipboardCore
@testable import PastePal

final class SearchInteractionTests: AppTestSupport {
    @MainActor func testPanelStartsOnFirstCardAndSearchReturnOnlyCompletesSearch() async throws {
        let (model, panel) = try await makePanel(["其他内容", "命中内容"])
        panel.show()
        XCTAssertEqual(panel.interactionMode, .cards)
        XCTAssertTrue(panel.isCollectionFocused)
        XCTAssertEqual(panel.selectedEntryID, model.entries.first?.id)
        XCTAssertTrue(panel.isGroupToolbarVisible)
        XCTAssertFalse(panel.isSearchControlVisible)
        XCTAssertTrue(panel.isNewGroupControlVisible)

        panel.beginSearch(selectAll: false)
        panel.searchControl.stringValue = "命中"
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: panel.searchControl))
        let before = board.changeCount
        let window = try XCTUnwrap(panel.window)
        XCTAssertNotNil(panel.searchControl.currentEditor() as? NSTextView)
        window.sendEvent(try keyEvent(36, "\r"))

        XCTAssertEqual(panel.interactionMode, .cards)
        XCTAssertTrue(panel.isCollectionFocused)
        XCTAssertEqual(panel.visibleQuery, "命中")
        XCTAssertTrue(panel.isSearchControlVisible, "完成搜索后查询必须保持可见")
        XCTAssertFalse(panel.isGroupToolbarVisible)
        XCTAssertEqual(panel.visibleEntryIDs.count, 1)
        XCTAssertEqual(panel.selectedEntryID, panel.visibleEntryIDs.first)
        XCTAssertEqual(board.changeCount, before)
        XCTAssertFalse(model.busy)

        model.paste.invalidate(); model.onFeedback = nil
        window.sendEvent(try keyEvent(36, "\r"))
        try await waitUntil { board.string(forType: .string) == "命中内容" && !panel.isVisible }
    }

    @MainActor func testEmptyQueryRemainsSearchingAndCancelRestoresPreviousCard() async throws {
        let (_, panel) = try await makePanel(["第一条", "第二条", "第三条"])
        let original = panel.visibleEntryIDs[1]
        panel.collectionView(panel.historyView, didSelectItemsAt: [IndexPath(item: 1, section: 0)])
        XCTAssertEqual(panel.selectedEntryID, original)

        panel.beginSearch(selectAll: false)
        panel.searchControl.stringValue = "没有结果"
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: panel.searchControl))
        try await waitUntil { panel.visibleEntryIDs.isEmpty }
        panel.searchControl.stringValue = ""
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: panel.searchControl))
        try await waitUntil { panel.visibleEntryIDs.count == 3 }

        XCTAssertEqual(panel.interactionMode, .search)
        XCTAssertEqual(panel.visibleQuery, "")
        XCTAssertTrue(panel.isSearchControlVisible, "清空关键词时仍应保持搜索编辑态")
        XCTAssertFalse(panel.isGroupToolbarVisible)
        XCTAssertEqual(panel.selectedEntryID, panel.visibleEntryIDs.first)
        let editor = try XCTUnwrap(panel.searchControl.currentEditor() as? NSTextView)
        XCTAssertTrue(panel.control(panel.searchControl, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(panel.interactionMode, .cards)
        XCTAssertEqual(panel.visibleQuery, "")
        XCTAssertEqual(panel.selectedEntryID, original)
        XCTAssertFalse(panel.isSearchControlVisible)
        XCTAssertTrue(panel.isGroupToolbarVisible)
    }

    @MainActor func testCenteredSearchTriggerHasNoDefaultGroupLabelAndRestoresHistory() async throws {
        let (_, panel) = try await makePanel(["命中文字", "其他"])
        panel.window?.makeKeyAndOrderFront(nil)
        panel.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(panel.isGroupToolbarVisible)
        XCTAssertFalse(panel.isSearchControlVisible)
        XCTAssertNotNil(panel.searchTriggerControl.image)
        XCTAssertTrue(panel.groupLabelTitles.isEmpty, "尚无自定义分组时不显示虚构标签")
        XCTAssertFalse(descendants(of: panel.window?.contentView).contains { $0 is NSSegmentedControl })
        XCTAssertEqual(panel.preferredPanelHeight, 356)
        let cardSize = try XCTUnwrap((panel.historyView.collectionViewLayout as? NSCollectionViewFlowLayout)?.itemSize)
        XCTAssertGreaterThan(cardSize.height, 248)
        XCTAssertEqual(cardSize.width / cardSize.height, 238.0 / 248.0, accuracy: 0.001)
        XCTAssertEqual(panel.visibleToolbarCenterOffset, 0, accuracy: 0.5)

        panel.searchTriggerControl.performClick(nil)
        panel.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.interactionMode, .search)
        XCTAssertTrue(panel.isSearchControlVisible)
        XCTAssertFalse(panel.isGroupToolbarVisible)
        XCTAssertEqual(panel.searchScopeText, "")
        XCTAssertFalse(panel.isSearchScopeControlVisible, "完整历史搜索不显示范围胶囊")
        XCTAssertFalse(panel.isNewGroupControlVisible)
        XCTAssertEqual(panel.visibleToolbarCenterOffset, 0, accuracy: 0.5)
        XCTAssertNotNil(panel.searchControl.currentEditor())

        panel.searchControl.stringValue = "命中"
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: panel.searchControl))
        panel.finishSearch()
        XCTAssertEqual(panel.interactionMode, .cards)
        XCTAssertEqual(panel.visibleQuery, "命中")
        XCTAssertTrue(panel.isSearchControlVisible)
        XCTAssertFalse(panel.isGroupToolbarVisible)
        XCTAssertTrue(panel.isCollectionFocused)

        panel.beginSearch(selectAll: true)
        panel.cancelSearch()
        panel.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.visibleQuery, "")
        XCTAssertTrue(panel.isGroupToolbarVisible)
        XCTAssertFalse(panel.isSearchControlVisible)
        XCTAssertEqual(panel.visibleToolbarCenterOffset, 0, accuracy: 0.5)
    }

    @MainActor func testGroupSearchCancelAndDeleteRestoreScopeWithoutDeletingEntry() async throws {
        let (model, panel) = try await makePanel(["组内命中", "组内其它", "组外内容"])
        let group = try model.store.createGroup(name: "项目")
        let first = try XCTUnwrap(model.entries.first { $0.text == "组内命中" })
        let second = try XCTUnwrap(model.entries.first { $0.text == "组内其它" })
        try model.store.add(entryID: first.id, toGroup: group.id)
        try model.store.add(entryID: second.id, toGroup: group.id)
        model.refresh(); try await waitUntil { model.groups.count == 1 }
        panel.prepareForDisplay(); panel.window?.makeKeyAndOrderFront(nil); panel.selectGroup(group.id)
        XCTAssertEqual(panel.contextualDeleteTitle, L("从「\("项目")」移除所选（Delete）"))
        panel.collectionView(panel.historyView, didSelectItemsAt: [IndexPath(item: 1, section: 0)])
        let original = panel.selectedEntryID

        panel.beginSearch(selectAll: false)
        XCTAssertEqual(panel.searchScopeText, "项目  ×")
        XCTAssertTrue(panel.isSearchScopeControlVisible)
        panel.searchControl.stringValue = "命中"
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: panel.searchControl))
        try await waitUntil { panel.visibleEntryIDs == [first.id] }
        panel.cancelSearch()
        XCTAssertEqual(panel.selectedGroupID, group.id)
        XCTAssertEqual(panel.selectedEntryID, original)
        XCTAssertEqual(panel.visibleEntryIDs.count, 2)

        panel.historyView.keyDown(with: try keyEvent(51, String(UnicodeScalar(NSDeleteCharacter)!)))
        try await waitUntil { !model.entryIDs(in: group.id).contains(original!) }
        XCTAssertTrue(model.entries.contains { $0.id == original }, "组内 Delete 只解除当前组归属")
        panel.selectGroup(group.id)
        XCTAssertNil(panel.selectedGroupID)
        XCTAssertEqual(panel.contextualDeleteTitle, L("永久删除所选（Delete）"))
        XCTAssertTrue(panel.visibleEntryIDs.contains(original!))
    }

    @MainActor func testSearchScopeChipKeyboardRemovalExpandsResultsAndEscapeRestoresOrigin() async throws {
        let (model, panel) = try await makePanel(["组内命中", "组外命中", "其它"])
        let group = try model.store.createGroup(name: "很长的工作项目分组名称用于验证胶囊截断显示")
        let inside = try XCTUnwrap(model.entries.first { $0.text == "组内命中" })
        let outside = try XCTUnwrap(model.entries.first { $0.text == "组外命中" })
        try model.store.add(entryID: inside.id, toGroup: group.id)
        model.refresh(); try await waitUntil { model.groups.count == 1 }
        panel.show(); panel.selectGroup(group.id)
        let original = panel.selectedEntryID

        panel.beginSearch(selectAll: false)
        panel.searchControl.stringValue = "命中"
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: panel.searchControl))
        try await waitUntil { panel.visibleEntryIDs == [inside.id] }
        XCTAssertTrue(panel.isSearchScopeControlVisible)
        XCTAssertEqual(panel.activeSearchScopeGroupID, group.id)
        XCTAssertEqual(panel.searchScopeControl.toolTip, L("搜索范围：\(group.name)。移除后搜索完整历史"))
        panel.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(panel.searchScopeControl.frame.width, 150.5)

        XCTAssertTrue(panel.window?.makeFirstResponder(panel.searchScopeControl) == true)
        panel.window?.sendEvent(try keyEvent(49, " "))
        XCTAssertNil(panel.activeSearchScopeGroupID)
        XCTAssertFalse(panel.isSearchScopeControlVisible)
        XCTAssertEqual(Set(panel.visibleEntryIDs), Set([inside.id, outside.id]))
        XCTAssertEqual(panel.selectedGroupID, group.id, "移除范围不能覆盖搜索前视图")

        panel.beginSearch(selectAll: false)
        let editor = try XCTUnwrap(panel.searchControl.currentEditor() as? NSTextView)
        XCTAssertTrue(panel.control(panel.searchControl, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(panel.selectedGroupID, group.id)
        XCTAssertEqual(panel.selectedEntryID, original)
        XCTAssertEqual(panel.visibleEntryIDs, [inside.id])
        XCTAssertFalse(panel.isSearchControlVisible)
        XCTAssertTrue(panel.isNewGroupControlVisible)
    }

    @MainActor func testSearchEditorDoesNotOverlapIconAndHistoryHasNoScrollers() async throws {
        let (_, panel) = try await makePanel(["文本"])
        panel.show(); panel.beginSearch(selectAll: false)
        panel.window?.contentView?.layoutSubtreeIfNeeded()
        let search = panel.searchControl
        let cell = try XCTUnwrap(search.cell as? NSSearchFieldCell)
        let icon = cell.searchButtonRect(forBounds: search.bounds)
        let editor = try XCTUnwrap(search.currentEditor() as? NSTextView)
        let textRect = editor.convert(editor.bounds, to: search)
        XCTAssertGreaterThanOrEqual(textRect.minX, icon.maxX)
        XCTAssertFalse(panel.historyScrollView.hasHorizontalScroller)
        XCTAssertFalse(panel.historyScrollView.hasVerticalScroller)
        editor.insertText("a中文", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(search.stringValue, "a中文")
    }

    @MainActor func testFinishSearchUsesLatestQueryAndEmptyResultCannotUseOldCard() async throws {
        let (model, panel) = try await makePanel(["旧查询命中", "最新查询命中"])
        panel.beginSearch(selectAll: false)
        panel.searchControl.stringValue = "旧查询"
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: panel.searchControl))
        panel.searchControl.stringValue = "不存在"
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: panel.searchControl))
        let before = board.changeCount
        panel.finishSearch()

        XCTAssertEqual(panel.interactionMode, .cards)
        XCTAssertTrue(panel.visibleEntryIDs.isEmpty)
        XCTAssertNil(panel.selectedEntryID)
        panel.historyView.keyDown(with: try keyEvent(36, "\r"))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(board.changeCount, before)
        XCTAssertFalse(model.busy)

        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(panel.visibleEntryIDs.isEmpty, "旧的异步查询结果不能覆盖已完成的新查询")
    }

    @MainActor func testFirstOrdinaryCharacterIsForwardedToNativeSearchEditorWithoutLoss() async throws {
        let (_, panel) = try await makePanel(["éclair", "其他"])
        panel.window?.makeKeyAndOrderFront(nil)
        panel.window?.makeFirstResponder(panel.historyView)
        panel.historyView.keyDown(with: try keyEvent(0, "é"))

        try await waitUntil { panel.visibleQuery == "é" }
        XCTAssertEqual(panel.interactionMode, .search)
        try await waitUntil { panel.visibleEntryIDs.count == 1 }
    }

    @MainActor func testReservedKeysAndCommandShortcutDoNotStartSearch() async throws {
        let (model, panel) = try await makePanel(["第一条", "第二条"])
        panel.show()
        let window = try XCTUnwrap(panel.window)
        let initial = panel.selectedEntryID
        window.sendEvent(try keyEvent(124, String(UnicodeScalar(NSRightArrowFunctionKey)!)))
        XCTAssertNotEqual(panel.selectedEntryID, initial)
        let moved = panel.selectedEntryID
        window.sendEvent(try keyEvent(126, String(UnicodeScalar(NSUpArrowFunctionKey)!)))
        window.sendEvent(try keyEvent(125, String(UnicodeScalar(NSDownArrowFunctionKey)!)))
        window.sendEvent(try keyEvent(8, "c", modifiers: .command))

        XCTAssertEqual(panel.interactionMode, .cards)
        XCTAssertEqual(panel.visibleQuery, "")
        XCTAssertEqual(panel.selectedEntryID, moved, "卡片态上下键不改变选择")
        XCTAssertFalse(model.busy)
    }

    @MainActor func testCommandVIsRoutedToSearchOnlyFromCardMode() throws {
        let panel = HistoryPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        var pasteRoutes = 0
        panel.isCardMode = { true }
        panel.onPasteIntoSearch = { pasteRoutes += 1 }
        XCTAssertTrue(panel.performKeyEquivalent(with: try keyEvent(9, "v", modifiers: .command)))
        XCTAssertEqual(pasteRoutes, 1)

        panel.isCardMode = { false }
        _ = panel.performKeyEquivalent(with: try keyEvent(8, "c", modifiers: .command))
        XCTAssertEqual(pasteRoutes, 1)
    }

    @MainActor func testCommandFFindsAndSelectsExistingQueryForReplacement() async throws {
        let (_, panel) = try await makePanel(["已有关键词", "其他"])
        panel.beginSearch(selectAll: false)
        panel.searchControl.stringValue = "已有"
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: panel.searchControl))
        panel.finishSearch()
        XCTAssertEqual(panel.interactionMode, .cards)

        let commandF = try keyEvent(3, "f", modifiers: .command)
        XCTAssertTrue((panel.window as! HistoryPanel).performKeyEquivalent(with: commandF))
        let editor = try XCTUnwrap(panel.searchControl.currentEditor() as? NSTextView)
        XCTAssertEqual(panel.interactionMode, .search)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 2))
    }

    @MainActor func testMarkedTextKeepsSearchCommandsInsideNativeInputMethod() async throws {
        let (model, panel) = try await makePanel(["命中内容", "其他"])
        panel.beginSearch(selectAll: false)
        let editor = try XCTUnwrap(panel.searchControl.currentEditor() as? NSTextView)
        editor.setMarkedText("ming", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        let before = board.changeCount

        for command in [
            #selector(NSResponder.insertNewline(_:)),
            #selector(NSResponder.moveLeft(_:)),
            #selector(NSResponder.moveRight(_:)),
            #selector(NSResponder.moveUp(_:)),
            #selector(NSResponder.moveDown(_:)),
            #selector(NSResponder.deleteBackward(_:)),
            #selector(NSResponder.deleteForward(_:)),
            #selector(NSResponder.cancelOperation(_:))
        ] {
            XCTAssertFalse(panel.control(panel.searchControl, textView: editor, doCommandBy: command))
        }

        XCTAssertEqual(panel.interactionMode, .search)
        XCTAssertEqual(board.changeCount, before)
        XCTAssertFalse(model.busy)
    }

    @MainActor func testDeleteEditsSearchButDeletesHistoryOnlyInCardMode() async throws {
        let (model, panel) = try await makePanel(["保留", "删除我"])
        let count = model.entries.count
        panel.beginSearch(selectAll: false)
        panel.searchControl.stringValue = "删"
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: panel.searchControl))
        let editor = try XCTUnwrap(panel.searchControl.currentEditor() as? NSTextView)
        XCTAssertFalse(panel.control(panel.searchControl, textView: editor, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
        XCTAssertEqual(model.entries.count, count)
        XCTAssertEqual(panel.interactionMode, .search)

        panel.cancelSearch()
        let deletedID = panel.selectedEntryID
        panel.historyView.keyDown(with: try keyEvent(51, String(UnicodeScalar(NSDeleteCharacter)!)))
        try await waitUntil { model.entries.count == count - 1 }
        XCTAssertFalse(model.entries.contains(where: { $0.id == deletedID }))
    }
}
