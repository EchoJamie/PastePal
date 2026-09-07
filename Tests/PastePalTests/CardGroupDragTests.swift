import XCTest
import AppKit
import ClipboardCore
@testable import PastePal

final class CardGroupDragTests: AppTestSupport {
    @MainActor func testDropOnlyAddsMembershipAndRestoresHighlight() async throws {
        let (model, panel) = try await makePanel(["拖动内容"])
        defer { panel.dismiss() }
        panel.window?.makeKeyAndOrderFront(nil)
        let first = try model.store.createGroup(name: "已有")
        let second = try model.store.createGroup(name: "目标")
        let entryID = try XCTUnwrap(model.entries.first?.id)
        try model.store.add(entryID: entryID, toGroup: first.id)
        model.refresh(); try await waitUntil { model.groups.count == 2 }
        panel.prepareForDisplay()
        let dragBoard = NSPasteboard.withUniqueName()
        defer { dragBoard.releaseGlobally() }
        let writer = try XCTUnwrap(panel.collectionView(panel.historyView, pasteboardWriterForItemAt: IndexPath(item: 0, section: 0)))
        XCTAssertTrue(dragBoard.writeObjects([writer]))
        XCTAssertEqual(dragBoard.string(forType: CardGroupDrag.pasteboardType), entryID)
        let drag = TestCardDraggingInfo(pasteboard: dragBoard, source: panel.historyView)
        let buttons = descendants(of: panel.window?.contentView).compactMap { $0 as? GroupButton }
        let target = try XCTUnwrap(buttons.first { $0.groupID == second.id })
        let existing = try XCTUnwrap(buttons.first { $0.groupID == first.id })
        let count = board.changeCount
        XCTAssertEqual(existing.draggingEntered(drag), [])
        XCTAssertFalse(existing.isCardDropHighlighted)
        XCTAssertEqual(target.draggingEntered(drag), .copy)
        XCTAssertTrue(target.isCardDropHighlighted)
        target.draggingExited(drag)
        XCTAssertFalse(target.isCardDropHighlighted)
        XCTAssertFalse(model.groupIDs(for: entryID).contains(second.id))
        XCTAssertEqual(target.draggingEntered(drag), .copy)
        target.draggingEnded(drag)
        XCTAssertFalse(target.isCardDropHighlighted)
        XCTAssertFalse(model.groupIDs(for: entryID).contains(second.id))
        XCTAssertTrue(target.prepareForDragOperation(drag))
        XCTAssertTrue(target.performDragOperation(drag))
        XCTAssertFalse(target.isCardDropHighlighted)
        try await waitUntil { model.groupIDs(for: entryID).contains(second.id) }
        XCTAssertEqual(model.groupIDs(for: entryID), Set([first.id, second.id]))
        XCTAssertFalse(target.performDragOperation(drag))
        XCTAssertEqual(board.changeCount, count)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(model.entries.count, 1)
        XCTAssertFalse(panel.panelRootView.registeredDraggedTypes.contains(CardGroupDrag.pasteboardType))
    }

    @MainActor func testExternalMissingAndNonCopyDropsAreRejected() async throws {
        let (model, panel) = try await makePanel(["保留"])
        defer { panel.dismiss() }
        panel.window?.makeKeyAndOrderFront(nil)
        _ = try model.store.createGroup(name: "目标")
        model.refresh(); try await waitUntil { model.groups.count == 1 }
        let target = try XCTUnwrap(descendants(of: panel.window?.contentView).compactMap { $0 as? GroupButton }.first)
        let dragBoard = NSPasteboard.withUniqueName()
        defer { dragBoard.releaseGlobally() }
        dragBoard.setString(model.entries[0].id, forType: CardGroupDrag.pasteboardType)
        let drag = TestCardDraggingInfo(pasteboard: dragBoard, source: NSView())
        XCTAssertEqual(target.draggingEntered(drag), [])
        drag.draggingSource = panel.historyView
        drag.draggingSourceOperationMask = .move
        XCTAssertFalse(target.performDragOperation(drag))
        drag.draggingSourceOperationMask = .copy
        dragBoard.setString("missing", forType: CardGroupDrag.pasteboardType)
        XCTAssertFalse(target.prepareForDragOperation(drag))
        XCTAssertFalse(target.isCardDropHighlighted)
        XCTAssertTrue(model.groupIDs(for: model.entries[0].id).isEmpty)
    }

    @MainActor func testDragPreviewIsSmallAndTranslucentWithoutChangingCardOpacity() async throws {
        let (_, panel) = try await makePanel(["清晰原卡片"])
        defer { panel.dismiss() }
        panel.window?.makeKeyAndOrderFront(nil)
        panel.window?.contentView?.layoutSubtreeIfNeeded()
        let item = try XCTUnwrap(panel.historyView.item(at: IndexPath(item: 0, section: 0)) as? CardItem)
        let image = try XCTUnwrap(item.card.makeDragPreview())
        XCTAssertEqual(image.size.width, 108, accuracy: 0.1)
        XCTAssertLessThan(image.size.height, item.card.bounds.height)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
        XCTAssertEqual(color.alphaComponent, 0.32, accuracy: 0.03)
        XCTAssertEqual(item.card.alphaValue, 1)
        XCTAssertEqual(panel.panelContentView.alphaValue, 1)
    }

    @MainActor func testHorizontalJoinCancellationPreservesFilteredCardsAndScope() async throws {
        let (model, panel) = try await makePanel(["匹配内容", "其他"])
        defer { panel.dismiss() }
        panel.window?.makeKeyAndOrderFront(nil)
        let first = try model.store.createGroup(name: "工作")
        let second = try model.store.createGroup(name: "资料")
        let entry = try XCTUnwrap(model.entries.first { $0.text == "匹配内容" })
        try model.store.add(entryID: entry.id, toGroup: first.id)
        model.refresh(); try await waitUntil { model.groups.count == 2 }
        panel.selectGroup(first.id)
        panel.beginSearch(selectAll: false)
        panel.searchControl.stringValue = "匹配"
        panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: panel.searchControl))
        panel.finishSearch()
        let selection = panel.selectedEntryID
        panel.showGroupPicker()
        XCTAssertEqual(panel.groupJoinTargetID, second.id)
        XCTAssertTrue(panel.isGroupToolbarVisible)
        XCTAssertFalse(panel.isSearchControlVisible)
        XCTAssertEqual(panel.visibleQuery, "匹配")
        XCTAssertEqual(panel.visibleEntryIDs, [entry.id])
        panel.window?.contentView?.layoutSubtreeIfNeeded()
        let memberButton = try XCTUnwrap(descendants(of: panel.window?.contentView).compactMap { $0 as? GroupButton }.first { $0.groupID == first.id })
        XCTAssertEqual(memberButton.title, "工作 ✓")
        XCTAssertGreaterThanOrEqual(memberButton.bounds.width, memberButton.intrinsicContentSize.width)
        panel.window?.sendEvent(try keyEvent(48, "\t"))
        XCTAssertEqual(panel.groupJoinTargetID, first.id)
        panel.window?.sendEvent(try keyEvent(53, ""))
        XCTAssertEqual(panel.selectedGroupID, first.id)
        XCTAssertEqual(panel.activeSearchScopeGroupID, first.id)
        XCTAssertEqual(panel.selectedEntryID, selection)
        XCTAssertEqual(panel.visibleQuery, "匹配")
        XCTAssertTrue(panel.isSearchControlVisible)
        XCTAssertEqual(model.groupIDs(for: entry.id), Set([first.id]))
        XCTAssertNil(board.string(forType: .string))
    }
}

private final class TestCardDraggingInfo: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggingLocation: NSPoint = .zero
    var draggedImageLocation: NSPoint = .zero
    var draggedImage: NSImage? { nil }
    let draggingPasteboard: NSPasteboard
    var draggingSource: Any?
    var draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight = .none
    init(pasteboard: NSPasteboard, source: Any?) { draggingPasteboard = pasteboard; draggingSource = source }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
