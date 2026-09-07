import PastePalLocalization
import XCTest
import AppKit
import ClipboardCore
@testable import PastePal

final class RetentionSettingsTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var board: NSPasteboard!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PastePalRetentionApp-\(UUID().uuidString)")
        suite = "PastePalRetentionApp.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        board = NSPasteboard.withUniqueName()
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite); board.releaseGlobally()
        try? FileManager.default.removeItem(at: directory)
    }
    private func content(_ text: String) -> ClipboardContent {
        ClipboardContent(kind: .text, text: text, representations: [Representation(type: "public.utf8-plain-text", data: Data(text.utf8))])
    }
    func testUpgradeDefaultsAndBothInputsPersist() throws {
        defaults.set(321, forKey: "historyLimit")
        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.retentionPolicy, .init(mode: .count, count: 321, days: 30))
        try settings.saveRetentionPolicy(.init(mode: .time, count: 321, days: 7))
        try settings.saveRetentionPolicy(.init(mode: .count, count: 25, days: 7))
        XCTAssertEqual(SettingsStore(defaults: defaults).retentionPolicy, .init(mode: .count, count: 25, days: 7))
        XCTAssertThrowsError(try settings.saveRetentionPolicy(.init(mode: .time, count: 0, days: 7)))
        XCTAssertEqual(settings.retentionPolicy, .init(mode: .count, count: 25, days: 7))
    }
    func testUnconfiguredDefaultsToThirtyDaysWithoutPersistingAChoice() {
        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.retentionPolicy, .init(mode: .time, count: 10000, days: 30))
        XCTAssertNil(defaults.persistentDomain(forName: suite)?["historyRetentionMode"])
        XCTAssertNil(defaults.persistentDomain(forName: suite)?["historyLimit"])
        XCTAssertEqual(SettingsStore(defaults: defaults).retentionMode, .time)
    }
    func testLegacyThousandAndExplicitChoicesArePreserved() throws {
        defaults.set(1000, forKey: "historyLimit")
        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.retentionPolicy, .init(mode: .count, count: 1000, days: 30))
        try settings.saveRetentionPolicy(.init(mode: .time, count: 1000, days: 7))
        XCTAssertEqual(SettingsStore(defaults: defaults).retentionPolicy, .init(mode: .time, count: 1000, days: 7))
        try settings.saveRetentionPolicy(.init(mode: .count, count: 1000, days: 7))
        XCTAssertEqual(SettingsStore(defaults: defaults).retentionPolicy, .init(mode: .count, count: 1000, days: 7))
    }
    @MainActor func testStartupAndIdleTimerExpireWithoutCopy() async throws {
        let lock = NSLock()
        var instant = Date(timeIntervalSince1970: 2_000_000)
        let settings = SettingsStore(defaults: defaults)
        try settings.saveRetentionPolicy(.init(mode: .time, count: 1, days: 1))
        let model = try AppModel(directory: directory, settings: settings, pasteboard: board,
                                 retentionClock: { lock.withLock { instant } }, retentionInterval: 0.05)
        _ = try model.store.record(content("expired at startup"), limit: 10, now: instant.addingTimeInterval(-200_000))
        let current = try model.store.record(content("expires while idle"), limit: 10, now: instant)
        model.start()
        for _ in 0..<100 {
            if model.entries.map(\.id) == [current.id] { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.entries.map(\.id), [current.id])
        lock.withLock { instant = instant.addingTimeInterval(86_401) }
        for _ in 0..<100 {
            if model.entries.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.entries.isEmpty)
        await withCheckedContinuation { continuation in model.prepareToQuit { continuation.resume() } }
    }
    @MainActor func testFailedCleanupKeepsSavedSettingsAndHistoryThenRetrySucceeds() async throws {
        var fail = false
        let settings = SettingsStore(defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000)
        let model = try AppModel(directory: directory, settings: settings, pasteboard: board,
                                 fault: { if fail, $0 == .beforeCommit { throw ClipboardError.database("fixture") } },
                                 retentionClock: { now })
        _ = try model.store.record(content("old fixture"), limit: 10, now: now.addingTimeInterval(-200_000))
        let policy = HistoryRetentionPolicy(mode: .time, count: 12, days: 1)
        fail = true
        let failed: Bool = await withCheckedContinuation { continuation in
            model.setRetentionPolicy(policy) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(failed)
        XCTAssertEqual(settings.retentionPolicy, policy)
        for _ in 0..<100 {
            if model.status?.contains(L("保留设置已保存，后台清理失败，将在后续维护时重试。\("")")) == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.status?.contains(L("保留设置已保存，后台清理失败，将在后续维护时重试。\("")")) == true)
        XCTAssertEqual(try model.store.entries().count, 1)
        fail = false
        let succeeded: Bool = await withCheckedContinuation { continuation in
            model.setRetentionPolicy(policy) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(succeeded)
        XCTAssertEqual(settings.retentionPolicy, policy)
        await withCheckedContinuation { continuation in model.prepareToQuit { continuation.resume() } }
        XCTAssertTrue(try model.store.entries().isEmpty)
    }
    @MainActor func testSavingDoesNotWaitForCleanupAndQueuedPoliciesUseLatest() async throws {
        let barrier = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var calls = 0
        let settings = SettingsStore(defaults: defaults)
        let model = try AppModel(directory: directory, settings: settings, pasteboard: board, retentionClock: {
            let call = lock.withLock { calls += 1; return calls }
            if call == 1 { _ = barrier.wait(timeout: .now() + 5) }
            return Date()
        })
        var saved = false
        model.setRetentionPolicy(.init(mode: .time, count: 1000, days: 7)) { saved = $0 }
        XCTAssertTrue(saved)
        for _ in 0..<100 {
            if lock.withLock({ calls > 0 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(lock.withLock { calls }, 1)
        model.setRetentionPolicy(.init(mode: .time, count: 1000, days: 14)) { XCTAssertTrue($0) }
        model.setRetentionPolicy(.init(mode: .count, count: 250, days: 14)) { XCTAssertTrue($0) }
        XCTAssertEqual(settings.retentionPolicy, .init(mode: .count, count: 250, days: 14))
        XCTAssertEqual(lock.withLock { calls }, 1)
        barrier.signal()
        await withCheckedContinuation { continuation in model.prepareToQuit { continuation.resume() } }
        XCTAssertEqual(lock.withLock { calls }, 2)
        model.setRetentionPolicy(.init(mode: .time, count: 250, days: 0)) { XCTAssertFalse($0) }
        XCTAssertEqual(settings.retentionPolicy, .init(mode: .count, count: 250, days: 14))
    }

}

final class RetentionConcurrencyTests: AppTestSupport {
    @MainActor func testLowerLimitAppliesToCopiesQueuedWhileSettingsSave() async throws {
        defaults.set("count", forKey: "historyRetentionMode")
        let model = try AppModel(directory: directory, settings: SettingsStore(defaults: defaults), pasteboard: board)
        var previous: [HistoryEntry] = []
        for i in 0..<5 { previous.append(try model.store.record(ContentCodec.decode(values("之前 \(i)")), limit: 1000)) }
        let group = try model.store.createGroup(name: "长期保留")
        try model.store.add(entryID: previous[0].id, toGroup: group.id)
        var changed = false
        model.setLimit(1) { changed = $0 }
        for i in 0..<5 { try PasteboardIO.write(values("之后 \(i)"), to: board); model.monitor.poll() }
        try await waitUntil { changed && model.entries.first?.text == "之后 4" }
        XCTAssertEqual(model.settings.limit, 1)
        XCTAssertEqual(try model.store.ungroupedEntryCount(), 1)
        XCTAssertEqual(try model.store.entries().count, 2)
        XCTAssertEqual(try model.store.entryIDs(in: group.id), [previous[0].id])
    }
}
