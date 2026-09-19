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

    @MainActor func testHistoryKeyboardSelectionDoesNotDeactivateOriginalApplication() async throws {
        guard try await runFocusTestInChildProcess(#function) else { return }
        let (model, panel) = try await makePanel(["第一条", "第二条"])
        let originalApp = try XCTUnwrap(NSWorkspace.shared.frontmostApplication)
        XCTAssertNotEqual(originalApp.processIdentifier, ProcessInfo.processInfo.processIdentifier)
        let originalPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { panel.dismiss(); NSApp.setActivationPolicy(originalPolicy) }

        panel.show()
        try await waitUntil {
            self.drainApplicationEvents()
            return panel.window?.isKeyWindow == true
        }
        XCTAssertTrue(originalApp.isActive, "呼出历史面板不能使原输入应用失活")
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, originalApp.processIdentifier)
        XCTAssertTrue(panel.isCollectionFocused)

        let window = try XCTUnwrap(panel.window)
        window.sendEvent(try keyEvent(124, String(UnicodeScalar(NSRightArrowFunctionKey)!)))
        let secondID = panel.visibleEntryIDs[1]
        XCTAssertEqual(panel.selectedEntryID, secondID)
        let expected = try XCTUnwrap(model.store.content(id: secondID).text)
        // 此用例验证呼出和选取时的真实应用激活状态，不向用户当前应用发送测试内容。
        model.paste.invalidate(); model.onFeedback = nil
        window.sendEvent(try keyEvent(36, "\r"))
        try await waitUntil {
            self.drainApplicationEvents()
            return board.string(forType: .string) == expected && !panel.isVisible
        }
        XCTAssertTrue(originalApp.isActive, "回车取回历史内容后应继续保留原应用")
    }

    @MainActor private func drainApplicationEvents() {
        while let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
    }

    @MainActor private func runFocusTestInChildProcess(_ function: String) async throws -> Bool {
        // 原生焦点测试会处理 AppKit 系统事件，独立运行以免影响其它合成鼠标事件测试。
        let childFlag = "PASTEPAL_FOCUS_TEST_CHILD"
        if ProcessInfo.processInfo.environment[childFlag] == "1" { return true }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest", "-XCTest",
            "PastePalTests.DirectPasteDefaultTests/\(function.replacingOccurrences(of: "()", with: ""))",
            Bundle(for: DirectPasteDefaultTests.self).bundlePath
        ]
        process.environment = ProcessInfo.processInfo.environment.merging([childFlag: "1"]) { _, new in new }
        let status = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
        XCTAssertEqual(status, 0, "独立进程中的原生焦点回归必须通过")
        return false
    }
}
