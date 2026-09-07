import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import ClipboardCore

final class HistoryMetadataTests: HistoryTestSupport {
    func testRecopyUpdatesSourceWithoutLosingGroupsOrLinkMetadata() throws {
        let store = try HistoryStore(directory: directory)
        let group = try store.createGroup(name: "保留")
        let sourceLess = try store.record(text("旧无来源记录"), limit: 10)
        let content = text("https://example.com/source")
        let declared = SourceApplication(bundleID: "com.example.first", name: "首次应用")
        let first = try store.record(content, source: declared, limit: 10)
        try store.add(entryID: first.id, toGroup: group.id)
        XCTAssertTrue(try store.updateLinkMetadata(
            id: first.id,
            expectedFingerprint: first.fingerprint,
            payload: LinkMetadataPayload(status: .ready, title: "已缓存标题", siteName: "Example")
        ))

        let inferred = SourceApplication(bundleID: "com.example.second", name: "再次应用", attribution: .foreground)
        let copiedAgain = try store.record(content, source: inferred, limit: 10)
        XCTAssertEqual(copiedAgain.id, first.id)
        XCTAssertEqual(copiedAgain.source, inferred)
        XCTAssertEqual(copiedAgain.linkMetadata?.title, "已缓存标题")
        XCTAssertEqual(try store.groupIDs(for: first.id), [group.id])
        XCTAssertEqual(try store.entries().first { $0.id == first.id }?.source?.attribution, .foreground, "轻量摘要必须保留来源依据")
        XCTAssertNil(try store.entries().first { $0.id == sourceLess.id }?.source)

        let reopened = try HistoryStore(directory: directory)
        XCTAssertEqual(try reopened.entries().first { $0.id == first.id }?.source?.attribution, .foreground)
        XCTAssertNil(try reopened.entries().first { $0.id == sourceLess.id }?.source, "重开数据库不能为旧无来源记录补写来源")
    }

    func testLinkMetadataAndSourceIconPersistWithoutChangingClipboardIdentityOrOrder() throws {
        var store: HistoryStore? = try HistoryStore(directory: directory)
        let urlText = "https://github.com/openai/example"
        let content = text(urlText)
        let icon = try imageData(type: UTType.png.identifier)
        let source = SourceApplication(bundleID: "com.google.Chrome", name: "Google Chrome")
        let link = try store!.record(content, source: source, sourceIcon: icon, limit: 10, now: Date(timeIntervalSince1970: 10))
        let other = try store!.record(text("后来"), limit: 10, now: Date(timeIntervalSince1970: 20))
        let originalRepresentations = try store!.content(id: link.id).representations

        XCTAssertTrue(try store!.updateLinkMetadata(
            id: link.id,
            expectedFingerprint: link.fingerprint,
            payload: LinkMetadataPayload(status: .ready, title: "Example Repository", siteName: "GitHub", iconPNG: icon, previewPNG: icon),
            now: Date(timeIntervalSince1970: 30)
        ))
        let updated = try XCTUnwrap(store!.entries().first { $0.id == link.id })
        XCTAssertEqual(try store!.entries().map(\.id), [other.id, link.id])
        XCTAssertEqual(updated.activity, link.activity)
        XCTAssertEqual(updated.copiedAt, link.copiedAt)
        XCTAssertEqual(updated.fingerprint, link.fingerprint)
        XCTAssertEqual(try store!.content(id: link.id).representations, originalRepresentations)
        XCTAssertEqual(updated.source?.name, "Google Chrome")
        XCTAssertEqual(updated.linkMetadata?.siteName, "GitHub")
        XCTAssertEqual(try store!.entries(query: "example repository").map(\.id), [link.id])
        XCTAssertEqual(try store!.entries(query: "chrome").map(\.id), [link.id])
        XCTAssertEqual(try store!.entries(query: "com.google.Chrome").map(\.id), [link.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(store!.sourceIconURL(for: updated)).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(store!.linkIconURL(for: updated)).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(store!.linkPreviewURL(for: updated)).path))
        XCTAssertFalse(try store!.updateLinkMetadata(id: link.id, expectedFingerprint: link.fingerprint, payload: LinkMetadataPayload(status: .failed)))

        let richURL = text(urlText, extra: [Representation(type: "public.rtf", data: Data("{\\rtf1 URL}".utf8))])
        let variant = try store!.record(richURL, limit: 10)
        XCTAssertTrue(try store!.reuseLinkMetadata(id: variant.id, expectedFingerprint: variant.fingerprint, url: try XCTUnwrap(variant.linkURL)))
        let reused = try XCTUnwrap(store!.entries().first { $0.id == variant.id })
        XCTAssertEqual(reused.linkMetadata, updated.linkMetadata)

        store = nil; store = try HistoryStore(directory: directory)
        let reopened = try XCTUnwrap(store!.entries().first { $0.id == link.id })
        XCTAssertEqual(reopened.linkMetadata?.title, "Example Repository")
        XCTAssertEqual(reopened.source?.iconFile, updated.source?.iconFile)
        try store!.delete(id: link.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(store!.linkIconURL(for: reused)).path), "共享缓存仍被另一条记录引用")
        try store!.delete(id: variant.id)
        XCTAssertTrue(try store!.entries().map(\.id) == [other.id])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store!.imageDirectory.path).isEmpty)
    }

    func testFailedLinkMetadataPersistsAndLateResultCannotRestoreRemovedEntry() throws {
        var store: HistoryStore? = try HistoryStore(directory: directory)
        let failed = try store!.record(text("https://offline.example/path"), limit: 10)
        XCTAssertTrue(try store!.updateLinkMetadata(id: failed.id, expectedFingerprint: failed.fingerprint, payload: LinkMetadataPayload(status: .failed)))
        store = nil; store = try HistoryStore(directory: directory)
        XCTAssertEqual(try store!.entries().first?.linkMetadata?.status, .failed)

        let removed = try store!.record(text("https://deleted.example/path"), limit: 1)
        _ = try store!.record(text("淘汰它"), limit: 1)
        let image = try imageData(type: UTType.png.identifier)
        XCTAssertFalse(try store!.updateLinkMetadata(id: removed.id, expectedFingerprint: removed.fingerprint, payload: LinkMetadataPayload(status: .ready, title: "迟到标题", iconPNG: image, previewPNG: image)))
        XCTAssertEqual(try store!.entries().compactMap(\.text), ["淘汰它"])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store!.imageDirectory.path).isEmpty)
    }
}
