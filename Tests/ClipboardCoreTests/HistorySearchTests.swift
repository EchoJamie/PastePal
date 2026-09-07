import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import ClipboardCore

final class HistorySearchTests: HistoryTestSupport {
    func testSearchUsesFullLiteralTextAndFiltersOutImages() throws {
        let store = try HistoryStore(directory: directory)
        _ = try store.record(text(String(repeating: "前文", count: 500) + "\nHello 世界 100% _"), limit: 10)
        _ = try store.record(image(), limit: 10)
        XCTAssertEqual(try store.entries(query: "hELLo 世界").count, 1)
        XCTAssertEqual(try store.entries(query: "100% _").count, 1)
        XCTAssertTrue(try store.entries(query: "世界", filter: .image).isEmpty)
        XCTAssertEqual(try store.entries(filter: .image).count, 1)
    }

    func testReadDeleteAndSearchHaveNoClipboardOrOrderSideEffects() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        try PasteboardIO.write(text("系统当前值").representations, to: board)
        let count = board.changeCount
        let store = try HistoryStore(directory: directory)
        let a = try store.record(text("A"), limit: 10); _ = try store.record(text("B"), limit: 10)
        _ = try store.content(id: a.id); _ = try store.entries(query: "A")
        XCTAssertEqual(try store.entries().compactMap(\.text), ["B", "A"])
        try store.delete(id: a.id)
        XCTAssertThrowsError(try store.markUsed(id: a.id))
        XCTAssertEqual(board.changeCount, count)
    }

    func testSnapshotKeepsOnlyVisibleSummaryAndDatabaseSearchesFullText() throws {
        let store = try HistoryStore(directory: directory)
        let marker = "只存在于摘要范围之外的检索词"
        let fullText = String(repeating: "前", count: 5_000) + marker
        let richBytes = Data(repeating: 0x5a, count: 512 * 1_024)
        let content = ClipboardContent(
            kind: .text,
            text: fullText,
            representations: [Representation(type: "public.rtf", data: richBytes)]
        )
        let recorded = try store.record(content, limit: 10)

        let summary = try XCTUnwrap(store.snapshot().entries.first)
        XCTAssertEqual(summary.id, recorded.id)
        XCTAssertEqual(summary.text?.count, 1_600)
        XCTAssertEqual(summary.textLength, fullText.count)
        XCTAssertNil(summary.representations.first?.inline)
        XCTAssertEqual(try store.summaries(query: marker).map(\.id), [recorded.id])
        XCTAssertEqual(try store.content(id: recorded.id).representations.first?.data, richBytes)
    }
}
