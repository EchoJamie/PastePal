import PastePalLocalization
import XCTest
import ClipboardCore
@testable import PastePal

final class CaptureInboxTests: AppTestSupport {
    func testSpoolPreservesEveryRepresentationOrderAndSurvivesReopening() throws {
        let inbox = try CaptureInbox(directory: directory)
        let source = SourceApplication(bundleID: "test.application", name: "测试")
        for index in 0..<20 {
            try inbox.append([Representation(type: "public.rtf", data: Data(repeating: UInt8(index), count: 256 * 1024), itemIndex: 0)], source: source, icon: nil, capturedAt: Date(timeIntervalSince1970: Double(index)))
        }
        let recovered = try CaptureInbox(directory: directory)
        for index in 0..<20 {
            let capture = try XCTUnwrap(recovered.peek())
            XCTAssertEqual(capture.values[0].data, Data(repeating: UInt8(index), count: 256 * 1024))
            XCTAssertEqual(capture.source?.bundleID, source.bundleID)
            XCTAssertEqual(capture.capturedAt, Date(timeIntervalSince1970: Double(index)))
            try recovered.acknowledge(capture.sequence)
        }
        XCTAssertNil(try recovered.peek())
    }

    @MainActor func testSlowRecordingSpoolsBurstWithoutDroppingAcceptedCaptures() async throws {
        let reached = expectation(description: "首条记录进入数据库")
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var blocked = false
        let model = try AppModel(directory: directory, settings: SettingsStore(defaults: defaults), pasteboard: board, fault: { checkpoint in
            if checkpoint == .beforeCommit {
                let first = lock.withLock { () -> Bool in
                    if blocked { return false }; blocked = true; return true
                }
                if first { reached.fulfill(); _ = release.wait(timeout: .now() + 5) }
            }
        })
        defer { release.signal() }
        _ = try PasteboardIO.write(values("首条"), to: board); model.monitor.poll()
        await fulfillment(of: [reached], timeout: 2)
        for index in 1..<20 {
            _ = try PasteboardIO.write(values("burst-\(index) " + String(repeating: "字", count: 20_000)), to: board)
            model.monitor.poll()
        }
        let pending = directory.appendingPathComponent("CaptureInbox")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: pending.path).filter { !$0.hasPrefix(".") }.count, 20)
        release.signal()
        try await waitUntil { model.entryCount == 20 }
        XCTAssertEqual(try model.store.overview().count, 20)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: pending.path).isEmpty)
    }
    @MainActor func testFailedSpoolingReportsFailureAndLeavesPasteboardUntouched() async throws {
        let model = try AppModel(directory: directory, settings: SettingsStore(defaults: defaults), pasteboard: board)
        try Data("existing".utf8).write(to: directory.appendingPathComponent("CaptureInbox/0"))
        let original = values("仍在原剪贴板")
        _ = try PasteboardIO.write(original, to: board)
        model.monitor.poll()
        try await waitUntil { model.status?.contains(L("无法暂存本次复制，内容仍在系统剪贴板中。请释放空间后重新复制。\("")")) == true }
        XCTAssertEqual(try PasteboardIO.snapshot(board), original)
        XCTAssertEqual(try model.store.overview().count, 0)
    }

    @MainActor func testDatabaseFailureKeepsPendingCaptureForNextRetry() async throws {
        let lock = NSLock()
        var fail = true
        let model = try AppModel(directory: directory, settings: SettingsStore(defaults: defaults), pasteboard: board, fault: { checkpoint in
            if checkpoint == .beforeCommit, lock.withLock({ fail }) { throw NSError(domain: "fixture", code: 1) }
        })
        _ = try PasteboardIO.write(values("先暂存"), to: board); model.monitor.poll()
        try await waitUntil { model.status?.contains(L("复制内容已暂存，保存历史失败；后续复制或重新启动时会重试。\("")")) == true }
        XCTAssertEqual(try CaptureInbox(directory: directory).peek()?.values, values("先暂存"))
        lock.withLock { fail = false }
        _ = try PasteboardIO.write(values("之后复制"), to: board); model.monitor.poll()
        try await waitUntil { model.entryCount == 2 }
        XCTAssertEqual(Set(model.entries.compactMap(\.text)), ["先暂存", "之后复制"])
    }

    @MainActor func testClearRespectsCaptureOrderAcrossBatches() async throws {
        let began = expectation(description: "阻塞首批")
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var first = true
        let model = try AppModel(directory: directory, settings: SettingsStore(defaults: defaults), pasteboard: board, fault: { checkpoint in
            if checkpoint == .beforeCommit {
                let block = lock.withLock { () -> Bool in defer { first = false }; return first }
                if block { began.fulfill(); _ = release.wait(timeout: .now() + 5) }
            }
        })
        defer { release.signal() }
        _ = try PasteboardIO.write(values("清空前0"), to: board); model.monitor.poll()
        await fulfillment(of: [began], timeout: 2)
        for index in 1..<20 {
            _ = try PasteboardIO.write(values("清空前\(index)"), to: board); model.monitor.poll()
        }
        model.clear()
        _ = try PasteboardIO.write(values("清空之后"), to: board); model.monitor.poll()
        release.signal()
        try await waitUntil { model.entries.map(\.text) == ["清空之后"] }
        XCTAssertEqual(model.entryCount, 1)
    }

}
