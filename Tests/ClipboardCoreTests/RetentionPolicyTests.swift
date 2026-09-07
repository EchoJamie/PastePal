import XCTest
import CSQLite
@testable import ClipboardCore

final class RetentionPolicyTests: XCTestCase {
    private var directory: URL!
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private let timed = HistoryRetentionPolicy(mode: .time, count: 1, days: 1)
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PastePalRetention-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private func content(_ text: String) -> ClipboardContent {
        ClipboardContent(kind: .text, text: text, representations: [Representation(type: "public.utf8-plain-text", data: Data(text.utf8))])
    }
    @discardableResult private func record(_ store: HistoryStore, _ text: String, at date: Date) throws -> HistoryEntry {
        try store.record(content(text), limit: 100, now: date)
    }
    func testRollingBoundaryAndTimeDoesNotApplyCount() throws {
        let store = try HistoryStore(directory: directory)
        let cutoff = timed.cutoff(now: now)
        try record(store, "before", at: cutoff.addingTimeInterval(-0.001))
        let equal = try record(store, "equal", at: cutoff)
        let after = try record(store, "after", at: cutoff.addingTimeInterval(0.001))
        try store.applyRetention(timed, now: now)
        XCTAssertEqual(Set(try store.entries().map(\.id)), [equal.id, after.id])
    }
    func testCountUsesMRUWithoutAgeRestriction() throws {
        let store = try HistoryStore(directory: directory)
        let old = try record(store, "old", at: now.addingTimeInterval(-1_000_000))
        try record(store, "new", at: now)
        try store.markUsed(id: old.id, now: now.addingTimeInterval(-900_000))
        try store.applyRetention(.init(mode: .count, count: 1, days: 1), now: now)
        XCTAssertEqual(try store.entries().map(\.id), [old.id])
    }
    func testGroupProtectionAndLastMembershipRemoval() throws {
        let store = try HistoryStore(directory: directory)
        let old = try record(store, "grouped", at: now.addingTimeInterval(-200_000))
        let a = try store.createGroup(name: "a"), b = try store.createGroup(name: "b")
        try store.add(entryID: old.id, toGroup: a.id)
        try store.add(entryID: old.id, toGroup: b.id)
        try store.applyRetention(timed, now: now)
        try store.remove(entryID: old.id, fromGroup: a.id, policy: timed, now: now)
        XCTAssertEqual(try store.entries().count, 1)
        try store.deleteGroup(id: b.id, policy: timed, now: now)
        XCTAssertTrue(try store.entries().isEmpty)
        let second = try record(store, "second", at: now.addingTimeInterval(-200_000))
        try store.add(entryID: second.id, toGroup: a.id)
        try store.remove(entryID: second.id, fromGroup: a.id, policy: timed, now: now)
        XCTAssertTrue(try store.entries().isEmpty)
    }
    func testCopyUseRenewButSearchAndMetadataDoNotResurrect() throws {
        let store = try HistoryStore(directory: directory)
        let copy = try record(store, "copy", at: now.addingTimeInterval(-200_000))
        let used = try record(store, "used", at: now.addingTimeInterval(-200_000))
        let searched = try record(store, "https://example.com", at: now.addingTimeInterval(-200_000))
        try store.markUsed(id: used.id, now: now)
        _ = try store.summaries(query: "example")
        _ = try store.content(id: searched.id)
        _ = try store.record(content("copy"), policy: timed, now: now)
        XCTAssertEqual(Set(try store.entries().map(\.id)), [copy.id, used.id])
        XCTAssertFalse(try store.updateLinkMetadata(id: searched.id, expectedFingerprint: searched.fingerprint,
                                                   payload: LinkMetadataPayload(status: .failed), now: now))
        try store.markUsed(id: used.id, policy: timed, now: now.addingTimeInterval(86_401))
        XCTAssertEqual(try store.entries().map(\.id), [used.id])
    }
    func testFailureRollsBackPruningAndGroupRemoval() throws {
        var fail = false
        let store = try HistoryStore(directory: directory, fault: { if fail, $0 == .beforeCommit { throw ClipboardError.database("fixture") } })
        let old = try record(store, "old", at: now.addingTimeInterval(-200_000))
        let group = try store.createGroup(name: "protected")
        try store.add(entryID: old.id, toGroup: group.id)
        fail = true
        XCTAssertThrowsError(try store.remove(entryID: old.id, fromGroup: group.id, policy: timed, now: now))
        XCTAssertEqual(try store.groupIDs(for: old.id), [group.id])
        fail = false
        try store.remove(entryID: old.id, fromGroup: group.id, policy: timed, now: now)
        XCTAssertTrue(try store.entries().isEmpty)
    }
    func testLegacyDatabaseActivityMigrationAndReopen() throws {
        var store: HistoryStore? = try HistoryStore(directory: directory)
        let copied = try record(store!, "copied", at: now)
        let used = try record(store!, "used", at: now.addingTimeInterval(-200_000))
        try store!.markUsed(id: used.id, now: now)
        store = nil
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("history.sqlite").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "DROP INDEX history_activity_at; ALTER TABLE history DROP COLUMN activity_at", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        store = try HistoryStore(directory: directory)
        try store!.applyRetention(timed, now: now)
        XCTAssertEqual(Set(try store!.entries().map(\.id)), [copied.id, used.id])
        store = nil
        store = try HistoryStore(directory: directory)
        try store!.applyRetention(timed, now: now.addingTimeInterval(86_401))
        XCTAssertTrue(try store!.entries().isEmpty)
    }
}

final class HistoryRetentionCountTests: HistoryTestSupport {
    func testLimitPrunesLeastRecentActivityAndRejectsZero() throws {
        let store = try HistoryStore(directory: directory)
        for i in 1...8 { _ = try store.record(text("\(i)"), limit: 5) }
        XCTAssertEqual(try store.entries().compactMap(\.text), ["8", "7", "6", "5", "4"])
        let oldest = try store.entries().last!
        try store.markUsed(id: oldest.id); try store.setLimit(2)
        XCTAssertEqual(try store.entries().compactMap(\.text), ["4", "8"])
        XCTAssertThrowsError(try store.setLimit(0))
        XCTAssertEqual(try store.entries().count, 2)
    }
}
