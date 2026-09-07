import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import ClipboardCore

final class HistoryRecordingTests: HistoryTestSupport {
    func testCopyDedupUseAndReopenKeepPersistentOrderAndDates() throws {
        var store: HistoryStore? = try HistoryStore(directory: directory)
        let a = try store!.record(text("A"), limit: 10, now: Date(timeIntervalSince1970: 10))
        _ = try store!.record(text("B"), limit: 10)
        _ = try store!.record(text("C"), limit: 10)
        try store!.markUsed(id: a.id, now: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(try store!.entries().compactMap(\.text), ["A", "C", "B"])
        XCTAssertEqual(try store!.entries()[0].createdAt, a.createdAt)
        XCTAssertEqual(try store!.entries()[0].copiedAt, a.copiedAt)
        store = nil
        store = try HistoryStore(directory: directory)
        _ = try store!.record(text("B"), limit: 10)
        XCTAssertEqual(try store!.entries().compactMap(\.text), ["B", "A", "C"])
        XCTAssertEqual(try store!.entries().count, 3)
    }

    func testABAOnlyKeepsTwoAndFormatDifferencesStayDistinct() throws {
        let store = try HistoryStore(directory: directory)
        _ = try store.record(text("A"), limit: 10); _ = try store.record(text("B"), limit: 10)
        let a = try store.record(text("A"), limit: 10)
        XCTAssertEqual(try store.entries().compactMap(\.text), ["A", "B"])
        let rich = try store.record(text("A", extra: [Representation(type: "public.rtf", data: Data("{\\rtf1 A}".utf8))]), limit: 10)
        XCTAssertNotEqual(a.id, rich.id)
        XCTAssertEqual(try store.entries().count, 3)
    }

    func testFingerprintPreservesMultipleItemBoundariesAndOrder() {
        let first = Representation(type: "public.file-url", data: Data("file:///a".utf8), itemIndex: 0)
        let second = Representation(type: "public.file-url", data: Data("file:///b".utf8), itemIndex: 1)
        let reversedItems = [
            Representation(type: second.type, data: second.data, itemIndex: 0),
            Representation(type: first.type, data: first.data, itemIndex: 1)
        ]
        XCTAssertNotEqual(ClipboardContent.digest([first, second]), ClipboardContent.digest(reversedItems))
    }

    func testLegacyRepresentationJSONDefaultsToFirstPasteboardItem() throws {
        struct LegacyRepresentation: Codable { let type: String; let data: Data }
        struct LegacyStoredRepresentation: Codable { let type: String; let inline: Data?; let file: String? }
        struct LegacyHistoryEntry: Codable {
            let id: String
            let fingerprint: String
            let kind: ContentKind
            let text: String?
            let source: SourceApplication?
            let createdAt: Date
            let copiedAt: Date
            let usedAt: Date?
            let activity: Int64
            let representations: [LegacyStoredRepresentation]
            let thumbnailFile: String?
            let width: Int?
            let height: Int?
        }
        let representation = try JSONDecoder().decode(Representation.self, from: JSONEncoder().encode(LegacyRepresentation(type: "public.utf8-plain-text", data: Data("旧记录".utf8))))
        let legacyStored = LegacyStoredRepresentation(type: representation.type, inline: representation.data, file: nil)
        let stored = try JSONDecoder().decode(StoredRepresentation.self, from: JSONEncoder().encode(legacyStored))
        let legacyEntry = LegacyHistoryEntry(id: "legacy", fingerprint: "digest", kind: .text, text: "旧记录", source: SourceApplication(bundleID: "com.apple.TextEdit", name: "文本编辑"), createdAt: Date(timeIntervalSince1970: 1), copiedAt: Date(timeIntervalSince1970: 2), usedAt: nil, activity: 3, representations: [legacyStored], thumbnailFile: nil, width: nil, height: nil)
        let entry = try JSONDecoder().decode(HistoryEntry.self, from: JSONEncoder().encode(legacyEntry))
        XCTAssertEqual(representation.itemIndex, 0)
        XCTAssertEqual(stored.itemIndex, 0)
        XCTAssertEqual(entry.id, "legacy")
        XCTAssertNil(entry.frameCount)
        XCTAssertEqual(entry.source?.name, "文本编辑")
        XCTAssertNil(entry.source?.iconFile)
        XCTAssertEqual(entry.source?.attribution, .declared)
        XCTAssertNil(entry.linkMetadata)
    }

    func testFingerprintIncludesTypesAndBytesButNotRepresentationOrder() {
        let a = text("same", extra: [Representation(type: "public.rtf", data: Data([0, 1]))])
        XCTAssertEqual(a.fingerprint, ClipboardContent.digest(a.representations.reversed()))
        XCTAssertNotEqual(a.fingerprint, text("same").fingerprint)
    }
}
