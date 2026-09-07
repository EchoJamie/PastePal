import PastePalLocalization
import XCTest
import AppKit
import ClipboardCore
@testable import PastePal

final class GroupDeleteKeyboardTests: AppTestSupport {
    @MainActor func testConfirmationCyclesFocusAndOnlyActivatesCurrentChoice() async throws {
        let (model, panel) = try await makePanel(["保留内容"])
        defer { panel.dismiss() }
        let first = try model.store.createGroup(name: "工作")
        let second = try model.store.createGroup(name: "资料")
        let entryID = try XCTUnwrap(model.entries.first?.id)
        try model.store.add(entryID: entryID, toGroup: first.id)
        model.refresh(); try await waitUntil { model.groups.count == 2 }
        let window = try XCTUnwrap(panel.window)
        window.makeKeyAndOrderFront(nil)
        panel.selectGroup(first.id)
        let clipboardChanges = board.changeCount

        panel.requestSelectedGroupDeletion()
        XCTAssertEqual((window.firstResponder as? NSButton)?.title, L("取消"))
        window.sendEvent(try keyEvent(48, "\t"))
        XCTAssertEqual((window.firstResponder as? NSButton)?.title, L("确认删除"))
        XCTAssertEqual(panel.selectedGroupID, first.id)
        window.sendEvent(try keyEvent(48, "\t", modifiers: .shift))
        XCTAssertEqual((window.firstResponder as? NSButton)?.title, L("取消"))
        window.sendEvent(try keyEvent(49, " "))
        XCTAssertFalse(panel.isGroupInteractionVisible)
        XCTAssertTrue(panel.isCollectionFocused)
        XCTAssertFalse(panel.hasPreviewController)
        XCTAssertEqual(model.groups.count, 2)

        panel.requestSelectedGroupDeletion()
        window.sendEvent(try keyEvent(48, "\t", modifiers: .shift))
        XCTAssertEqual((window.firstResponder as? NSButton)?.title, L("确认删除"))
        window.sendEvent(try keyEvent(53, ""))
        XCTAssertFalse(panel.isGroupInteractionVisible)
        XCTAssertTrue(panel.isCollectionFocused)
        XCTAssertEqual(model.groups.count, 2)

        panel.requestSelectedGroupDeletion()
        window.sendEvent(try keyEvent(36, "\r"))
        XCTAssertFalse(panel.isGroupInteractionVisible)
        XCTAssertEqual(model.groups.count, 2)
        panel.requestSelectedGroupDeletion()
        window.sendEvent(try keyEvent(48, "\t"))
        let confirm = try XCTUnwrap(window.firstResponder as? NSButton)
        XCTAssertEqual(confirm.title, L("确认删除"))
        XCTAssertNotNil(confirm.bezelColor)
        XCTAssertEqual(confirm.contentTintColor, .white)
        window.sendEvent(try keyEvent(76, "\r"))
        try await waitUntil { model.groups.map(\.id) == [second.id] }
        XCTAssertFalse(panel.isGroupInteractionVisible)
        XCTAssertTrue(panel.isCollectionFocused)
        XCTAssertTrue(model.entries.contains { $0.id == entryID })
        XCTAssertEqual(board.changeCount, clipboardChanges)
    }
}
