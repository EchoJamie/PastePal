import AppKit
import ClipboardCore
import XCTest
@testable import PastePal

final class InlinePreviewTests: AppTestSupport {
    @MainActor func testPreviewOnlyChangesHeightOnWidePanels() async throws {
        let (_, panel) = try await makePanel([String(repeating: "预览应保留历史面板原有宽度。", count: 100)])
        defer { panel.dismiss() }
        let window = try XCTUnwrap(panel.window)
        let root = try XCTUnwrap(window.contentView)
        for width: CGFloat in [800, 1440, 1920, 2560] {
            window.setFrame(NSRect(x: -300, y: 0, width: width, height: PanelLayout.height), display: false)
            root.layoutSubtreeIfNeeded()
            let original = window.frame
            let cardsFrame = panel.historyScrollView.convert(panel.historyScrollView.bounds, to: root)
            panel.historyView.keyDown(with: try keyEvent(49, " "))
            try await waitUntil { panel.isPreviewVisible }
            window.layoutIfNeeded()
            root.layoutSubtreeIfNeeded()
            XCTAssertEqual(window.frame.width, original.width)
            XCTAssertEqual(window.frame.origin, original.origin)
            XCTAssertEqual(root.frame.width, original.width)
            XCTAssertGreaterThan(window.frame.height, original.height)
            XCTAssertEqual(panel.historyScrollView.convert(panel.historyScrollView.bounds, to: root), cardsFrame)
            let preview = try XCTUnwrap(panel.previewView)
            let text = try XCTUnwrap(preview.textView)
            let readingArea = try XCTUnwrap(text.enclosingScrollView)
            XCTAssertEqual(readingArea.frame.width, min(760, preview.bounds.width - 32), accuracy: 0.5)
            XCTAssertEqual(readingArea.convert(readingArea.bounds, to: preview).midX, preview.bounds.midX, accuracy: 0.5)
            panel.closePreview()
            window.layoutIfNeeded()
            XCTAssertEqual(window.frame, original)
        }
        XCTAssertFalse(window.isVisible)
    }

    @MainActor func testTextPreviewExpandsUpwardAndReturnsToSelectionWithoutOpeningWindow() async throws {
        let (model, panel) = try await makePanel((1...12).map { "条目\($0)：保留文本选择和复制" })
        defer { panel.dismiss() }
        let window = try XCTUnwrap(panel.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1000, height: PanelLayout.height), display: false)
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        for _ in 0..<6 { panel.historyView.keyDown(with: try keyEvent(124, "")) }
        let selected = try XCTUnwrap(panel.selectedEntryID)
        let expectedText = try XCTUnwrap(model.store.content(id: selected).text)
        let originalFrame = window.frame
        let cardsFrame = panel.historyScrollView.convert(panel.historyScrollView.bounds, to: root)
        let scrollOrigin = panel.historyScrollView.contentView.bounds.origin
        let windows = NSApp.windows.map(ObjectIdentifier.init)

        panel.historyView.keyDown(with: try keyEvent(49, " "))
        try await waitUntil { panel.isPreviewVisible }
        root.layoutSubtreeIfNeeded()
        let preview = try XCTUnwrap(panel.previewView)
        XCTAssertTrue(preview.window === window)
        XCTAssertEqual(NSApp.windows.map(ObjectIdentifier.init), windows)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(window.frame.minY, originalFrame.minY)
        XCTAssertGreaterThan(window.frame.height, originalFrame.height)
        XCTAssertEqual(panel.historyScrollView.convert(panel.historyScrollView.bounds, to: root), cardsFrame)
        XCTAssertEqual(panel.historyScrollView.contentView.bounds.origin.x, scrollOrigin.x, accuracy: 1 / window.backingScaleFactor)
        XCTAssertEqual(panel.historyScrollView.contentView.bounds.origin.y, scrollOrigin.y)
        XCTAssertEqual(panel.selectedEntryID, selected)
        XCTAssertGreaterThanOrEqual(preview.convert(preview.bounds, to: root).minY, PanelLayout.height)
        let text = try XCTUnwrap(preview.textView)
        XCTAssertTrue(panel.isCollectionFocused)
        XCTAssertTrue(text.isSelectable)
        XCTAssertFalse(text.isEditable)
        XCTAssertEqual(text.string, expectedText)
        XCTAssertTrue(window.makeFirstResponder(text))
        text.setSelectedRange((text.string as NSString).range(of: "文本选择"))
        XCTAssertTrue(text.writeSelection(to: board, types: text.writablePasteboardTypes))
        XCTAssertEqual(board.string(forType: .string), "文本选择")

        text.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        root.layoutSubtreeIfNeeded()
        XCTAssertFalse(panel.isPreviewVisible)
        XCTAssertEqual(window.frame, originalFrame)
        XCTAssertEqual(panel.selectedEntryID, selected)
        XCTAssertEqual(panel.historyScrollView.contentView.bounds.origin.x, scrollOrigin.x, accuracy: 1 / window.backingScaleFactor)
        XCTAssertEqual(panel.historyScrollView.contentView.bounds.origin.y, scrollOrigin.y)
        XCTAssertTrue(panel.isCollectionFocused)
    }

    @MainActor func testSelectionUpdatesPreviewAndEscapeCancelsPendingUpdates() async throws {
        let (model, panel) = try await makePanel(["第一条", "第二条"])
        defer { panel.dismiss() }
        let original = try XCTUnwrap(panel.selectedEntryID)
        panel.historyView.keyDown(with: try keyEvent(49, " "))
        panel.historyView.keyDown(with: try keyEvent(53, ""))
        await withCheckedContinuation { continuation in
            model.loadContent(id: original) { _ in continuation.resume() }
        }
        XCTAssertFalse(panel.isPreviewVisible)
        XCTAssertEqual(panel.selectedEntryID, original)

        panel.historyView.keyDown(with: try keyEvent(49, " "))
        try await waitUntil { panel.isPreviewVisible }
        let frame = panel.window?.frame
        panel.historyView.keyDown(with: try keyEvent(124, ""))
        XCTAssertTrue(panel.isPreviewVisible)
        XCTAssertNotEqual(panel.selectedEntryID, original)
        let expected = try model.store.content(id: XCTUnwrap(panel.selectedEntryID)).text
        try await waitUntil { panel.previewView?.textView?.string == expected }
        XCTAssertEqual(panel.window?.frame, frame)
        XCTAssertTrue(panel.isCollectionFocused)

        panel.historyView.keyDown(with: try keyEvent(123, ""))
        panel.historyView.keyDown(with: try keyEvent(124, ""))
        panel.historyView.keyDown(with: try keyEvent(53, ""))
        await withCheckedContinuation { continuation in
            model.loadContent(id: original) { _ in continuation.resume() }
        }
        XCTAssertFalse(panel.isPreviewVisible)
        panel.historyView.keyDown(with: try keyEvent(49, " "))
        try await waitUntil { panel.isPreviewVisible }
        let selected = panel.selectedEntryID
        let close = try XCTUnwrap(descendants(of: panel.previewView).compactMap { $0 as? NSButton }.first)
        close.performClick(nil)
        XCTAssertFalse(panel.isPreviewVisible)
        XCTAssertEqual(panel.selectedEntryID, selected)
        XCTAssertTrue(panel.isCollectionFocused)

        panel.historyView.keyDown(with: try keyEvent(49, " "))
        try await waitUntil { panel.isPreviewVisible }
        panel.dismiss()
        XCTAssertNil(panel.previewView)
        XCTAssertEqual(panel.window?.frame.height, PanelLayout.height)
    }

    func testPreviewHeightFitsAvailableSpaceAboveCards() {
        XCTAssertEqual(PanelLayout.expandedHeight(availableHeight: 1200), PanelLayout.height + PanelLayout.previewHeight)
        XCTAssertEqual(PanelLayout.expandedHeight(availableHeight: 600), 600)
        XCTAssertEqual(PanelLayout.expandedHeight(availableHeight: PanelLayout.height), PanelLayout.height)
    }

    @MainActor func testCardSelectionUpdatesImagePreviewToTextAndDeletionKeepsPreview() async throws {
        let (model, panel) = try await makePanel(["切换后可以选择和复制的文字"])
        defer { panel.dismiss() }
        let entry = try model.store.record(ContentCodec.decode([Representation(type: "public.png", data: try pngData())]), limit: 10)
        model.refresh()
        try await waitUntil { model.entries.count == 2 }
        panel.prepareForDisplay()
        panel.historyView.keyDown(with: try keyEvent(49, " "))
        try await waitUntil { panel.isPreviewVisible }
        XCTAssertNotNil(descendants(of: panel.previewView).first { $0 is PreviewImageView })
        XCTAssertNil(panel.previewView?.textView)
        XCTAssertTrue(panel.isCollectionFocused)
        let frame = panel.window?.frame
        let next = IndexPath(item: 1, section: 0)
        panel.historyView.selectionIndexPaths = [next]
        panel.collectionView(panel.historyView, didSelectItemsAt: [next])
        XCTAssertTrue(panel.isPreviewVisible)
        try await waitUntil { panel.previewView?.textView?.string == "切换后可以选择和复制的文字" }
        XCTAssertEqual(panel.window?.frame, frame)
        XCTAssertTrue(panel.isCollectionFocused)
        panel.historyView.keyDown(with: try keyEvent(51, ""))
        try await waitUntil { panel.selectedEntryID == entry.id && panel.previewView?.textView == nil }
        XCTAssertTrue(panel.isPreviewVisible)
        XCTAssertEqual(panel.window?.frame, frame)
        panel.historyView.keyDown(with: try keyEvent(53, ""))
        XCTAssertFalse(panel.isPreviewVisible)
        XCTAssertEqual(panel.selectedEntryID, entry.id)
        XCTAssertTrue(panel.isCollectionFocused)
    }
}
