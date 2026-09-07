import PastePalLocalization
import XCTest
import AppKit
import ClipboardCore
@testable import PastePal

final class DirectPasteDefaultTests: AppTestSupport {
    @MainActor func testMissingAccessibilityBlocksClipboardWriteAndRequestsGuidance() async throws {
        let model = try AppModel(directory: directory, settings: SettingsStore(defaults: defaults), pasteboard: board, paste: PasteCoordinator(permission: { false }))
        let entry = try model.store.record(ContentCodec.decode(values("不得复制")), limit: 10)
        try PasteboardIO.write(values("原内容"), to: board)
        var guidance = 0
        model.onAccessibilityRequired = { guidance += 1 }
        model.use(id: entry.id)
        XCTAssertEqual(guidance, 1)
        XCTAssertEqual(board.string(forType: .string), "原内容")
        XCTAssertFalse(model.busy)
    }
    @MainActor func testLegacyFalseStillAttemptsPasteAndReportsMissingTargetWithoutPrompting() async throws {
        defaults.set(false, forKey: "directPaste")
        let model = try AppModel(directory: directory, settings: SettingsStore(defaults: defaults), pasteboard: board, paste: PasteCoordinator(permission: { true }))
        let entry = try model.store.record(ContentCodec.decode(values("默认直接粘贴")), limit: 10)
        model.paste.invalidate()
        var feedback: String?
        model.onFeedback = { feedback = $0 }
        model.use(id: entry.id)
        try await waitUntil { feedback != nil }
        XCTAssertEqual(board.string(forType: .string), "默认直接粘贴")
        XCTAssertTrue(feedback?.contains(L("已复制。无法确认原来的输入窗口，请手动按 ⌘V。")) == true)
        XCTAssertTrue(feedback?.contains("⌘V") == true)
        XCTAssertFalse(defaults.bool(forKey: "directPaste"))
        XCTAssertEqual(try model.store.entries().first?.id, entry.id)
    }
}
