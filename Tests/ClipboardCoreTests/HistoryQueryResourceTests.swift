import XCTest
@testable import ClipboardCore

final class HistoryQueryResourceTests: HistoryTestSupport {
    func testPagedResultsKeepEntireHistoryAndGroupScopeWithBoundedCache() throws {
        let store = try HistoryStore(directory: directory)
        let group = try store.createGroup(name: "保留全部")
        var ids = [String]()
        for index in 0..<330 {
            let entry = try store.record(text("marker-\(index)"), limit: 1000)
            ids.append(entry.id)
            if index % 3 == 0 { try store.add(entryID: entry.id, toGroup: group.id) }
        }
        let overview = try store.overview()
        XCTAssertEqual(overview.entries.count, 128)
        XCTAssertEqual(overview.count, 330)
        let results = try HistoryQueryResults(directory: directory, pageSize: 16)
        XCTAssertEqual(results.count, 330)
        for index in stride(from: 0, to: 330, by: 16) {
            XCTAssertEqual(try results.entry(at: index)?.id, ids[329 - index])
            XCTAssertLessThanOrEqual(results.cachedEntryCount, 64)
        }
        XCTAssertEqual(try results.entry(at: 329)?.id, ids[0])
        XCTAssertEqual(try results.index(of: ids[0]), 329)
        let scoped = try HistoryQueryResults(directory: directory, query: "marker-0", groupID: group.id)
        XCTAssertEqual(scoped.count, 1)
        XCTAssertEqual(try scoped.entry(at: 0)?.id, ids[0])
        XCTAssertEqual(try store.groupIDs(for: ids[0]), [group.id])
        try store.applyRetention(HistoryRetentionPolicy(count: 1))
        XCTAssertTrue(try store.contains(id: ids[0]))
        XCTAssertEqual(results.count, 330)
        XCTAssertEqual(try results.entry(at: 100)?.id, ids[229], "同一结果集的翻页排序不受写入连接改变")
    }

    func testCancellationStopsPagesWithoutInterruptingWrites() throws {
        let store = try HistoryStore(directory: directory)
        _ = try store.record(text("已有内容"), limit: 10)
        let token = HistoryQueryCancellation()
        let results = try HistoryQueryResults(directory: directory, cancellation: token)
        token.cancel()
        XCTAssertThrowsError(try results.entry(at: 0)) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try HistoryQueryResults(directory: directory, query: "旧查询", cancellation: token))
        _ = try store.record(text("写入不受取消影响"), limit: 10)
        XCTAssertEqual(try store.overview().count, 2)
    }

    func testRetentionCountAndMembershipQueriesCoverRowsOutsideOverview() throws {
        let store = try HistoryStore(directory: directory)
        let protected = try store.record(text("永久分组"), limit: 1000)
        let group = try store.createGroup(name: "保护")
        try store.add(entryID: protected.id, toGroup: group.id)
        for index in 0..<140 { _ = try store.record(text("后续\(index)"), limit: 1000) }
        XCTAssertFalse(try store.overview().entries.contains { $0.id == protected.id })
        XCTAssertEqual(try store.entryIDs(in: group.id), [protected.id])
        XCTAssertEqual(try store.retentionRemovalCount(for: HistoryRetentionPolicy(count: 10), now: Date()), 130)
    }
    func testStreamingMetadataReusePreservesNormalizedUnicodeURLs() throws {
        let store = try HistoryStore(directory: directory)
        let url = "https://example.com/中文"
        let first = try store.record(text(url), limit: 10)
        XCTAssertTrue(try store.updateLinkMetadata(id: first.id, expectedFingerprint: first.fingerprint, payload: LinkMetadataPayload(status: .ready, title: "已有标题")))
        let second = try store.record(text(url, extra: [Representation(type: "public.html", data: Data("<a>中文</a>".utf8))]), limit: 10)
        XCTAssertTrue(try store.reuseLinkMetadata(id: second.id, expectedFingerprint: second.fingerprint, url: try XCTUnwrap(second.linkURL)))
        XCTAssertEqual(try store.overview().entries.first?.linkMetadata?.title, "已有标题")
    }

    func testRecoveredCaptureUsesCurrentRetentionClockWithoutChangingCopyTime() throws {
        let store = try HistoryStore(directory: directory)
        let now = Date(timeIntervalSince1970: 2_000_000)
        let captured = now.addingTimeInterval(-3 * 86_400)
        let entry = try store.record(text("过期暂存"), policy: HistoryRetentionPolicy(mode: .time, days: 1), now: captured, retentionNow: now)
        XCTAssertEqual(entry.copiedAt, captured)
        XCTAssertFalse(try store.contains(id: entry.id))
    }

}
