import XCTest
import AppKit
import KeyboardShortcuts
@testable import PastePal

final class AppShortcutStoreTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    override func setUp() {
        super.setUp()
        suite = "AppShortcutStoreTests.\(UUID())"; defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite); defaults = nil
        super.tearDown()
    }
    func testAllDefaultsMatchOnlyTheirActualContextsAndEnterAlias() throws {
        let store = AppShortcutStore(defaults: defaults, globalShortcuts: { [] })
        for action in AppShortcutAction.allCases {
            let key = action.defaultShortcut
            XCTAssertEqual(store.action(for: try event(key), context: .cards), action)
            XCTAssertEqual(store.action(for: try event(key), context: .search), action == .beginSearch ? action : nil)
            XCTAssertNil(store.action(for: try event(key), context: .cards, hasMarkedText: true))
        }
        XCTAssertEqual(store.action(for: try event(.init(carbonKeyCode: 76, carbonModifiers: AppShortcutAction.usePlainText.defaultShortcut.carbonModifiers)), context: .cards), .usePlainText)
    }
    func testRebindingPersistsAndOldKeyStopsMatching() throws {
        let writer = AppShortcutStore(defaults: defaults, globalShortcuts: { [] })
        let reader = AppShortcutStore(defaults: defaults, globalShortcuts: { [] })
        let changed = KeyboardShortcuts.Shortcut(.r, modifiers: [.command, .option])
        XCTAssertNil(writer.setShortcut(changed, for: .addToGroup))
        XCTAssertEqual(reader.shortcut(for: .addToGroup), changed)
        XCTAssertEqual(reader.action(for: try event(changed), context: .cards), .addToGroup)
        XCTAssertNil(reader.action(for: try event(AppShortcutAction.addToGroup.defaultShortcut), context: .cards))
        XCTAssertNil(writer.restoreDefault(for: .addToGroup))
        XCTAssertEqual(reader.shortcut(for: .addToGroup), AppShortcutAction.addToGroup.defaultShortcut)
    }
    func testFixedKeysAndSystemCommandsRejectWithoutWriting() {
        let store = AppShortcutStore(defaults: defaults, globalShortcuts: { [] })
        let invalid: [KeyboardShortcuts.Shortcut] = [.init(.space), .init(.return), .init(.leftArrow), .init(.tab), .init(.tab, modifiers: .control), .init(.escape, modifiers: .command), .init(.q, modifiers: .command), .init(.comma, modifiers: .command), .init(.a, modifiers: .command), .init(.c, modifiers: .command), .init(.x, modifiers: .command), .init(.v, modifiers: .command), .init(.z, modifiers: .command)]
        for shortcut in invalid { XCTAssertNotNil(store.setShortcut(shortcut, for: .beginSearch)) }
        XCTAssertNil(defaults.data(forKey: "applicationFunctionShortcutsV1"))
    }
    func testLocalAndGlobalConflictsIncludeKeypadEnterAlias() {
        let global = KeyboardShortcuts.Shortcut(.k, modifiers: [.command, .option])
        let store = AppShortcutStore(defaults: defaults, globalShortcuts: { [global] })
        XCTAssertNotNil(store.setShortcut(global, for: .beginSearch))
        XCTAssertNotNil(store.setShortcut(.init(.g, modifiers: .command), for: .beginSearch))
        XCTAssertNotNil(store.setShortcut(.init(carbonKeyCode: 76, carbonModifiers: AppShortcutAction.usePlainText.defaultShortcut.carbonModifiers), for: .beginSearch))
        XCTAssertNotNil(store.globalShortcutConflict(.init(.g, modifiers: .command)))
        XCTAssertNil(store.globalShortcutConflict(nil))
    }
    func testScreenshotDefaultMigrationPreservesCustomAndDisabledBindings() {
        XCTAssertEqual(ScreenshotShortcutPolicy.migratedShortcut(ScreenshotShortcutPolicy.previousDefault), .init(.a, modifiers: [.command, .shift]))
        let custom = KeyboardShortcuts.Shortcut(.k, modifiers: [.control, .option])
        XCTAssertEqual(ScreenshotShortcutPolicy.migratedShortcut(custom), custom)
        XCTAssertNil(ScreenshotShortcutPolicy.migratedShortcut(nil))
        XCTAssertFalse(SettingsStore(defaults: defaults).screenshotEnabled)
    }
    private func event(_ shortcut: KeyboardShortcuts.Shortcut) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shortcut.modifiers,
            timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(shortcut.carbonKeyCode)))
    }
}
