import XCTest
import AppKit
import PastePalLocalization
@testable import PastePal

final class PresentationPreferencesTests: AppTestSupport {
    func testPreferencesPersistAndSystemLanguageRemovesOnlyApplicationOverride() {
        let globalLanguages = defaults.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.appearanceMode, .system)
        XCTAssertEqual(settings.language, .system)
        settings.appearanceMode = .dark
        settings.language = .traditionalChinese
        let reopened = SettingsStore(defaults: defaults)
        XCTAssertEqual(reopened.appearanceMode, .dark)
        XCTAssertEqual(reopened.language, .traditionalChinese)
        XCTAssertEqual(defaults.persistentDomain(forName: suite)?["AppleLanguages"] as? [String], ["zh-Hant"])
        reopened.language = .system
        XCTAssertNil(defaults.persistentDomain(forName: suite)?["AppleLanguages"])
        XCTAssertEqual(defaults.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String], globalLanguages)
        defaults.set("invalid", forKey: "appearanceMode")
        defaults.set("invalid", forKey: "appLanguage")
        XCTAssertEqual(reopened.appearanceMode, .system)
        XCTAssertEqual(reopened.language, .system)
    }

    func testLanguageResolutionRespectsPreferenceOrderAndExplicitChoice() {
        for code in ["zh", "zh-CN", "zh-Hans", "zh-Hans-TW", "zh_SG"] {
            XCTAssertEqual(AppLanguage.resolve(.system, preferredLanguages: [code, "en"]), .simplifiedChinese, code)
        }
        for code in ["zh-Hant", "zh-Hant-CN", "zh-TW", "zh_HK", "zh-MO"] {
            XCTAssertEqual(AppLanguage.resolve(.system, preferredLanguages: [code, "en"]), .traditionalChinese, code)
        }
        XCTAssertEqual(AppLanguage.resolve(.system, preferredLanguages: ["fr-FR", "en-CN", "zh-Hans"]), .english)
        XCTAssertEqual(AppLanguage.resolve(.system, preferredLanguages: ["ja", "zh-Hant", "en"]), .traditionalChinese)
        XCTAssertEqual(AppLanguage.resolve(.system, preferredLanguages: ["fr"]), .english)
        XCTAssertEqual(AppLanguage.resolve(.system, preferredLanguages: []), .english)
        XCTAssertEqual(AppLanguage.resolve(.english, preferredLanguages: ["zh-Hans"]), .english)
    }

    func testTranslationResourcesAndInterpolationPreserveUserContent() throws {
        XCTAssertEqual(AppLocalization.render("跟随系统", language: .english), "Follow System")
        XCTAssertEqual(AppLocalization.render("浅色", language: .traditionalChinese), "淺色")
        let english = AppLocalization.catalog(for: .english)
        let traditional = AppLocalization.catalog(for: .traditionalChinese)
        XCTAssertFalse(english.isEmpty)
        XCTAssertEqual(Set(english.keys), Set(traditional.keys))
        let pattern = try NSRegularExpression(pattern: #"\{\d+\}"#)
        func tokens(_ value: String) -> [String] {
            pattern.matches(in: value, range: NSRange(value.startIndex..., in: value))
                .map { (value as NSString).substring(with: $0.range) }.sorted()
        }
        for catalog in [english, traditional] {
            for (key, value) in catalog {
                XCTAssertFalse(value.isEmpty, key)
                XCTAssertEqual(tokens(key), tokens(value), key)
            }
        }
        let name = "用户内容 {1} 🌏"
        let text: LocalizedText = "\(name) · 设置"
        XCTAssertEqual(AppLocalization.render(text, language: .english), "\(name) · Settings")
        XCTAssertEqual(AppLocalization.render(text, language: .traditionalChinese), "\(name) · 設置")
    }

    @MainActor func testGeneralPickersApplyAppearanceImmediatelyAndPersistLanguage() throws {
        _ = NSApplication.shared
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        let model = try AppModel(directory: directory, settings: SettingsStore(defaults: defaults), pasteboard: board)
        let controller = SettingsController(model: model, screenPermissionCheck: { false }, screenPermissionRequest: { false })
        defer { controller.close() }
        let window = try XCTUnwrap(controller.window)
        let controls = descendants(of: window.contentView).compactMap { $0 as? NSPopUpButton }
        let appearance = try XCTUnwrap(controls.first { $0.accessibilityLabel() == L("外观模式") })
        let language = try XCTUnwrap(controls.first { $0.accessibilityLabel() == L("应用语言") })
        XCTAssertEqual(appearance.itemTitles, AppAppearanceMode.allCases.map(\.title))
        XCTAssertEqual(language.itemTitles, AppLanguage.allCases.map(\.title))
        XCTAssertEqual(appearance.indexOfSelectedItem, 0)
        XCTAssertEqual(language.indexOfSelectedItem, 0)
        for (index, mode) in AppAppearanceMode.allCases.enumerated().reversed() {
            appearance.selectItem(at: index)
            XCTAssertTrue(appearance.sendAction(appearance.action!, to: appearance.target))
            XCTAssertEqual(model.settings.appearanceMode, mode)
            XCTAssertEqual(NSApp.appearance?.name, mode.appearance?.name)
            XCTAssertNil(window.appearance)
            XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]))
            let toolbar = ScreenshotAnnotationToolbar()
            window.contentView?.addSubview(toolbar)
            XCTAssertNil(toolbar.appearance)
            XCTAssertEqual(toolbar.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]))
            toolbar.removeFromSuperview()
        }
        language.selectItem(at: 3)
        XCTAssertTrue(language.sendAction(language.action!, to: language.target))
        XCTAssertEqual(SettingsStore(defaults: defaults).language, .english)
        XCTAssertTrue(descendants(of: window.contentView).compactMap { $0 as? NSTextField }.contains { $0.stringValue == L("重新打开应用后，语言设置生效。") && !$0.isHidden })
    }
}
