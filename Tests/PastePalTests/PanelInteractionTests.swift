import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
import ClipboardCore
@testable import PastePal

final class PanelInteractionTests: AppTestSupport {
    @MainActor func testWindowDispatchRightThenReturnUsesSecondCard() async throws {
        let (model, panel) = try await makePanel(["第一条", "第二条", "第三条"])
        panel.show()
        panel.beginSearch(selectAll: false)
        panel.cancelSearch()
        panel.dismiss()
        panel.show()
        let window = try XCTUnwrap(panel.window)
        XCTAssertTrue(panel.isCollectionFocused)
        XCTAssertEqual(panel.selectedEntryID, model.entries.first?.id, "再次呼出必须回到首卡")
        let first = try XCTUnwrap(panel.selectedEntryID)

        window.sendEvent(try keyEvent(124, String(UnicodeScalar(NSRightArrowFunctionKey)!)))
        let second = try XCTUnwrap(panel.selectedEntryID)
        XCTAssertNotEqual(second, first)
        XCTAssertTrue(panel.isCollectionFocused)
        let expected = try XCTUnwrap(model.store.content(id: second).text)

        model.paste.invalidate(); model.onFeedback = nil
        let returnEvent = try keyEvent(36, "\r")
        window.sendEvent(returnEvent)
        try await waitUntil { board.string(forType: .string) == expected && !panel.isVisible }
        XCTAssertEqual(panel.interactionMode, .cards)
    }

    @MainActor func testArrowSelectionKeepsEveryCardFullyVisibleAcrossBothEdges() async throws {
        let (_, panel) = try await makePanel((1...12).map { "第\($0)条" })
        panel.show()
        defer { panel.dismiss() }
        let window = try XCTUnwrap(panel.window)
        window.setFrame(NSRect(x: window.frame.minX, y: window.frame.minY, width: 900, height: window.frame.height), display: true)
        panel.historyView.layoutSubtreeIfNeeded()

        func assertSelectionVisible(file: StaticString = #filePath, line: UInt = #line) {
            panel.historyView.layoutSubtreeIfNeeded()
            guard let selected = panel.historyView.selectionIndexPaths.first,
                  let attributes = panel.historyView.collectionViewLayout?.layoutAttributesForItem(at: selected) else {
                XCTFail("选中项应有布局属性", file: file, line: line)
                return
            }
            let visible = panel.historyScrollView.documentVisibleRect.insetBy(dx: -0.5, dy: -0.5)
            XCTAssertTrue(visible.contains(attributes.frame), "选中项 \(selected.item) 未完整露出：\(attributes.frame)，可见：\(visible)", file: file, line: line)
        }

        assertSelectionVisible()
        for _ in 1..<12 {
            window.sendEvent(try keyEvent(124, String(UnicodeScalar(NSRightArrowFunctionKey)!)))
            assertSelectionVisible()
        }
        for _ in 1..<12 {
            window.sendEvent(try keyEvent(123, String(UnicodeScalar(NSLeftArrowFunctionKey)!)))
            assertSelectionVisible()
        }
        XCTAssertEqual(panel.selectedEntryID, panel.visibleEntryIDs.first)
    }

    @MainActor func testWindowDispatchedMouseClicksKeepPanelOpenAndRouteControls() async throws {
        let (model, panel) = try await makePanel(["第一条", "第二条"])
        let group = try model.store.createGroup(name: "工作")
        model.refresh(); try await waitUntil { panel.groupLabelTitles == ["工作"] }
        panel.show()
        let window = try XCTUnwrap(panel.window)
        window.contentView?.layoutSubtreeIfNeeded()
        panel.historyView.layoutSubtreeIfNeeded()

        let secondItem = try XCTUnwrap(panel.historyView.item(at: IndexPath(item: 1, section: 0)))
        try click(secondItem.view, in: window)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.selectedEntryID, panel.visibleEntryIDs[1])

        try click(panel.searchTriggerControl, in: window)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.interactionMode, .search)
        XCTAssertNotNil(panel.searchControl.currentEditor())
        try click(panel.searchControl, in: window)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(window.firstResponder === panel.searchControl.currentEditor())
        panel.cancelSearch()

        try click(panel.newGroupControl, in: window)
        XCTAssertTrue(panel.isVisible)
        XCTAssertNotNil(panel.groupCreationView)
        XCTAssertNil(panel.groupEditorController)
        XCTAssertFalse(panel.historyScrollView.isHidden)
        panel.closeGroupInteraction()

        let groupButton = try XCTUnwrap(descendants(of: window.contentView).compactMap { $0 as? GroupButton }.first)
        try click(groupButton, in: window)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.selectedGroupID, group.id)
        try click(try XCTUnwrap(panel.deleteGroupControl), in: window)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.isGroupDeleteConfirmationVisible)
        panel.groupEditorController?.cancelDelete()
        let renameButton = try XCTUnwrap(descendants(of: window.contentView).compactMap { $0 as? GroupButton }.first)
        try click(renameButton, in: window)
        XCTAssertEqual(panel.selectedGroupID, group.id)
        try click(renameButton, in: window, clickCount: 2)
        XCTAssertNotNil(panel.groupLabelEditor)
        XCTAssertTrue(panel.isVisible)
        panel.cancelGroupRename()
        panel.dismiss()
    }

    @MainActor func testWindowDispatchedDoubleClickUsesCardAndClosesPanel() async throws {
        let (model, panel) = try await makePanel(["双击使用"])
        panel.show()
        let window = try XCTUnwrap(panel.window)
        window.contentView?.layoutSubtreeIfNeeded()
        panel.historyView.layoutSubtreeIfNeeded()
        let item = try XCTUnwrap(panel.historyView.item(at: IndexPath(item: 0, section: 0)))

        model.paste.invalidate(); model.onFeedback = nil
        try click(item.view, in: window, clickCount: 2)

        try await waitUntil { board.string(forType: .string) == "双击使用" && !panel.isVisible }
        XCTAssertEqual(model.entries.first?.text, "双击使用")
    }

    @MainActor func testOutsideMonitorIgnoresPanelCoordinatesAndDismissesOutsideCoordinates() async throws {
        let (_, panel) = try await makePanel(["保留"])
        panel.show()
        let window = try XCTUnwrap(panel.window)

        panel.handleOutsideMouseDown(at: NSPoint(x: window.frame.midX, y: window.frame.midY))
        XCTAssertTrue(panel.isVisible)

        panel.handleOutsideMouseDown(at: NSPoint(x: window.frame.maxX + 1, y: window.frame.maxY + 1))
        XCTAssertFalse(panel.isVisible)
    }

    func testFocusLossDismissalRequiresLeavingAppOrAnotherKeyWindow() {
        XCTAssertFalse(PanelController.shouldDismissAfterResigningKey(
            applicationIsActive: true,
            hasDifferentKeyWindow: false
        ))
        XCTAssertTrue(PanelController.shouldDismissAfterResigningKey(
            applicationIsActive: true,
            hasDifferentKeyWindow: true
        ))
        XCTAssertTrue(PanelController.shouldDismissAfterResigningKey(
            applicationIsActive: false,
            hasDifferentKeyWindow: false
        ))
    }

    @MainActor func testStatusMenuSelectionActionsRequireVisibleCardState() async throws {
        let (_, panel) = try await makePanel(["可用文字"])
        XCTAssertFalse(panel.canActOnSelectedEntry)

        panel.show()
        XCTAssertTrue(panel.canActOnSelectedEntry)
        XCTAssertTrue(panel.canUseSelectedEntryAsPlainText)

        panel.beginSearch(selectAll: false)
        XCTAssertFalse(panel.canActOnSelectedEntry)
        panel.finishSearch()
        XCTAssertTrue(panel.canActOnSelectedEntry)

        panel.beginSearch(selectAll: false)
        panel.searchControl.stringValue = "没有匹配"
        panel.finishSearch()
        XCTAssertFalse(panel.canActOnSelectedEntry)
        panel.dismiss()
    }

    @MainActor func testCommandNumberStillUsesMatchingVisibleCard() async throws {
        let (model, panel) = try await makePanel(["第一条", "第二条", "第三条"])
        panel.window?.makeKeyAndOrderFront(nil)
        defer { panel.dismiss() }
        model.paste.invalidate(); model.onFeedback = nil
        let expectedID = panel.visibleEntryIDs[1]
        let expectedText = try model.store.content(id: expectedID).text
        XCTAssertTrue(panel.historyView.performKeyEquivalent(with: try keyEvent(19, "2", modifiers: .command)))
        try await waitUntil { board.string(forType: .string) == expectedText }
        XCTAssertEqual(try model.store.entries().first?.id, expectedID)
    }

    @MainActor private func mouseEvent(_ type: NSEvent.EventType, in window: NSWindow, at point: NSPoint, clickCount: Int = 1) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: type == .leftMouseDown ? 1 : 0
        ))
    }

    @MainActor private func click(_ view: NSView, in window: NSWindow, clickCount: Int = 1) throws {
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let down = try mouseEvent(.leftMouseDown, in: window, at: point, clickCount: clickCount)
        let up = try mouseEvent(.leftMouseUp, in: window, at: point, clickCount: clickCount)
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
    }
}
