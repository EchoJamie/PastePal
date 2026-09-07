import PastePalLocalization
import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
import ClipboardCore
@testable import PastePal

final class ContentUseTests: AppTestSupport {
    @MainActor func testModelUsePlainTextUpdatesOriginalAndOwnMonitorDoesNotDuplicate() async throws {
        let model = try AppModel(directory: directory, settings: SettingsStore(defaults: defaults), pasteboard: board)
        let rich = values("  中文\nHello") + [Representation(type: "public.rtf", data: Data("{\\rtf1 Hello}".utf8))]
        let entry = try model.store.record(ContentCodec.decode(rich), limit: 10)
        _ = try model.store.record(ContentCodec.decode(values("后来")), limit: 10)
        var dismissed = false
        model.onDismiss = { dismissed = true }
        model.use(id: entry.id, plainText: true, copyOnly: true)
        try await waitUntil { dismissed }
        model.monitor.poll()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(board.string(forType: .string), "  中文\nHello")
        XCTAssertEqual(try model.store.entries().map(\.id).first, entry.id)
        XCTAssertEqual(try model.store.entries().count, 2)
        XCTAssertEqual(try model.store.content(id: entry.id).representations, rich.sorted { $0.type < $1.type })
        try PasteboardIO.write(values("外部紧接着复制"), to: board); model.monitor.poll()
        try await waitUntil { model.entries.first?.text == "外部紧接着复制" }
        XCTAssertEqual(try model.store.entries().count, 3)
    }

    @MainActor func testModelPartialFailureReportsCopiedAndDoesNotDismissOrPaste() async throws {
        enum Injected: Error { case failure }
        let model = try AppModel(directory: directory, settings: SettingsStore(defaults: defaults), pasteboard: board, fault: { if $0 == .beforeMarkUsed { throw Injected.failure } })
        let a = try model.store.record(ContentCodec.decode(values("A")), limit: 10)
        _ = try model.store.record(ContentCodec.decode(values("B")), limit: 10)
        var feedback: String?, dismissed = false
        model.onFeedback = { feedback = $0 }; model.onDismiss = { dismissed = true }
        model.use(id: a.id, copyOnly: true)
        try await waitUntil { feedback != nil }
        XCTAssertTrue(feedback!.contains(L("内容已复制，但历史顺序更新失败。请手动粘贴。\("")"))); XCTAssertFalse(dismissed)
        XCTAssertEqual(board.string(forType: .string), "A")
        XCTAssertEqual(try model.store.entries().compactMap(\.text), ["B", "A"])
    }

    @MainActor func testModelStaleIDNeverUsesNextItem() async throws {
        let model = try AppModel(directory: directory, settings: SettingsStore(defaults: defaults), pasteboard: board)
        let old = try model.store.record(ContentCodec.decode(values("旧内容")), limit: 1)
        _ = try model.store.record(ContentCodec.decode(values("新内容")), limit: 1)
        try PasteboardIO.write(values("当前系统内容"), to: board)
        var feedback: String?
        model.onFeedback = { feedback = $0 }
        model.use(id: old.id, copyOnly: true)
        try await waitUntil { feedback != nil }
        XCTAssertEqual(board.string(forType: .string), "当前系统内容")
        XCTAssertTrue(feedback!.contains(L("这条记录已被删除或淘汰，请重新选择。")))
    }

    @MainActor func testModelMissingFileLeavesCurrentPasteboardUntouched() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("已移动.txt")
        try Data("file".utf8).write(to: file)
        let model = try AppModel(directory: directory, settings: SettingsStore(defaults: defaults), pasteboard: board)
        let content = try ContentCodec.decode([Representation(type: "public.file-url", data: Data(file.absoluteString.utf8))])
        let entry = try model.store.record(content, limit: 10)
        try PasteboardIO.write(values("当前系统内容"), to: board)
        try FileManager.default.removeItem(at: file)
        var feedback: String?, dismissed = false
        model.onFeedback = { feedback = $0 }; model.onDismiss = { dismissed = true }

        model.use(id: entry.id, copyOnly: true)
        try await waitUntil { feedback != nil }
        XCTAssertEqual(board.string(forType: .string), "当前系统内容")
        XCTAssertTrue(feedback?.contains("已移动.txt") == true)
        XCTAssertFalse(dismissed)
    }

    @MainActor func testReturnUsesSelectionAndCommandReturnHasNoSeparateAction() throws {
        let collection = HistoryCollection()
        var normalUses = 0
        collection.onUse = { _ in normalUses += 1 }

        collection.keyDown(with: try keyEvent(36, "\r", modifiers: .command))
        XCTAssertEqual(normalUses, 0)
        collection.keyDown(with: try keyEvent(36, "\r"))
        collection.keyDown(with: try keyEvent(36, "\r", modifiers: .option))

        XCTAssertEqual(normalUses, 1)
    }
}
