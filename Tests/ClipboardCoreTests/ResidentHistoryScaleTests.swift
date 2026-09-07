import XCTest
import CSQLite
@testable import ClipboardCore

final class ResidentHistoryScaleTests: HistoryTestSupport {
    func testReadSnapshotReleasesWALAfterClosingResults() throws {
        let store = try HistoryStore(directory: directory)
        _ = try store.record(text("before snapshot"), limit: 10000)
        var results: HistoryQueryResults? = try HistoryQueryResults(directory: directory)
        weak var releasedResults: HistoryQueryResults?
        releasedResults = results
        for index in 0..<300 {
            _ = try store.record(text("wal-\(index) " + String(repeating: "x", count: 1024)), limit: 10000)
        }
        XCTAssertEqual(results?.count, 1)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(directory.appendingPathComponent("history.sqlite").path, &db, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "SELECT COUNT(*) FROM sqlite_master", nil, nil, nil), SQLITE_OK)
        let wal = directory.appendingPathComponent("history.sqlite-wal")
        let heldBytes = try FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? Int ?? 0
        XCTAssertEqual(sqlite3_wal_checkpoint_v2(db, "main", SQLITE_CHECKPOINT_TRUNCATE, nil, nil), SQLITE_BUSY)
        results = nil
        XCTAssertNil(releasedResults)
        XCTAssertEqual(sqlite3_wal_checkpoint_v2(db, "main", SQLITE_CHECKPOINT_TRUNCATE, nil, nil), SQLITE_OK)
        let releasedBytes = try FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? Int ?? 0
        XCTAssertEqual(releasedBytes, 0)
        XCTAssertEqual(try store.overview().count, 301)
        print("RESIDENT_CHECK reader_held_wal_bytes=\(heldBytes) reader_released_wal_bytes=\(releasedBytes) writes_preserved=301")
    }

    func testTenThousandRecordsAndRepeatedQueriesKeepResidentPagesBounded() throws {
        let store = try HistoryStore(directory: directory)
        for batch in 0..<10 {
            let began = Date()
            for index in (batch * 1000)..<((batch + 1) * 1000) {
                _ = try store.record(text("scale-\(index) " + String(repeating: "data ", count: 200)), limit: 10000)
            }
            let overview = try store.overview()
            XCTAssertEqual(overview.count, (batch + 1) * 1000)
            XCTAssertEqual(overview.entries.count, 128)
            print("RESIDENT_CHECK records=\(overview.count) batch_seconds=\(Date().timeIntervalSince(began)) overview_entries=\(overview.entries.count)")
        }
        for cycle in 0..<100 {
            try autoreleasepool {
                let cancellation = HistoryQueryCancellation()
                let results = try HistoryQueryResults(directory: directory, cancellation: cancellation)
                XCTAssertEqual(results.count, 10000)
                for index in stride(from: cycle, to: 10000, by: 641) {
                    XCTAssertNotNil(try results.entry(at: index))
                    XCTAssertLessThanOrEqual(results.cachedEntryCount, 256)
                }
                cancellation.cancel()
                XCTAssertThrowsError(try results.entry(at: 0)) { XCTAssertTrue($0 is CancellationError) }
            }
        }
        XCTAssertEqual(try store.overview().count, 10000)
        print("RESIDENT_CHECK query_cycles=100 maximum_cached_entries=256 writes_preserved=10000")
    }
}
