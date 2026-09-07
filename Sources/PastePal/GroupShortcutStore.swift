import PastePalLocalization
import AppKit
import KeyboardShortcuts

enum GroupShortcutDirection: String, Codable, CaseIterable {
    case previous, next
}

final class GroupShortcutStore {
    private let screenshotShortcut: () -> KeyboardShortcuts.Shortcut?
    private let globalShortcut: () -> KeyboardShortcuts.Shortcut?

    init(defaults: UserDefaults = .standard,
         globalShortcut: @escaping () -> KeyboardShortcuts.Shortcut? = { KeyboardShortcuts.getShortcut(for: .showHistory) },
         screenshotShortcut: @escaping () -> KeyboardShortcuts.Shortcut? = { KeyboardShortcuts.getShortcut(for: .captureRegion) }) {
        self.globalShortcut = globalShortcut
        self.screenshotShortcut = screenshotShortcut
    }

    func shortcut(for direction: GroupShortcutDirection) -> KeyboardShortcuts.Shortcut {
        // 历史自定义数据保留；Tab / ⇧Tab 现在是固定的分组导航键。
        return .init(.tab, modifiers: direction == .previous ? [.shift] : [])
    }

    func validationError(for shortcut: KeyboardShortcuts.Shortcut, direction: GroupShortcutDirection) -> String? {
        guard shortcut == self.shortcut(for: direction) else { return L("Tab / ⇧Tab 分组切换为固定按键，不能修改。") }
        guard shortcut != globalShortcut(), shortcut != screenshotShortcut() else { return L("固定分组按键与全局快捷键冲突。") }
        return nil
    }

    @discardableResult
    func setShortcut(_ shortcut: KeyboardShortcuts.Shortcut, for direction: GroupShortcutDirection) -> String? {
        L("Tab / ⇧Tab 分组切换为固定按键，不能修改。")
    }

    func globalShortcutConflict(_ shortcut: KeyboardShortcuts.Shortcut?) -> String? {
        guard let shortcut else { return nil }
        return GroupShortcutDirection.allCases.contains { self.shortcut(for: $0) == shortcut }
            ? L("此快捷键已用于面板内切换分组，请使用不同组合。") : nil
    }

    func direction(for event: NSEvent) -> GroupShortcutDirection? {
        guard let shortcut = KeyboardShortcuts.Shortcut(event: event) else { return nil }
        return GroupShortcutDirection.allCases.first {
            self.shortcut(for: $0) == shortcut && validationError(for: shortcut, direction: $0) == nil
        }
    }
}
