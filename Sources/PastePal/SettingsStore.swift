import AppKit
import PastePalLocalization
import ClipboardCore
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let showHistory = Self("showHistory", default: .init(.v, modifiers: [.command, .shift]))
}

final class SettingsStore {
    private let retentionLock = NSRecursiveLock()
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["historyRetentionDays": 30, "paused": false, "screenshotEnabled": false, "excludedApps": [String]()])
    }
    var appearanceMode: AppAppearanceMode {
        get { AppAppearanceMode(rawValue: defaults.string(forKey: "appearanceMode") ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "appearanceMode") }
    }
    var language: AppLanguage {
        get { AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? "") ?? .system }
        set {
            defaults.set(newValue.rawValue, forKey: "appLanguage")
            if newValue == .system { defaults.removeObject(forKey: "AppleLanguages") }
            else { defaults.set([newValue.rawValue], forKey: "AppleLanguages") }
        }
    }
    var limit: Int { get { max(1, (defaults.object(forKey: "historyLimit") as? Int) ?? 10000) } set { defaults.set(newValue, forKey: "historyLimit") } }
    var retentionMode: HistoryRetentionMode {
        if let mode = defaults.string(forKey: "historyRetentionMode") {
            return HistoryRetentionMode(rawValue: mode) ?? .count
        }
        // 旧版只保存条数，无法区分默认值与用户选择，保留原策略。
        return defaults.object(forKey: "historyLimit") == nil ? .time : .count
    }
    var retentionDays: Int { max(1, defaults.integer(forKey: "historyRetentionDays")) }
    var retentionPolicy: HistoryRetentionPolicy {
        retentionLock.withLock { HistoryRetentionPolicy(mode: retentionMode, count: limit, days: retentionDays) }
    }
    func saveRetentionPolicy(_ policy: HistoryRetentionPolicy) throws {
        try policy.validate()
        retentionLock.withLock {
            limit = policy.count
            defaults.set(policy.days, forKey: "historyRetentionDays")
            defaults.set(policy.mode.rawValue, forKey: "historyRetentionMode")
        }
    }
    var screenshotEnabled: Bool {
        get { defaults.bool(forKey: "screenshotEnabled") }
        set {
            defaults.set(newValue, forKey: "screenshotEnabled")
            NotificationCenter.default.post(name: .screenshotSettingsDidChange, object: nil)
        }
    }
    var paused: Bool { get { defaults.bool(forKey: "paused") } set { defaults.set(newValue, forKey: "paused") } }
    var excludedApps: [String] { get { defaults.stringArray(forKey: "excludedApps") ?? [] } set { defaults.set(newValue.sorted(), forKey: "excludedApps") } }
    var welcomed: Bool { get { defaults.bool(forKey: "welcomed") } set { defaults.set(newValue, forKey: "welcomed") } }
}

enum AppAppearanceMode: String, CaseIterable {
    case system, light, dark
    var title: String {
        switch self {
        case .system: return L("跟随系统")
        case .light: return L("浅色")
        case .dark: return L("深色")
        }
    }
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
    func apply() { NSApp.appearance = appearance }
}
