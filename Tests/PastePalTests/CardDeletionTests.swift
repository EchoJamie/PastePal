import AppKit
import XCTest
@testable import PastePal

final class CardDeletionTests: AppTestSupport {
    @MainActor func testRepeatedDeletionKeepsIndexThenMovesLeftAtEnd() async throws {
        let (_, panel) = try await makePanel((1...12).map { "条目\($0)" })
        defer { panel.dismiss() }
        let window = try XCTUnwrap(panel.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 900, height: 356), display: false)
        window.contentView?.layoutSubtreeIfNeeded()
        for _ in 0..<6 { panel.historyView.keyDown(with: try keyEvent(124, "")) }
        while !panel.visibleEntryIDs.isEmpty {
            let before = panel.visibleEntryIDs
            let index = try XCTUnwrap(before.firstIndex(of: try XCTUnwrap(panel.selectedEntryID)))
            let scrollOrigin = panel.historyScrollView.contentView.bounds.origin
            let remaining = before.filter { $0 != panel.selectedEntryID }
            let expected = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)]
            panel.historyView.keyDown(with: try keyEvent(51, ""))
            try await waitUntil { panel.visibleEntryIDs.count == remaining.count }
            XCTAssertEqual(panel.visibleEntryIDs, remaining)
            XCTAssertEqual(panel.selectedEntryID, expected)
            if before.count == 12 {
                XCTAssertEqual(panel.historyScrollView.contentView.bounds.origin.x, scrollOrigin.x, accuracy: 1 / window.backingScaleFactor)
                XCTAssertEqual(panel.historyScrollView.contentView.bounds.origin.y, scrollOrigin.y)
            }
            XCTAssertTrue(panel.isCollectionFocused)
            if let selected = panel.historyView.selectionIndexPaths.first {
                panel.historyView.layoutSubtreeIfNeeded()
                let attributes = try XCTUnwrap(panel.historyView.collectionViewLayout?.layoutAttributesForItem(at: selected))
                XCTAssertTrue(panel.historyScrollView.documentVisibleRect.insetBy(dx: -0.5, dy: -0.5).contains(attributes.frame))
            }
        }
        XCTAssertTrue(panel.historyView.selectionIndexPaths.isEmpty)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor func testGroupRemovalAndFilteredDeletionSelectVisibleNeighbor() async throws {
        let (model, panel) = try await makePanel(["组外", "匹配甲", "匹配乙", "匹配丙", "匹配丁"])
        defer { panel.dismiss() }
        let group = try model.store.createGroup(name: "工作")
        for entry in model.entries where entry.text?.hasPrefix("匹配") == true {
            try model.store.add(entryID: entry.id, toGroup: group.id)
        }
        model.refresh()
        try await waitUntil { model.groups.count == 1 }
        panel.selectGroup(group.id)
        panel.historyView.keyDown(with: try keyEvent(124, ""))
        let grouped = panel.visibleEntryIDs
        let removedID = try XCTUnwrap(panel.selectedEntryID)
        panel.historyView.keyDown(with: try keyEvent(51, ""))
        try await waitUntil { panel.visibleEntryIDs.count == 3 }
        XCTAssertEqual(panel.selectedEntryID, grouped[2])
        XCTAssertFalse(model.entryIDs(in: group.id).contains(removedID))
        XCTAssertNoThrow(try model.store.content(id: removedID), "分组中删除只移除成员关系")

        panel.selectGroup(nil)
        panel.beginSearch(selectAll: false)
        panel.searchControl.stringValue = "匹配"
        panel.finishSearch()
        panel.historyView.keyDown(with: try keyEvent(124, ""))
        let filtered = panel.visibleEntryIDs
        let index = try XCTUnwrap(filtered.firstIndex(of: try XCTUnwrap(panel.selectedEntryID)))
        let remaining = filtered.filter { $0 != panel.selectedEntryID }
        panel.historyView.keyDown(with: try keyEvent(51, ""))
        try await waitUntil { panel.visibleEntryIDs.count == filtered.count - 1 }
        XCTAssertEqual(panel.selectedEntryID, remaining[min(index, remaining.count - 1)])
        XCTAssertTrue(panel.isCollectionFocused)
        XCTAssertFalse(panel.window?.isVisible == true)
    }
}
