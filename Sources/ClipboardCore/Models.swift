import PastePalLocalization
import Foundation
import CryptoKit

public enum ContentKind: String, Codable, Sendable { case text, image, file, color }
public enum HistoryFilter: Int, Sendable { case all, text, image }

public struct ClipGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var position: Int
    public init(id: String, name: String, position: Int) {
        self.id = id; self.name = name; self.position = position
    }
}

public struct HistoryOverview: Sendable {
    public let entries: [HistoryEntry]
    public let groups: [ClipGroup]
    public let count: Int
}

public struct HistorySnapshot: Sendable {
    public let entries: [HistoryEntry]
    public let groups: [ClipGroup]
    public let groupEntryIDs: [String: Set<String>]
    public init(entries: [HistoryEntry], groups: [ClipGroup], groupEntryIDs: [String: Set<String>]) {
        self.entries = entries; self.groups = groups; self.groupEntryIDs = groupEntryIDs
    }
}

public struct Representation: Codable, Equatable, Sendable {
    public let type: String
    public let data: Data
    public let itemIndex: Int
    public init(type: String, data: Data, itemIndex: Int = 0) {
        self.type = type; self.data = data; self.itemIndex = itemIndex
    }
    private enum CodingKeys: String, CodingKey { case type, data, itemIndex }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(String.self, forKey: .type)
        data = try values.decode(Data.self, forKey: .data)
        itemIndex = try values.decodeIfPresent(Int.self, forKey: .itemIndex) ?? 0
    }
}

public struct ClipboardContent: Sendable {
    public let kind: ContentKind
    public let text: String?
    public let representations: [Representation]
    public let width: Int?
    public let height: Int?
    public let thumbnail: Data?
    public let frameCount: Int?
    public init(kind: ContentKind, text: String?, representations: [Representation], width: Int? = nil, height: Int? = nil, thumbnail: Data? = nil, frameCount: Int? = nil) {
        self.kind = kind; self.text = text; self.representations = representations
        self.width = width; self.height = height; self.thumbnail = thumbnail; self.frameCount = frameCount
    }
    public var fingerprint: String { Self.digest(representations) }
    public static func digest(_ representations: [Representation]) -> String {
        var hash = SHA256()
        let values = representations.sorted {
            $0.itemIndex == $1.itemIndex ? $0.type < $1.type : $0.itemIndex < $1.itemIndex
        }
        let hasMultipleItems = values.contains { $0.itemIndex != 0 }
        for value in values {
            if hasMultipleItems {
                var itemIndex = UInt64(bitPattern: Int64(value.itemIndex)).bigEndian
                withUnsafeBytes(of: &itemIndex) { hash.update(data: Data($0)) }
            }
            for data in [Data(value.type.utf8), value.data] {
                var length = UInt64(data.count).bigEndian
                withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
                hash.update(data: data)
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public func output(plainText: Bool) throws -> [Representation] {
        if plainText {
            guard supportsPlainText, let text else { throw ClipboardError.noPlainText }
            return [Representation(type: "public.utf8-plain-text", data: Data(text.utf8))]
        }
        if kind == .file {
            let itemCount = Set(representations.map(\.itemIndex)).count
            guard !fileURLs.isEmpty, fileURLs.count == itemCount else { throw ClipboardError.invalidContent }
            let missing = fileURLs.filter { !FileManager.default.fileExists(atPath: $0.path) }
            if !missing.isEmpty { throw ClipboardError.missingFiles(missing.map(\.lastPathComponent)) }
        }
        return representations
    }
    public var supportsPlainText: Bool { kind == .text || kind == .color }
    public var fileURLs: [URL] { Self.fileURLs(in: representations) }
    static func fileURLs(in representations: [Representation]) -> [URL] {
        representations
            .filter { $0.type == "public.file-url" }
            .sorted { $0.itemIndex < $1.itemIndex }
            .compactMap { String(data: $0.data, encoding: .utf8) }
            .compactMap(URL.init(string:))
            .filter(\.isFileURL)
    }
}

public enum SourceAttribution: String, Codable, Sendable {
    case declared
    case foreground
}

public struct SourceApplication: Codable, Equatable, Sendable {
    public let bundleID: String
    public let name: String
    public let iconFile: String?
    public let attribution: SourceAttribution
    public init(bundleID: String, name: String, iconFile: String? = nil, attribution: SourceAttribution = .declared) {
        self.bundleID = bundleID; self.name = name; self.iconFile = iconFile; self.attribution = attribution
    }
    private enum CodingKeys: String, CodingKey { case bundleID, name, iconFile, attribution }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try values.decode(String.self, forKey: .bundleID)
        name = try values.decode(String.self, forKey: .name)
        iconFile = try values.decodeIfPresent(String.self, forKey: .iconFile)
        attribution = try values.decodeIfPresent(SourceAttribution.self, forKey: .attribution) ?? .declared
    }
}

public enum LinkMetadataStatus: String, Codable, Sendable { case ready, failed }

public struct LinkMetadata: Codable, Equatable, Sendable {
    public let status: LinkMetadataStatus
    public let title: String?
    public let siteName: String?
    public let iconFile: String?
    public let previewFile: String?
    public let fetchedAt: Date
    public var files: [String] { [iconFile, previewFile].compactMap { $0 } }
}

public struct LinkMetadataPayload: Equatable, Sendable {
    public let status: LinkMetadataStatus
    public let title: String?
    public let siteName: String?
    public let iconPNG: Data?
    public let previewPNG: Data?
    public init(status: LinkMetadataStatus, title: String? = nil, siteName: String? = nil, iconPNG: Data? = nil, previewPNG: Data? = nil) {
        self.status = status; self.title = title; self.siteName = siteName
        self.iconPNG = iconPNG; self.previewPNG = previewPNG
    }
}

public struct StoredRepresentation: Codable, Sendable {
    public let type: String
    public let inline: Data?
    public let file: String?
    public let itemIndex: Int
    public init(type: String, inline: Data?, file: String?, itemIndex: Int = 0) {
        self.type = type; self.inline = inline; self.file = file; self.itemIndex = itemIndex
    }
    private enum CodingKeys: String, CodingKey { case type, inline, file, itemIndex }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(String.self, forKey: .type)
        inline = try values.decodeIfPresent(Data.self, forKey: .inline)
        file = try values.decodeIfPresent(String.self, forKey: .file)
        itemIndex = try values.decodeIfPresent(Int.self, forKey: .itemIndex) ?? 0
    }
}

public struct HistoryEntry: Codable, Identifiable, Sendable {
    public let id: String
    public let fingerprint: String
    public let kind: ContentKind
    public let text: String?
    public var source: SourceApplication?
    public let createdAt: Date
    public var copiedAt: Date
    public var usedAt: Date?
    public var activity: Int64
    public let representations: [StoredRepresentation]
    public let thumbnailFile: String?
    public let width: Int?
    public let height: Int?
    public let frameCount: Int?
    public var linkMetadata: LinkMetadata?
    public var textLength: Int?
    public var activityDate: Date { max(copiedAt, usedAt ?? .distantPast) }
    public var files: [String] {
        representations.compactMap(\.file)
            + [thumbnailFile, source?.iconFile].compactMap { $0 }
            + (linkMetadata?.files ?? [])
    }
    public var supportsPlainText: Bool { kind == .text || kind == .color }
    public var itemCount: Int { (representations.map(\.itemIndex).max() ?? -1) + 1 }
    public var fileURLs: [URL] {
        representations
            .filter { $0.type == "public.file-url" }
            .sorted { $0.itemIndex < $1.itemIndex }
            .compactMap(\.inline)
            .compactMap { String(data: $0, encoding: .utf8) }
            .compactMap(URL.init(string:))
            .filter(\.isFileURL)
    }
    public var hasMissingFiles: Bool {
        kind == .file && fileURLs.contains { !FileManager.default.fileExists(atPath: $0.path) }
    }
    public var linkURL: URL? {
        guard kind == .text, let text else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: \.isWhitespace), let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }
    public func matches(query: String, filter: HistoryFilter) -> Bool {
        let isText = kind == .text || kind == .color
        guard filter == .all || (filter == .text && isText) || (filter == .image && kind == .image) else { return false }
        guard !query.isEmpty else { return true }
        return [text, source?.name, source?.bundleID, linkMetadata?.title, linkMetadata?.siteName]
            .compactMap { $0 }
            .contains { $0.range(of: query, options: [.caseInsensitive, .literal]) != nil }
    }
    var searchText: String {
        [text, source?.name, source?.bundleID, linkMetadata?.title, linkMetadata?.siteName]
            .compactMap { $0 }
            .joined(separator: "\n")
            .lowercased()
    }
    func summary(maximumTextCharacters: Int = 1_600) -> HistoryEntry {
        let textLimit = linkURL == nil ? maximumTextCharacters : max(maximumTextCharacters, 4_096)
        let visibleText = text.map { String($0.prefix(textLimit)) }
        let lightweightRepresentations = representations.map { value in
            StoredRepresentation(
                type: value.type,
                inline: kind == .file && value.type == "public.file-url" ? value.inline : nil,
                file: value.file,
                itemIndex: value.itemIndex
            )
        }
        return HistoryEntry(
            id: id,
            fingerprint: fingerprint,
            kind: kind,
            text: visibleText,
            source: source,
            createdAt: createdAt,
            copiedAt: copiedAt,
            usedAt: usedAt,
            activity: activity,
            representations: lightweightRepresentations,
            thumbnailFile: thumbnailFile,
            width: width,
            height: height,
            frameCount: frameCount,
            linkMetadata: linkMetadata,
            textLength: text?.count
        )
    }
}

public enum ClipboardError: LocalizedError, Equatable {
    case database(String), missingEntry, missingGroup, invalidGroupName, duplicateGroupName, noPlainText, invalidLimit, invalidContent, missingImage, missingFiles([String]), pasteboardWrite, changedDuringRead
    public var errorDescription: String? {
        switch self {
        case .database(let reason): return L("历史数据库操作失败：\(reason)")
        case .missingEntry: return L("这条记录已被删除或淘汰，请重新选择。")
        case .missingGroup: return L("这个分组已被删除，请重新选择。")
        case .invalidGroupName: return L("分组名称应为 1–40 个字符。")
        case .duplicateGroupName: return L("已经有同名分组，请换一个名称。")
        case .noPlainText: return L("这条记录没有可用的纯文本。")
        case .invalidLimit: return L("保留条数必须是正整数。")
        case .invalidContent: return L("内容格式不受支持或无法完整读取。")
        case .missingImage: return L("原始图片文件缺失或损坏，未更改当前剪贴板。")
        case .missingFiles(let names): return L("文件已移动或删除，未更改当前剪贴板：\(names.joined(separator: "、"))")
        case .pasteboardWrite: return L("系统剪贴板写入失败，历史顺序未更新；当前剪贴板可能已改变。")
        case .changedDuringRead: return L("读取期间剪贴板发生变化，等待下一次检查。")
        }
    }
}

public struct RecordingGate {
    public private(set) var lastCount: Int
    private var ownWrite: (count: Int, digest: String)?
    public init(initialCount: Int) { lastCount = initialCount }
    public func hasChange(_ count: Int) -> Bool { count != lastCount }
    public mutating func resetBaseline(_ count: Int) { lastCount = count; ownWrite = nil }
    public mutating func noteOwnWrite(count: Int, representations: [Representation]) {
        ownWrite = (count, ClipboardContent.digest(representations))
    }
    public mutating func consume(count: Int, representations: [Representation], paused: Bool, excluded: Bool) -> Bool {
        guard count != lastCount else { return false }
        lastCount = count
        defer { ownWrite = nil }
        if paused || excluded { return false }
        if let ownWrite, ownWrite.count == count, ownWrite.digest == ClipboardContent.digest(representations) { return false }
        return true
    }
}
