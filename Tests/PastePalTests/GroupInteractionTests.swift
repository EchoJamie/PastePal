import PastePalLocalization
import XCTest
import AppKit
import ClipboardCore
import KeyboardShortcuts
@testable import PastePal

final class GroupInteractionTests: XCTestCase {
    @MainActor func testWindowDispatchedTabCyclesSearchScopeWithoutChangingQueryOrSelection() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "GroupSearchTabTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let board = NSPasteboard.withUniqueName()
        defer {
            defaults.removePersistentDomain(forName: suite)
            board.releaseGlobally()
            try? FileManager.default.removeItem(at: directory)
        }
        let model = try AppModel(directory: directory, settings: SettingsStore(defaults: defaults), pasteboard: board)
        let first = try model.store.createGroup(name: "工作")
        let second = try model.store.createGroup(name: "阅读")
        for (text, group) in [("匹配工作", first), ("匹配阅读", second), ("无关工作", first)] {
            let entry = try model.store.record(ContentCodec.decode([Representation(type: "public.utf8-plain-text", data: Data(text.utf8))]), limit: 20)
            try model.store.add(entryID: entry.id, toGroup: group.id)
        }
        model.refresh()
        try await wait { model.groups.count == 2 && model.entries.count == 3 }
        let workEntry = try XCTUnwrap(model.entries.first { $0.text == "匹配工作" })
        let readingEntry = try XCTUnwrap(model.entries.first { $0.text == "匹配阅读" })
        let panel = PanelController(model: model)
        panel.prepareForDisplay()
        let window = try XCTUnwrap(panel.window)
        defer { panel.dismiss() }
        window.sendEvent(try event(48, []))
        XCTAssertEqual(panel.selectedGroupID, first.id)
        window.sendEvent(try event(48, [.shift]))
        XCTAssertNil(panel.selectedGroupID)
        panel.selectGroup(first.id)
        panel.beginSearch(selectAll: false)
        let editor = try XCTUnwrap(panel.searchControl.currentEditor() as? NSTextView)
        editor.insertText("匹配", replacementRange: NSRange(location: NSNotFound, length: 0))
        let selection = NSRange(location: 1, length: 1)
        editor.setSelectedRange(selection)

        window.sendEvent(try event(48, []))
        XCTAssertEqual(panel.visibleQuery, "匹配")
        XCTAssertEqual(panel.activeSearchScopeGroupID, second.id)
        XCTAssertEqual(panel.visibleEntryIDs, [readingEntry.id])
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(panel.interactionMode, .search)
        window.sendEvent(try event(48, [.shift]))
        XCTAssertEqual(panel.activeSearchScopeGroupID, first.id)
        XCTAssertEqual(panel.visibleEntryIDs, [workEntry.id])
        XCTAssertEqual(editor.selectedRange(), selection)

        editor.setMarkedText("候选", selectedRange: NSRange(location: 2, length: 0), replacementRange: selection)
        XCTAssertFalse(panel.handleGroupShortcut(try event(48, [])))
        XCTAssertFalse(panel.control(panel.searchControl, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        XCTAssertEqual(panel.activeSearchScopeGroupID, first.id)
        editor.unmarkText()
        editor.string = "匹配"; panel.searchControl.stringValue = "匹配"
        editor.setSelectedRange(selection)
        let shortcuts = GroupShortcutStore(defaults: defaults)
        XCTAssertNotNil(shortcuts.setShortcut(.init(.n, modifiers: [.control, .option]), for: .next))
        XCTAssertFalse(panel.handleGroupShortcut(try event(45, [.control, .option])))
        window.sendEvent(try event(48, []))
        XCTAssertEqual(panel.activeSearchScopeGroupID, second.id)
        XCTAssertEqual(panel.visibleQuery, "匹配")
        XCTAssertEqual(panel.visibleEntryIDs, [readingEntry.id])
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertTrue(panel.control(panel.searchControl, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(panel.selectedGroupID, first.id)
        XCTAssertEqual(panel.visibleQuery, "")
        XCTAssertTrue(panel.isCollectionFocused)
    }

    @MainActor func testEditorHeadingsMatchCreateRenameAndDeleteStates() {
        _ = NSApplication.shared
        let create = GroupEditorController(title: L("新建分组"), actionTitle: "新建") { _ in nil }
        XCTAssertEqual(create.headingText, L("新建分组"))

        let rename = GroupEditorController(title: L("重命名分组"), actionTitle: "保存", value: "工作") { _ in nil }
        XCTAssertEqual(rename.headingText, L("重命名分组"))
        rename.requestDelete()
        XCTAssertEqual(rename.headingText, L("删除分组"))
        rename.cancelDelete()
        XCTAssertEqual(rename.headingText, L("重命名分组"))
    }

    @MainActor func testLabelEditingDeletionAndLocalShortcutRouting() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "GroupInteractionTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let model = try AppModel(directory: directory, settings: SettingsStore(defaults: defaults), pasteboard: .withUniqueName())
        let first = try model.store.createGroup(name: "第一组")
        let second = try model.store.createGroup(name: "第二组")
        model.refresh()
        try await wait { model.groups.count == 2 }
        let panel = PanelController(model: model)
        panel.prepareForDisplay(); panel.showWindow(nil)
        defer { panel.dismiss() }
        panel.selectGroup(first.id)
        XCTAssertNotNil(panel.deleteGroupControl?.superview)
        panel.deleteGroupControl?.performClick(nil)
        XCTAssertTrue(panel.isGroupDeleteConfirmationVisible)
        XCTAssertEqual(panel.selectedGroupID, first.id)
        panel.groupEditorController?.cancelDelete()
        XCTAssertFalse(panel.isGroupInteractionVisible)
        XCTAssertEqual(model.groups.count, 2)
        XCTAssertEqual(panel.selectedGroupID, first.id)

        panel.beginGroupRename(first.id)
        let editor = try XCTUnwrap(panel.groupLabelEditor)
        XCTAssertTrue(editor.window === panel.window)
        XCTAssertNil(panel.groupEditorController)
        editor.nameControl.stringValue = "第二组"; editor.submit()
        XCTAssertNotNil(panel.groupLabelEditor)
        XCTAssertEqual(model.groups.first?.name, "第一组")
        XCTAssertFalse(panel.handleGroupShortcut(try event(48, [])))
        editor.nameControl.stringValue = "改名分组"
        editor.laterControl.performClick(nil)
        try await wait { model.groups.first?.id == second.id }
        XCTAssertEqual(panel.groupLabelEditor?.nameControl.stringValue, "改名分组")
        editor.submit()
        try await wait { model.groups.last?.name == "改名分组" }
        XCTAssertNil(panel.groupLabelEditor)
        panel.selectGroup(nil)
        XCTAssertTrue(panel.handleGroupShortcut(try event(48, [])))
        XCTAssertEqual(panel.selectedGroupID, second.id)
        panel.beginSearch(selectAll: false)
        let searchEditor = try XCTUnwrap(panel.searchControl.currentEditor() as? NSTextView)
        searchEditor.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(panel.handleGroupShortcut(try event(48, [])))
        XCTAssertEqual(panel.selectedGroupID, second.id)
        searchEditor.unmarkText(); panel.cancelSearch()

        panel.requestSelectedGroupDeletion(); panel.groupEditorController?.confirmDelete()
        try await wait { model.groups.count == 1 }
        XCTAssertEqual(model.groups.first?.id, first.id)
        XCTAssertFalse(panel.isGroupInteractionVisible)
    }

    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("等待分组变更超时")
    }
    private func event(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                      timestamp: 0, windowNumber: 0, context: nil, characters: code == 48 ? "\t" : "n",
                                      charactersIgnoringModifiers: code == 48 ? "\t" : "n", isARepeat: false, keyCode: code))
    }
}

final class GroupPanelInteractionTests: AppTestSupport {
    @MainActor func testDraggingGroupLabelsInsertsOrderAndCancellationDoesNotMutate() async throws {
        let (model, panel) = try await makePanel(["拖动测试"])
        let groups = try ["甲组", "乙组", "丙组"].map { try model.store.createGroup(name: $0) }
        model.refresh(); try await waitUntil { model.groups.count == 3 }
        panel.show(); panel.selectGroup(groups[1].id)
        let window = try XCTUnwrap(panel.window)
        defer { panel.dismiss() }
        func button(_ id: String) throws -> GroupButton {
            window.contentView?.layoutSubtreeIfNeeded()
            return try XCTUnwrap(descendants(of: window.contentView).compactMap { $0 as? GroupButton }.first { $0.groupID == id })
        }
        func drag(_ source: GroupButton, to point: NSPoint, escape: Bool = false) throws {
            func mouseEvent(_ type: NSEvent.EventType, in window: NSWindow, at point: NSPoint) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            }
            let start = source.convert(NSPoint(x: source.bounds.midX, y: source.bounds.midY), to: nil)
            let down = try mouseEvent(.leftMouseDown, in: window, at: start)
            NSApp.postEvent(try mouseEvent(.leftMouseDragged, in: window, at: point), atStart: false)
            if escape {
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
                NSApp.postEvent(event, atStart: false)
            } else {
                NSApp.postEvent(try mouseEvent(.leftMouseUp, in: window, at: point), atStart: false)
            }
            window.sendEvent(down)
        }
        let first = try button(groups[0].id)
        let last = try button(groups[2].id)
        let destination = last.convert(NSPoint(x: last.bounds.maxX + 8, y: last.bounds.midY), to: nil)
        let originalHandler = first.onDragChanged
        var insertionWasVisible = false
        first.onDragChanged = { event in
            originalHandler?(event)
            insertionWasVisible = insertionWasVisible || panel.isGroupDropIndicatorVisible
        }
        try drag(first, to: destination)
        try await waitUntil { model.groups.map(\.id) == [groups[1].id, groups[2].id, groups[0].id] }
        XCTAssertTrue(insertionWasVisible)
        XCTAssertFalse(panel.isGroupDropIndicatorVisible)
        XCTAssertEqual(panel.selectedGroupID, groups[1].id)
        XCTAssertEqual(try model.store.groups().map(\.id), [groups[1].id, groups[2].id, groups[0].id])

        let third = try button(groups[2].id)
        let smallMove = third.convert(NSPoint(x: third.bounds.midX + 2, y: third.bounds.midY), to: nil)
        try drag(third, to: smallMove)
        XCTAssertEqual(panel.selectedGroupID, groups[2].id)
        let order = model.groups.map(\.id)
        let source = try button(groups[1].id)
        try drag(source, to: NSPoint(x: 0, y: 0))
        XCTAssertEqual(try model.store.groups().map(\.id), order)
        let final = try button(groups[0].id)
        try drag(source, to: final.convert(NSPoint(x: final.bounds.maxX + 8, y: final.bounds.midY), to: nil), escape: true)
        XCTAssertEqual(try model.store.groups().map(\.id), order)
        XCTAssertEqual(panel.selectedGroupID, groups[2].id)
        XCTAssertFalse(panel.isGroupDropIndicatorVisible)
    }

    @MainActor func testCustomGroupLabelsToggleHistoryAndCycleWithTab() async throws {
        let (model, panel) = try await makePanel(["普通内容", "资料内容", "工作内容"])
        let work = try model.store.createGroup(name: "工作")
        let reading = try model.store.createGroup(name: "阅读")
        let workEntry = try XCTUnwrap(model.entries.first { $0.text == "工作内容" })
        let readingEntry = try XCTUnwrap(model.entries.first { $0.text == "资料内容" })
        try model.store.add(entryID: workEntry.id, toGroup: work.id)
        try model.store.add(entryID: readingEntry.id, toGroup: reading.id)
        model.refresh(); try await waitUntil { model.groups.count == 2 }
        panel.prepareForDisplay(); panel.window?.makeKeyAndOrderFront(nil); panel.window?.contentView?.layoutSubtreeIfNeeded()

        XCTAssertNil(panel.selectedGroupID)
        XCTAssertEqual(panel.groupLabelTitles, ["工作", "阅读"])
        XCTAssertEqual(panel.visibleEntryIDs.count, 3)
        panel.selectGroup(work.id)
        XCTAssertEqual(panel.selectedGroupID, work.id)
        XCTAssertEqual(panel.visibleEntryIDs, [workEntry.id])
        panel.selectGroup(work.id)
        XCTAssertNil(panel.selectedGroupID, "再次选择当前组应回到没有高亮标签的历史")
        XCTAssertEqual(panel.visibleEntryIDs.count, 3)

        let historyPanel = try XCTUnwrap(panel.window as? HistoryPanel)
        XCTAssertTrue(historyPanel.performKeyEquivalent(with: try keyEvent(48, "\t")))
        XCTAssertEqual(panel.selectedGroupID, work.id)
        XCTAssertTrue(historyPanel.performKeyEquivalent(with: try keyEvent(48, "\t", modifiers: [.shift])))
        XCTAssertNil(panel.selectedGroupID)
    }

    @MainActor func testPanelGroupCreationContextManagementAndFocusRestoration() async throws {
        let (model, panel) = try await makePanel(["待管理内容"])
        let first = try model.store.createGroup(name: "甲组")
        let second = try model.store.createGroup(name: "乙组")
        model.refresh(); try await waitUntil { model.groups.count == 2 }
        panel.show()

        XCTAssertTrue(panel.isNewGroupControlVisible)
        panel.newGroupControl.performClick(nil)
        let creation = try XCTUnwrap(panel.groupCreationView)
        XCTAssertTrue(creation.window === panel.window)
        XCTAssertNil(panel.groupEditorController)
        XCTAssertFalse(panel.historyScrollView.isHidden)
        XCTAssertNil(panel.window?.attachedSheet)
        XCTAssertFalse(panel.canActOnSelectedEntry)
        creation.nameControl.stringValue = "新组"
        creation.submit()
        try await waitUntil { model.groups.contains { $0.name == "新组" } && panel.groupCreationView == nil }
        XCTAssertEqual(panel.selectedGroupID, model.groups.first { $0.name == "新组" }?.id)
        XCTAssertTrue(panel.groupLabelTitles.contains("新组"))
        XCTAssertTrue(panel.isCollectionFocused)

        panel.showGroupEditor(groupID: first.id)
        let editor = try XCTUnwrap(panel.groupEditorController)
        XCTAssertEqual(editor.nameControl.stringValue, "甲组")
        editor.nameControl.stringValue = "甲组重命名"
        editor.submit()
        try await waitUntil { model.groups.contains { $0.name == "甲组重命名" } && panel.groupEditorController == nil }
        XCTAssertTrue(panel.isCollectionFocused)

        panel.showGroupEditor(groupID: first.id)
        panel.groupEditorController?.move(offset: 1)
        try await waitUntil { model.groups.first?.id == second.id }
        XCTAssertTrue(panel.isCollectionFocused)

        panel.showGroupEditor(groupID: first.id)
        panel.groupEditorController?.requestDelete()
        XCTAssertTrue(panel.isGroupDeleteConfirmationVisible)
        XCTAssertNil(panel.window?.attachedSheet)
        panel.groupEditorController?.cancelDelete()
        XCTAssertFalse(panel.isGroupDeleteConfirmationVisible)
        XCTAssertTrue(model.groups.contains { $0.id == first.id })
        panel.groupEditorController?.requestDelete()
        panel.groupEditorController?.confirmDelete()
        try await waitUntil { !model.groups.contains { $0.id == first.id } && !panel.isGroupDeleteConfirmationVisible }
        XCTAssertTrue(panel.isCollectionFocused)
        XCTAssertTrue(panel.isVisible)
    }

    @MainActor func testInlineGroupValidationCancelAndManagementKeepHistoryUntouched() async throws {
        let (model, panel) = try await makePanel(["内容"])
        _ = try model.store.createGroup(name: "工作")
        model.refresh(); try await waitUntil { model.groups.count == 1 }
        panel.show()
        let selected = panel.selectedEntryID
        panel.showGroupEditor(groupID: nil)
        let editor = try XCTUnwrap(panel.groupCreationView)
        for blank in ["", " \t\n "] {
            editor.nameControl.stringValue = blank; editor.submit()
            XCTAssertEqual(model.groups.count, 1)
            XCTAssertFalse(editor.errorText.isEmpty)
            XCTAssertFalse(editor.isSubmitting)
        }
        let fieldEditor = try XCTUnwrap(editor.nameControl.currentEditor() as? NSTextView)
        fieldEditor.setMarkedText("候选", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(editor.control(editor.nameControl, textView: fieldEditor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertFalse(editor.control(editor.nameControl, textView: fieldEditor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(model.groups.count, 1)
        fieldEditor.unmarkText()
        editor.nameControl.stringValue = "工作"; editor.submit()
        XCTAssertFalse(editor.errorText.isEmpty)
        XCTAssertTrue(panel.isGroupInteractionVisible)
        XCTAssertNil(board.string(forType: .string))
        panel.window?.cancelOperation(nil)
        XCTAssertFalse(panel.isGroupInteractionVisible)
        XCTAssertTrue(panel.isCollectionFocused)
        XCTAssertEqual(panel.selectedEntryID, selected)
        panel.showGroupManagement()
        let picker = try XCTUnwrap(panel.groupPickerController)
        XCTAssertTrue(picker.view.window === panel.window)
        picker.addSelected()
        XCTAssertEqual(panel.groupEditorController?.nameControl.stringValue, "工作")
        XCTAssertNil(panel.window?.attachedSheet)
        panel.groupEditorController?.close()
        XCTAssertTrue(panel.isCollectionFocused)
    }

    @MainActor func testCommandGUsesHorizontalGroupsAndAddsWithoutPasting() async throws {
        let (model, panel) = try await makePanel(["待归组"])
        let work = try model.store.createGroup(name: "工作")
        let reading = try model.store.createGroup(name: "阅读资料")
        model.refresh(); try await waitUntil { model.groups.count == 2 }
        panel.prepareForDisplay(); panel.window?.makeKeyAndOrderFront(nil)

        XCTAssertTrue(panel.historyView.performKeyEquivalent(with: try keyEvent(5, "g", modifiers: .command)))
        XCTAssertTrue(panel.isGroupJoinVisible)
        XCTAssertTrue(panel.isGroupToolbarVisible)
        XCTAssertFalse(panel.historyScrollView.isHidden)
        XCTAssertNil(panel.groupPickerController)
        XCTAssertEqual(panel.groupJoinTargetID, work.id)
        panel.window?.sendEvent(try keyEvent(124, ""))
        XCTAssertEqual(panel.groupJoinTargetID, reading.id)
        panel.window?.sendEvent(try keyEvent(36, "\r"))
        let entryID = try XCTUnwrap(model.entries.first?.id)
        try await waitUntil { model.entryIDs(in: reading.id).contains(entryID) && !panel.isGroupJoinVisible }
        XCTAssertFalse(model.entryIDs(in: work.id).contains(entryID))
        XCTAssertTrue(panel.isCollectionFocused)
        XCTAssertNil(board.string(forType: .string))
        panel.showGroupPicker()
        XCTAssertTrue(panel.groupLabelTitles.contains("阅读资料 ✓"))
        panel.window?.sendEvent(try keyEvent(53, ""))
        XCTAssertFalse(panel.isGroupJoinVisible)
        XCTAssertFalse(model.entryIDs(in: work.id).contains(entryID))

        model.paste.invalidate(); model.onFeedback = nil
        panel.window?.sendEvent(try keyEvent(36, "\r"))
        try await waitUntil { board.string(forType: .string) == "待归组" && !panel.isVisible }
    }

    @MainActor func testEmptyGroupAndOverflowingLabelsKeepSelectedGroupVisible() async throws {
        let (model, panel) = try await makePanel(["唯一内容"])
        var groups: [ClipGroup] = []
        for index in 1...14 { groups.append(try model.store.createGroup(name: "第 \(index) 个很长的自定义分组")) }
        model.refresh(); try await waitUntil { model.groups.count == groups.count }
        panel.prepareForDisplay()
        panel.window?.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 356), display: true)
        panel.selectGroup(groups.last!.id); panel.window?.contentView?.layoutSubtreeIfNeeded()

        XCTAssertTrue(panel.visibleEntryIDs.isEmpty)
        XCTAssertEqual(panel.emptyStateTitle, L("这个分组还没有内容"))
        XCTAssertTrue(panel.groupStripOverflows)
        XCTAssertTrue(panel.isSelectedGroupVisible)
        XCTAssertEqual(panel.visibleToolbarCenterOffset, 0, accuracy: 0.5)
        XCTAssertTrue(panel.visibleToolbarDoesNotOverlapCount)
    }
}
