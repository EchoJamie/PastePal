import PastePalLocalization
import XCTest
import AppKit
import KeyboardShortcuts
@testable import PastePal

final class AppCommandMenuTests: XCTestCase {
    @MainActor func testCaptureMenuExposesBothCommandsAndStartsDisabledUntilConfigured() throws {
        let app = NSApplication.shared
        let previous = app.mainMenu
        defer { app.mainMenu = previous }
        let delegate = AppDelegate()
        delegate.installMainMenu()
        let menu = try XCTUnwrap(app.mainMenu?.items.first { $0.title == L("截屏") }?.submenu)
        XCTAssertFalse(menu.autoenablesItems)
        XCTAssertEqual(menu.items.map(\.title), [L("区域截屏"), L("截取窗口")])
        XCTAssertEqual(menu.items.map { $0.action.map(NSStringFromSelector) }, ["captureRegion", "captureWindow"])
        XCTAssertTrue(menu.items.allSatisfy { $0.target === delegate && !$0.isEnabled })
    }

    @MainActor func testMainMenuContainsFixedSettingsAndQuitCommandsWithSubstituteActions() throws {
        let app = NSApplication.shared
        let previous = app.mainMenu
        defer { app.mainMenu = previous }
        let delegate = AppDelegate()
        delegate.installMainMenu()
        let main = try XCTUnwrap(app.mainMenu)
        let menu = try XCTUnwrap(main.items.first?.submenu)
        let settings = try XCTUnwrap(menu.items.first { $0.keyEquivalent == "," })
        let quit = try XCTUnwrap(menu.items.first { $0.keyEquivalent == "q" })
        XCTAssertEqual(settings.keyEquivalentModifierMask, .command)
        XCTAssertEqual(quit.keyEquivalentModifierMask, .command)
        XCTAssertTrue(settings.target === delegate)
        XCTAssertTrue(quit.target === app)
        let counter = AppCommandCounter()
        settings.target = counter; settings.action = #selector(AppCommandCounter.settings)
        quit.target = counter; quit.action = #selector(AppCommandCounter.quit)
        XCTAssertTrue(main.performKeyEquivalent(with: try event(",", code: 43)))
        XCTAssertTrue(main.performKeyEquivalent(with: try event("q", code: 12)))
        XCTAssertEqual(counter.settingsCalls, 1)
        XCTAssertEqual(counter.quitCalls, 1)
    }
    @MainActor func testStatusMenuUsesCurrentFunctionBindingsInsteadOfOldDefaults() throws {
        let suite = "AppCommandMenuTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppShortcutStore(defaults: defaults, globalShortcuts: { [] })
        XCTAssertNil(store.setShortcut(.init(.r, modifiers: [.command, .option]), for: .addToGroup))
        XCTAssertNil(store.setShortcut(.init(.t, modifiers: [.command, .option]), for: .usePlainText))
        let menu = NSMenu(); menu.autoenablesItems = false
        let group = menu.addItem(withTitle: "加入", action: NSSelectorFromString("addSelectedToGroup"), keyEquivalent: "g")
        let plain = menu.addItem(withTitle: "纯文本", action: NSSelectorFromString("useSelectedAsPlainText"), keyEquivalent: "\r")
        plain.keyEquivalentModifierMask = .option
        AppDelegate().refreshStatusShortcuts(in: menu, store: store)
        XCTAssertEqual(group.keyEquivalent, "r")
        XCTAssertEqual(plain.keyEquivalent, "t")
        XCTAssertEqual(group.keyEquivalentModifierMask, [.command, .option])
        XCTAssertEqual(plain.keyEquivalentModifierMask, [.command, .option])
        let counter = AppCommandCounter()
        group.target = counter; group.action = #selector(AppCommandCounter.settings)
        XCTAssertFalse(menu.performKeyEquivalent(with: try event("g", code: 5)))
        let current = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
            windowNumber: 0, context: nil, characters: "r", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15))
        XCTAssertTrue(menu.performKeyEquivalent(with: current))
        XCTAssertEqual(counter.settingsCalls, 1)
    }
    private func event(_ text: String, code: UInt16) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
    }
}

private final class AppCommandCounter: NSObject {
    var settingsCalls = 0
    var quitCalls = 0
    @objc func settings() { settingsCalls += 1 }
    @objc func quit() { quitCalls += 1 }
}
