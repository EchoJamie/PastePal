import XCTest
import AppKit
import KeyboardShortcuts
@testable import PastePal

final class GroupShortcutTests: XCTestCase {
    func testFixedTabBindingsPreserveButDoNotUseLegacyCustomData() throws {
        let suite = "GroupShortcutTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = try JSONEncoder().encode(["previous": KeyboardShortcuts.Shortcut(.tab, modifiers: [.control, .shift]), "next": .init(.n, modifiers: [.control, .option])])
        defaults.set(legacy, forKey: "groupNavigationShortcutsV1")
        let store = GroupShortcutStore(defaults: defaults, globalShortcut: { nil }, screenshotShortcut: { nil })
        XCTAssertEqual(store.shortcut(for: .previous), .init(.tab, modifiers: .shift))
        XCTAssertEqual(store.shortcut(for: .next), .init(.tab))
        XCTAssertNotNil(store.setShortcut(.init(.n, modifiers: [.control, .option]), for: .next))
        XCTAssertEqual(defaults.data(forKey: "groupNavigationShortcutsV1"), legacy)
        XCTAssertEqual(store.direction(for: try event(48, modifiers: [])), .next)
        XCTAssertEqual(store.direction(for: try event(48, modifiers: [.shift, .capsLock])), .previous)
        XCTAssertNil(store.direction(for: try event(45, modifiers: [.control, .option])))
    }
    private func event(_ code: UInt16, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }
}
