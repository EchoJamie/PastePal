import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
import ClipboardCore
@testable import PastePal

class AppTestSupport: XCTestCase {
    var directory: URL!
    var defaults: UserDefaults!
    var suite: String!
    var board: NSPasteboard!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PastePalAppTests-\(UUID().uuidString)")
        suite = "PastePalAppTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        board = NSPasteboard.withUniqueName()
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite); board.releaseGlobally()
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    @MainActor final func keyEvent(_ keyCode: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    @MainActor final func descendants(of view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    final func pngData() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 20, bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.55, blue: 0.9, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 32, height: 20))
        let data = NSMutableData(); let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    final func values(_ text: String) -> [Representation] { [Representation(type: "public.utf8-plain-text", data: Data(text.utf8))] }

    @MainActor final func makePanel(_ texts: [String]) async throws -> (AppModel, PanelController) {
        _ = NSApplication.shared
        let model = try AppModel(directory: directory, settings: SettingsStore(defaults: defaults), pasteboard: board, paste: PasteCoordinator(permission: { true }))
        for text in texts { _ = try model.store.record(ContentCodec.decode(values(text)), limit: 20) }
        model.refresh()
        try await waitUntil { model.entries.count == texts.count }
        let panel = PanelController(model: model)
        panel.prepareForDisplay()
        return (model, panel)
    }
}

@MainActor func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
    for _ in 0..<100 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    _ = try XCTUnwrap(condition() ? true : nil, "等待异步操作超时", file: file, line: line)
}
