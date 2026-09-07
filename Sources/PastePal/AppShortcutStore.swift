import PastePalLocalization
import AppKit
import KeyboardShortcuts

enum AppShortcutContext { case cards, search }

enum AppShortcutAction: String, CaseIterable {
    case beginSearch, addToGroup, usePlainText
    case usePosition1, usePosition2, usePosition3, usePosition4, usePosition5
    case usePosition6, usePosition7, usePosition8, usePosition9

    var position: Int? {
        guard rawValue.hasPrefix("usePosition") else { return nil }
        return Int(rawValue.dropFirst("usePosition".count)).map { $0 - 1 }
    }
    var title: String {
        switch self {
        case .beginSearch: return L("搜索")
        case .addToGroup: return L("加入分组")
        case .usePlainText: return L("纯文本使用")
        default: return L("使用第 \(position! + 1) 条")
        }
    }
    var defaultShortcut: KeyboardShortcuts.Shortcut {
        switch self {
        case .beginSearch: return .init(.f, modifiers: .command)
        case .addToGroup: return .init(.g, modifiers: .command)
        case .usePlainText: return .init(.return, modifiers: .option)
        default:
            let keys: [KeyboardShortcuts.Key] = [.one, .two, .three, .four, .five, .six, .seven, .eight, .nine]
            return .init(keys[position!], modifiers: .command)
        }
    }
    func applies(to context: AppShortcutContext) -> Bool { context == .cards || self == .beginSearch }
}

extension Notification.Name {
    static let appShortcutsDidChange = Notification.Name("PastePal.appShortcutsDidChange")
}

final class AppShortcutStore {
    private let defaults: UserDefaults
    private let globalShortcuts: () -> [KeyboardShortcuts.Shortcut]
    private let key = "applicationFunctionShortcutsV1"

    init(defaults: UserDefaults = .standard,
         globalShortcuts: @escaping () -> [KeyboardShortcuts.Shortcut] = {
             [.showHistory, .captureRegion].compactMap { KeyboardShortcuts.getShortcut(for: $0) }
         }) {
        self.defaults = defaults; self.globalShortcuts = globalShortcuts
    }
    func shortcut(for action: AppShortcutAction) -> KeyboardShortcuts.Shortcut {
        saved()[action.rawValue] ?? action.defaultShortcut
    }
    @MainActor func display(for action: AppShortcutAction) -> String { shortcut(for: action).description }
    func validationError(for shortcut: KeyboardShortcuts.Shortcut, action: AppShortcutAction) -> String? {
        let modifiers = shortcut.modifiers.intersection([.command, .control, .option, .shift])
        guard !modifiers.intersection([.command, .control, .option]).isEmpty else {
            return L("功能快捷键需要包含 ⌘、⌃ 或 ⌥；单键操作保持固定。")
        }
        guard shortcut.carbonKeyCode != 48, shortcut.carbonKeyCode != 53 else {
            return L("Tab 分组切换和 Esc 退出保持固定，请使用其他组合。")
        }
        if modifiers.contains(.command), [0, 6, 7, 8, 9, 12, 43, 4, 46].contains(shortcut.carbonKeyCode) {
            return L("此组合保留给文本编辑、设置、退出或系统窗口操作。")
        }
        if [49, 48].contains(shortcut.carbonKeyCode), modifiers.contains(.command) || modifiers.contains(.control) {
            return L("此组合用于系统切换或输入法，请使用其他组合。")
        }
        if action == .beginSearch, [36, 76, 49, 51, 117, 115, 119, 123, 124, 125, 126].contains(shortcut.carbonKeyCode) {
            return L("搜索框中此组合用于文字或光标操作，请使用字母或数字组合。")
        }
        guard !globalShortcuts().contains(where: { equivalent($0, shortcut) }) else {
            return L("不能与全局呼出或区域截屏快捷键相同。")
        }
        if let conflict = AppShortcutAction.allCases.first(where: { $0 != action && equivalent(self.shortcut(for: $0), shortcut) }) {
            return L("此组合已用于“\(conflict.title)”，请先修改该项。")
        }
        return nil
    }
    @discardableResult func setShortcut(_ shortcut: KeyboardShortcuts.Shortcut, for action: AppShortcutAction) -> String? {
        if let error = validationError(for: shortcut, action: action) { return error }
        var values = saved(); values[action.rawValue] = shortcut
        guard let data = try? JSONEncoder().encode(values) else { return L("快捷键保存失败。") }
        defaults.set(data, forKey: key)
        NotificationCenter.default.post(name: .appShortcutsDidChange, object: nil)
        return nil
    }
    @discardableResult func restoreDefault(for action: AppShortcutAction) -> String? {
        setShortcut(action.defaultShortcut, for: action)
    }
    func globalShortcutConflict(_ shortcut: KeyboardShortcuts.Shortcut?) -> String? {
        guard let shortcut else { return nil }
        if let action = AppShortcutAction.allCases.first(where: { equivalent(self.shortcut(for: $0), shortcut) }) {
            return L("此组合已用于“\(action.title)”，请使用其他组合。")
        }
        return nil
    }
    func action(for event: NSEvent, context: AppShortcutContext, hasMarkedText: Bool = false) -> AppShortcutAction? {
        guard event.type == .keyDown, !hasMarkedText, let shortcut = KeyboardShortcuts.Shortcut(event: event) else { return nil }
        return AppShortcutAction.allCases.first {
            $0.applies(to: context) && equivalent(self.shortcut(for: $0), shortcut)
                && validationError(for: self.shortcut(for: $0), action: $0) == nil
        }
    }
    private func saved() -> [String: KeyboardShortcuts.Shortcut] {
        guard let data = defaults.data(forKey: key),
              let values = try? JSONDecoder().decode([String: KeyboardShortcuts.Shortcut].self, from: data) else { return [:] }
        return values
    }
    private func equivalent(_ lhs: KeyboardShortcuts.Shortcut, _ rhs: KeyboardShortcuts.Shortcut) -> Bool {
        let left = lhs.carbonKeyCode == 76 ? 36 : lhs.carbonKeyCode
        let right = rhs.carbonKeyCode == 76 ? 36 : rhs.carbonKeyCode
        let flags: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        return left == right && lhs.modifiers.intersection(flags) == rhs.modifiers.intersection(flags)
    }
}
