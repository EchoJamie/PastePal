import Foundation
import KeyboardShortcuts

extension Notification.Name {
    static let screenshotSettingsDidChange = Notification.Name("PastePal.screenshotSettingsDidChange")
}

enum ScreenshotShortcutPolicy {
    static let defaultShortcut = KeyboardShortcuts.Shortcut(.a, modifiers: [.command, .shift])
    static let previousDefault = KeyboardShortcuts.Shortcut(.s, modifiers: [.control, .option])

    static func migratedShortcut(_ current: KeyboardShortcuts.Shortcut?) -> KeyboardShortcuts.Shortcut? {
        current == previousDefault ? defaultShortcut : current
    }
    static func migrateIfNeeded(defaults: UserDefaults) {
        guard !defaults.bool(forKey: "screenshotShortcutDefaultV2") else { return }
        let current = KeyboardShortcuts.getShortcut(for: .captureRegion)
        let migrated = migratedShortcut(current)
        if migrated != current { KeyboardShortcuts.setShortcut(migrated, for: .captureRegion) }
        defaults.set(true, forKey: "screenshotShortcutDefaultV2")
    }
    static func apply(enabled: Bool) {
        if enabled { KeyboardShortcuts.enable(.captureRegion) }
        else { KeyboardShortcuts.disable(.captureRegion) }
    }
}
