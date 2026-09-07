import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import ClipboardCore

final class HistoryRecoveryTests: HistoryTestSupport {
    func testImageSurvivesReopenAndDeletionCleansFiles() throws {
        let content = try image()
        XCTAssertEqual(content.width, 32); XCTAssertEqual(content.height, 16)
        var store: HistoryStore? = try HistoryStore(directory: directory)
        let entry = try store!.record(content, limit: 10)
        XCTAssertEqual(entry.files.count, 2)
        store = nil; store = try HistoryStore(directory: directory)
        XCTAssertEqual(try store!.content(id: entry.id).representations, content.representations)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store!.thumbnailURL(for: entry)!.path))
        try store!.delete(id: entry.id)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store!.imageDirectory.path).isEmpty)
    }

    func testImageEvictionAndClearRemoveUnreferencedFiles() throws {
        let store = try HistoryStore(directory: directory)
        _ = try store.record(image(), limit: 1)
        _ = try store.record(text("文字"), limit: 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.imageDirectory.path).isEmpty)
        _ = try store.record(image(), limit: 10)
        try store.clear()
        XCTAssertTrue(try store.entries().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.imageDirectory.path).isEmpty)
    }

    func testTransactionFailurePreservesOldHistoryAndReferencedImage() throws {
        enum Injected: Error { case failure }
        var fail = false
        let store = try HistoryStore(directory: directory) { if fail && $0 == .beforeCommit { throw Injected.failure } }
        let old = try store.record(image(), limit: 1)
        fail = true
        XCTAssertThrowsError(try store.record(text("不能提交"), limit: 1))
        XCTAssertEqual(try store.entries().map(\.id), [old.id])
        XCTAssertNoThrow(try store.content(id: old.id))
        XCTAssertThrowsError(try store.clear())
        XCTAssertEqual(try store.entries().count, 1)
    }

    func testImageFileFailureLeavesExistingHistory() throws {
        enum Injected: Error { case failure }
        let store = try HistoryStore(directory: directory) { if $0 == .beforeFileWrite { throw Injected.failure } }
        let old = try store.record(text("已保存"), limit: 1)
        XCTAssertThrowsError(try store.record(image(), limit: 1))
        XCTAssertEqual(try store.entries().map(\.id), [old.id])
    }

    func testMissingImageDoesNotTouchPasteboardAndOrphansCleanOnOpen() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        try PasteboardIO.write(text("保留").representations, to: board)
        var store: HistoryStore? = try HistoryStore(directory: directory)
        let entry = try store!.record(image(), limit: 5)
        try FileManager.default.removeItem(at: store!.imageDirectory.appendingPathComponent(entry.files[0]))
        XCTAssertThrowsError(try store!.content(id: entry.id))
        XCTAssertEqual(board.string(forType: .string), "保留")
        let orphan = store!.imageDirectory.appendingPathComponent("orphan.data")
        try Data([1]).write(to: orphan)
        store = nil; store = try HistoryStore(directory: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testPostWriteDatabaseFailureKeepsWrittenClipboardAndOldOrder() throws {
        enum Injected: Error { case failure }
        let store = try HistoryStore(directory: directory) { if $0 == .beforeMarkUsed { throw Injected.failure } }
        let a = try store.record(text("A"), limit: 10); _ = try store.record(text("B"), limit: 10)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        try PasteboardIO.write(store.content(id: a.id).representations, to: board)
        XCTAssertThrowsError(try store.markUsed(id: a.id))
        XCTAssertEqual(board.string(forType: .string), "A")
        XCTAssertEqual(try store.entries().compactMap(\.text), ["B", "A"])
    }

    func testCleanupFailureKeepsCommittedStateAndCanRetry() throws {
        enum Injected: Error { case failure }
        var fail = false
        let store = try HistoryStore(directory: directory) { if fail && $0 == .beforeCleanup { throw Injected.failure } }
        _ = try store.record(image(), limit: 10)
        fail = true
        try store.clear()
        XCTAssertTrue(try store.entries().isEmpty)
        XCTAssertNotNil(store.cleanupWarning)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: store.imageDirectory.path).isEmpty)
        fail = false
        try store.cleanup()
        XCTAssertNil(store.cleanupWarning)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.imageDirectory.path).isEmpty)
    }
}
