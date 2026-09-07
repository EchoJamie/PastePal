import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import ClipboardCore

final class HistoryGroupTests: HistoryTestSupport {
    func testMovingAcrossSeveralGroupsInsertsAndPersistsIntermediateOrder() throws {
        var store: HistoryStore? = try HistoryStore(directory: directory)
        let groups = try ["甲", "乙", "丙", "丁"].map { try store!.createGroup(name: $0) }
        try store!.moveGroup(id: groups[0].id, offset: 3)
        XCTAssertEqual(try store!.groups().map(\.name), ["乙", "丙", "丁", "甲"])
        store = nil
        store = try HistoryStore(directory: directory)
        XCTAssertEqual(try store!.groups().map(\.name), ["乙", "丙", "丁", "甲"])
        try store!.moveGroup(id: groups[0].id, offset: -2)
        XCTAssertEqual(try store!.groups().map(\.name), ["乙", "甲", "丙", "丁"])
        try store!.moveGroup(id: groups[0].id, offset: 1)
        XCTAssertEqual(try store!.groups().map(\.name), ["乙", "丙", "甲", "丁"])
    }

    func testGroupsPersistOrderNamesAndManyToManyMembershipAcrossReopen() throws {
        var store: HistoryStore? = try HistoryStore(directory: directory)
        let first = try store!.createGroup(name: " 工作 ")
        let second = try store!.createGroup(name: "稍后读")
        let entry = try store!.record(text("同一条内容"), limit: 10)
        try store!.add(entryID: entry.id, toGroup: first.id)
        try store!.add(entryID: entry.id, toGroup: second.id)
        try store!.renameGroup(id: second.id, name: "资料")
        try store!.moveGroup(id: second.id, offset: -1)
        XCTAssertThrowsError(try store!.createGroup(name: "资料")) { error in
            XCTAssertEqual(error as? ClipboardError, .duplicateGroupName)
        }
        XCTAssertThrowsError(try store!.createGroup(name: "   ")) { error in
            XCTAssertEqual(error as? ClipboardError, .invalidGroupName)
        }
        XCTAssertThrowsError(try store!.createGroup(name: String(repeating: "长", count: 41))) { error in
            XCTAssertEqual(error as? ClipboardError, .invalidGroupName)
        }

        store = nil
        store = try HistoryStore(directory: directory)
        XCTAssertEqual(try store!.groups().map(\.name), ["资料", "工作"])
        XCTAssertEqual(try store!.groupIDs(for: entry.id), Set([first.id, second.id]))
        XCTAssertEqual(try store!.entryIDs(in: first.id), [entry.id])

        let copiedAgain = try store!.record(text("同一条内容"), limit: 1)
        XCTAssertEqual(copiedAgain.id, entry.id)
        XCTAssertEqual(try store!.groupIDs(for: entry.id), Set([first.id, second.id]), "历史去重不能丢失分组归属")
    }

    func testGroupedEntriesSurviveUngroupedQuotaAndLastRemovalReappliesLimit() throws {
        let store = try HistoryStore(directory: directory)
        let group = try store.createGroup(name: "长期资料")
        let kept = try store.record(text("分组保留"), limit: 2, now: Date(timeIntervalSince1970: 1))
        try store.add(entryID: kept.id, toGroup: group.id)
        _ = try store.record(text("普通 1"), limit: 2, now: Date(timeIntervalSince1970: 2))
        _ = try store.record(text("普通 2"), limit: 2, now: Date(timeIntervalSince1970: 3))
        _ = try store.record(text("普通 3"), limit: 2, now: Date(timeIntervalSince1970: 4))

        XCTAssertEqual(try store.entries().compactMap(\.text), ["普通 3", "普通 2", "分组保留"])
        XCTAssertEqual(try store.ungroupedEntryCount(), 2)
        XCTAssertEqual(try store.entryIDs(in: group.id), [kept.id])

        try store.remove(entryID: kept.id, fromGroup: group.id, limit: 2)
        XCTAssertThrowsError(try store.content(id: kept.id)) { error in
            XCTAssertEqual(error as? ClipboardError, .missingEntry)
        }
        XCTAssertEqual(try store.entries().compactMap(\.text), ["普通 3", "普通 2"])
    }

    func testDeletingOneGroupKeepsOtherMembershipAndDeletingLastGroupUsesQuota() throws {
        let store = try HistoryStore(directory: directory)
        let first = try store.createGroup(name: "甲")
        let second = try store.createGroup(name: "乙")
        let entry = try store.record(text("跨组内容"), limit: 1, now: Date(timeIntervalSince1970: 1))
        try store.add(entryID: entry.id, toGroup: first.id)
        try store.add(entryID: entry.id, toGroup: second.id)
        _ = try store.record(text("最近普通内容"), limit: 1, now: Date(timeIntervalSince1970: 2))

        try store.deleteGroup(id: first.id, limit: 1)
        XCTAssertEqual(try store.groupIDs(for: entry.id), [second.id])
        XCTAssertEqual(try store.entries().count, 2)

        try store.deleteGroup(id: second.id, limit: 1)
        XCTAssertEqual(try store.entries().compactMap(\.text), ["最近普通内容"])
        XCTAssertTrue(try store.groups().isEmpty)
    }

    func testClearUngroupedPreservesGroupedEntriesAndPermanentDeleteCascadesMembership() throws {
        let store = try HistoryStore(directory: directory)
        let group = try store.createGroup(name: "保留")
        let grouped = try store.record(text("分组内容"), limit: 10)
        let ordinary = try store.record(text("普通历史"), limit: 10)
        try store.add(entryID: grouped.id, toGroup: group.id)

        try store.clearUngrouped()
        XCTAssertEqual(try store.entries().map(\.id), [grouped.id])
        XCTAssertEqual(try store.entryIDs(in: group.id), [grouped.id])
        XCTAssertThrowsError(try store.content(id: ordinary.id))

        try store.delete(id: grouped.id)
        XCTAssertTrue(try store.entries().isEmpty)
        XCTAssertTrue(try store.entryIDs(in: group.id).isEmpty)
        XCTAssertEqual(try store.groups(), [group])
    }

    func testGroupDeletionRollbackPreservesGroupMembershipAndEntry() throws {
        enum GroupFailure: Error { case injected }
        var fail = false
        let store = try HistoryStore(directory: directory) { if fail && $0 == .beforeCommit { throw GroupFailure.injected } }
        let group = try store.createGroup(name: "不能半删")
        let entry = try store.record(text("需要保留"), limit: 1, now: Date(timeIntervalSince1970: 1))
        try store.add(entryID: entry.id, toGroup: group.id)
        _ = try store.record(text("最近普通内容"), limit: 1, now: Date(timeIntervalSince1970: 2))

        fail = true
        XCTAssertThrowsError(try store.deleteGroup(id: group.id, limit: 1))
        fail = false
        XCTAssertEqual(try store.groups(), [group])
        XCTAssertEqual(try store.entryIDs(in: group.id), [entry.id])
        XCTAssertNoThrow(try store.content(id: entry.id))
    }
}
