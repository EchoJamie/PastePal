import PastePalLocalization
import XCTest
import AppKit
import ClipboardCore
@testable import PastePal

final class GroupSpaceContextTests: AppTestSupport {
    @MainActor func testSpaceAddsInHorizontalGroupsButPreviewsCardsAndDoesNothingInEmptyCards() async throws {
        let (model, panel) = try await makePanel(["卡片预览内容"])
        defer { panel.dismiss() }
        let group = try model.store.createGroup(name: "目标")
        let empty = try model.store.createGroup(name: "空组")
        model.refresh(); try await waitUntil { model.groups.count == 2 }
        let entryID = try XCTUnwrap(panel.selectedEntryID)
        let window = try XCTUnwrap(panel.window)
        window.makeKeyAndOrderFront(nil)
        panel.showGroupPicker()
        XCTAssertEqual(panel.groupJoinTargetID, group.id)
        window.sendEvent(try keyEvent(49, " "))
        try await waitUntil { model.entryIDs(in: group.id).contains(entryID) }
        XCTAssertFalse(panel.isGroupInteractionVisible)
        XCTAssertFalse(panel.hasPreviewController)
        XCTAssertNil(board.string(forType: .string))
        window.sendEvent(try keyEvent(49, " "))
        try await waitUntil { panel.hasPreviewController }
        XCTAssertTrue(panel.isVisible)
        XCTAssertNil(board.string(forType: .string))
        panel.previewWindow?.close()
        try await waitUntil { !panel.hasPreviewController }
        panel.selectGroup(empty.id)
        XCTAssertTrue(panel.visibleEntryIDs.isEmpty)
        window.sendEvent(try keyEvent(49, " "))
        XCTAssertFalse(panel.hasPreviewController)
        XCTAssertFalse(panel.isGroupInteractionVisible)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.selectedGroupID, empty.id)
        XCTAssertNil(board.string(forType: .string))
    }

    @MainActor func testSpaceEditsManagementSearchAndConfirmsOnlyFocusedGroupList() async throws {
        let (model, panel) = try await makePanel(["内容"])
        defer { panel.dismiss() }
        _ = try model.store.createGroup(name: "工作 资料")
        model.refresh(); try await waitUntil { model.groups.count == 1 }
        let window = try XCTUnwrap(panel.window)
        window.makeKeyAndOrderFront(nil)
        panel.showGroupManagement()
        let picker = try XCTUnwrap(panel.groupPickerController)
        let editor = try XCTUnwrap(picker.searchControl.currentEditor() as? NSTextView)
        editor.insertText("工作", replacementRange: NSRange(location: NSNotFound, length: 0))
        window.sendEvent(try keyEvent(49, " "))
        XCTAssertEqual(picker.searchControl.stringValue, "工作 ")
        XCTAssertFalse(panel.shortcutHintControl.stringValue.contains(L("空格")))
        XCTAssertNil(panel.groupEditorController)
        editor.insertText("资料", replacementRange: NSRange(location: NSNotFound, length: 0))
        window.sendEvent(try keyEvent(125, String(UnicodeScalar(NSDownArrowFunctionKey)!)))
        XCTAssertTrue(window.firstResponder is GroupPickerTable)
        XCTAssertTrue(panel.shortcutHintControl.stringValue.contains(L("空格")))
        window.sendEvent(try keyEvent(49, " "))
        XCTAssertNil(panel.groupPickerController)
        XCTAssertEqual(panel.groupEditorController?.nameControl.stringValue, "工作 资料")
        XCTAssertEqual(model.groups.count, 1)
        XCTAssertNil(board.string(forType: .string))
    }

    @MainActor func testSpaceRemainsTextInputInSearchCreationAndRenameIncludingMarkedText() async throws {
        let (model, panel) = try await makePanel(["内容"])
        defer { panel.dismiss() }
        let group = try model.store.createGroup(name: "原名")
        model.refresh(); try await waitUntil { model.groups.count == 1 }
        let window = try XCTUnwrap(panel.window)
        window.makeKeyAndOrderFront(nil)
        for context in 0..<3 {
            if context == 0 { panel.beginSearch(selectAll: false) }
            else if context == 1 { panel.showGroupEditor(groupID: nil) }
            else { panel.beginGroupRename(group.id) }
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
            editor.insertText("名", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            window.sendEvent(try keyEvent(49, " "))
            XCTAssertEqual(editor.string, "名 ")
            editor.setMarkedText("候选", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            window.sendEvent(try keyEvent(49, " "))
            XCTAssertEqual(model.groups.map(\.name), ["原名"])
            XCTAssertFalse(panel.hasPreviewController)
            XCTAssertNil(board.string(forType: .string))
            editor.unmarkText()
            if context == 0 { panel.cancelSearch() } else { panel.closeGroupInteraction() }
        }
    }
}
