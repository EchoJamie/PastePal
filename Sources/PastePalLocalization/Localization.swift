import Foundation

public enum AppLanguage: String, CaseIterable, Sendable {
    case system, simplifiedChinese = "zh-Hans", traditionalChinese = "zh-Hant", english = "en"
    public var title: String {
        switch self {
        case .system: return L("跟随系统")
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .english: return "English"
        }
    }
    public static func resolve(_ selection: AppLanguage, preferredLanguages: [String]) -> AppLanguage {
        guard selection == .system else { return selection }
        for identifier in preferredLanguages {
            let code = identifier.lowercased().replacingOccurrences(of: "_", with: "-")
            if code == "zh" || code.hasPrefix("zh-") {
                if code.contains("hans") { return .simplifiedChinese }
                return code.contains("hant") || code.hasSuffix("-tw") || code.hasSuffix("-hk") || code.hasSuffix("-mo")
                    ? .traditionalChinese : .simplifiedChinese
            }
            if code == "en" || code.hasPrefix("en-") { return .english }
        }
        return .english
    }
}

public struct LocalizedText: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    let key: String
    let values: [String]
    public init(stringLiteral value: String) { key = value; values = [] }
    public init(stringInterpolation value: StringInterpolation) { key = value.key; values = value.values }
    public struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var values: [String] = []
        public init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity); values.reserveCapacity(interpolationCount)
        }
        public mutating func appendLiteral(_ literal: String) { key += literal }
        public mutating func appendInterpolation<T>(_ value: T) {
            key += "{\(values.count)}"; values.append(String(describing: value))
        }
    }
}

public enum AppLocalization {
    public static let language: AppLanguage = {
        let defaults = UserDefaults.standard
        let selected = AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? "") ?? .system
        let system = defaults.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
        return AppLanguage.resolve(selected, preferredLanguages: system ?? Locale.preferredLanguages)
    }()
    private static let catalogs: [AppLanguage: [String: String]] = {
        let bundle = Bundle.main.resourceURL.flatMap {
            Bundle(url: $0.appendingPathComponent("PastePal_PastePalLocalization.bundle"))
        } ?? Bundle.module
        var result: [AppLanguage: [String: String]] = [:]
        for language in [AppLanguage.english, .traditionalChinese] {
            guard let url = bundle.url(forResource: language.rawValue, withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let strings = try? JSONDecoder().decode([String: String].self, from: data) else { continue }
            result[language] = strings
        }
        return result
    }()
    public static func catalog(for language: AppLanguage) -> [String: String] { catalogs[language] ?? [:] }
    private static let placeholderPattern = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)
    public static func render(_ text: LocalizedText, language: AppLanguage = language) -> String {
        let template = catalogs[language]?[text.key] ?? text.key
        let source = template as NSString
        var result = "", offset = 0
        for match in placeholderPattern.matches(in: template, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: offset, length: match.range.location - offset))
            let index = Int(source.substring(with: match.range(at: 1)))!
            result += text.values.indices.contains(index) ? text.values[index] : source.substring(with: match.range)
            offset = NSMaxRange(match.range)
        }
        return result + source.substring(from: offset)
    }
}

public func L(_ text: LocalizedText) -> String { AppLocalization.render(text) }
