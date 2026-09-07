import XCTest
import AppKit
import ClipboardCore
@testable import PastePal

final class HistorySearchCoordinatorTests: AppTestSupport {
    @MainActor func testBurstOnlyExecutesActiveAndLatestQuery() async throws {
        let store = try HistoryStore(directory: directory)
        _ = try store.record(ContentCodec.decode(values("last")), limit: 10)
        let began = expectation(description: "首个查询开始")
        let completed = expectation(description: "最新查询完成")
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var executed = [String]()
        let coordinator = HistorySearchCoordinator(directory: directory, load: { [directory] query, groupID, token in
            lock.withLock { executed.append(query) }
            if query == "first" { began.fulfill(); _ = release.wait(timeout: .now() + 3) }
            return try HistoryQueryResults(directory: directory!, query: query, groupID: groupID, cancellation: token)
        })
        defer { release.signal(); coordinator.cancel() }
        coordinator.submit(query: "first", groupID: nil) { _ in XCTFail("过期查询不应发布") }
        await fulfillment(of: [began], timeout: 2)
        for index in 0..<100 {
            coordinator.submit(query: "obsolete-\(index)", groupID: nil) { _ in XCTFail("中间查询不应执行或发布") }
        }
        coordinator.submit(query: "last", groupID: nil) { result in
            XCTAssertEqual(try? result.get().count, 1)
            completed.fulfill()
        }
        release.signal()
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(lock.withLock { executed }, ["first", "last"])
    }
    @MainActor func testPanelCanSelectAndUseEntryBeyondResidentOverview() async throws {
        _ = NSApplication.shared
        let model = try AppModel(directory: directory, settings: SettingsStore(defaults: defaults), pasteboard: board)
        var firstID: String?
        for index in 0..<150 {
            let entry = try model.store.record(ContentCodec.decode(values("full-history-\(index)")), limit: 1000)
            if index == 0 { firstID = entry.id }
        }
        model.refresh()
        try await waitUntil { model.entryCount == 150 }
        XCTAssertEqual(model.entries.count, 128)
        let panel = PanelController(model: model)
        panel.show()
        XCTAssertEqual(panel.collectionView(panel.historyView, numberOfItemsInSection: 0), 150)
        panel.collectionView(panel.historyView, didSelectItemsAt: [IndexPath(item: 149, section: 0)])
        XCTAssertEqual(panel.selectedEntryID, firstID)
        panel.copySelected()
        try await waitUntil { self.board.string(forType: .string) == "full-history-0" }
        panel.dismiss()
    }

}
