import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

public enum ContentCodec {
    public static let textTypes = ["public.utf8-plain-text", "public.rtf", "com.apple.flat-rtfd", "public.html", "public.url"]
    public static let imageTypes = ["public.png", "public.tiff", "public.jpeg", "com.compuserve.gif"]
    public static let fileTypes = ["public.file-url"]
    public static let supportedTypes = textTypes + imageTypes + fileTypes

    public static func decode(_ representations: [Representation]) throws -> ClipboardContent {
        let values = representations.filter { supportedTypes.contains($0.type) }.sorted {
            $0.itemIndex == $1.itemIndex ? $0.type < $1.type : $0.itemIndex < $1.itemIndex
        }
        guard !values.isEmpty else { throw ClipboardError.invalidContent }
        let grouped = Dictionary(grouping: values, by: \.itemIndex)
        let indices = grouped.keys.sorted()
        guard indices == Array(0..<indices.count) else { throw ClipboardError.invalidContent }

        if grouped.values.allSatisfy({ values in values.contains { fileTypes.contains($0.type) } }) {
            let urls = ClipboardContent.fileURLs(in: values)
            guard urls.count == grouped.count else { throw ClipboardError.invalidContent }
            let names = urls.map { $0.lastPathComponent.isEmpty ? $0.path : $0.lastPathComponent }
            return ClipboardContent(kind: .file, text: names.joined(separator: "\n"), representations: values)
        }
        guard !values.contains(where: { fileTypes.contains($0.type) }) else { throw ClipboardError.invalidContent }

        let images = values.filter { imageTypes.contains($0.type) }
        if !images.isEmpty {
            guard values.count == images.count else { throw ClipboardError.invalidContent }
            var firstWidth: Int?, firstHeight: Int?, firstFrames: Int?, firstSource: CGImageSource?
            for image in images {
                guard let source = CGImageSourceCreateWithData(image.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetCount(source) > 0,
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { throw ClipboardError.invalidContent }
                if firstSource == nil {
                    firstSource = source; firstWidth = width; firstHeight = height; firstFrames = CGImageSourceGetCount(source)
                }
            }
            guard let source = firstSource,
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 600, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw ClipboardError.invalidContent }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw ClipboardError.invalidContent }
            CGImageDestinationAddImage(destination, thumbnail, nil)
            guard CGImageDestinationFinalize(destination) else { throw ClipboardError.invalidContent }
            return ClipboardContent(kind: .image, text: nil, representations: images, width: firstWidth, height: firstHeight, thumbnail: data as Data, frameCount: firstFrames)
        }
        let texts = try indices.map { index -> String in
            guard let text = extractText(from: grouped[index] ?? []), !text.isEmpty else { throw ClipboardError.invalidContent }
            return text
        }
        let text = texts.joined(separator: "\n")
        return ClipboardContent(kind: color(from: text) == nil ? .text : .color, text: text, representations: values)
    }

    private static func extractText(from values: [Representation]) -> String? {
        if let plain = values.first(where: { $0.type == "public.utf8-plain-text" }), let text = String(data: plain.data, encoding: .utf8) { return text }
        if let url = values.first(where: { $0.type == "public.url" }), let text = String(data: url.data, encoding: .utf8) { return text }
        if let rtf = values.first(where: { $0.type == "public.rtf" }) {
            return richText(rtf.data, type: .rtf)
        }
        if let rtfd = values.first(where: { $0.type == "com.apple.flat-rtfd" }) {
            return richText(rtfd.data, type: .rtfd)
        }
        if let html = values.first(where: { $0.type == "public.html" }) {
            return htmlText(html.data)
        }
        return nil
    }

    private static func richText(_ data: Data, type: NSAttributedString.DocumentType) -> String? {
        guard let text = try? NSAttributedString(data: data, options: [.documentType: type], documentAttributes: nil).string else { return nil }
        return hasSearchableText(text) ? text : nil
    }

    private static func hasSearchableText(_ text: String) -> Bool {
        let ignored = CharacterSet.whitespacesAndNewlines.union(.controlCharacters).union(CharacterSet(charactersIn: "\u{fffc}"))
        return text.rangeOfCharacter(from: ignored.inverted) != nil
    }

    private static func htmlText(_ data: Data) -> String? {
        guard var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { return nil }
        text = replacing(#"(?is)<!--.*?-->|<(script|style)\b[^>]*>.*?</\1>"#, in: text, with: "")
        text = replacing(#"(?i)<\s*(br|/p|/div|/li|/tr|/h[1-6])\b[^>]*>"#, in: text, with: "\n")
        text = replacing(#"(?s)<[^>]*>"#, in: text, with: "")
        text = decodeHTMLEntities(text)
        text = replacing(#"[\t ]+"#, in: text, with: " ")
        text = replacing(#"\n(?:\s*\n)+"#, in: text, with: "\n")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return hasSearchableText(text) ? text : nil
    }

    private static func replacing(_ pattern: String, in value: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        return expression.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: replacement)
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        let mutable = NSMutableString(string: value)
        if let expression = try? NSRegularExpression(pattern: #"&#(?:[xX][0-9a-fA-F]+|[0-9]+);"#) {
            for match in expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
                let entity = mutable.substring(with: match.range)
                let digits = entity.dropFirst(2).dropLast()
                let number = entity.lowercased().hasPrefix("&#x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
                if let number, let scalar = UnicodeScalar(number) { mutable.replaceCharacters(in: match.range, with: String(scalar)) }
            }
        }
        let named = [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"), ("&hellip;", "…"), ("&ndash;", "–"), ("&mdash;", "—"), ("&amp;", "&")]
        for (entity, replacement) in named { mutable.replaceOccurrences(of: entity, with: replacement, range: NSRange(location: 0, length: mutable.length)) }
        return mutable as String
    }

    public static func color(from text: String) -> ClipboardColor? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            let digits = String(value.dropFirst())
            guard [3, 4, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return nil }
            let pairs: [String]
            if digits.count <= 4 { pairs = digits.map { "\($0)\($0)" } }
            else { pairs = stride(from: 0, to: digits.count, by: 2).map { String(digits.dropFirst($0).prefix(2)) } }
            guard pairs.count == 3 || pairs.count == 4,
                  let red = UInt8(pairs[0], radix: 16), let green = UInt8(pairs[1], radix: 16), let blue = UInt8(pairs[2], radix: 16) else { return nil }
            let alpha = pairs.count == 4 ? UInt8(pairs[3], radix: 16)! : 255
            return ClipboardColor(red: red, green: green, blue: blue, alpha: alpha)
        }
        let pattern = #"(?i)^rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})(?:\s*,\s*((?:0(?:\.\d+)?|1(?:\.0+)?)))?\s*\)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.range.location != NSNotFound,
              let red = component(match, 1, in: value), let green = component(match, 2, in: value), let blue = component(match, 3, in: value),
              red <= 255, green <= 255, blue <= 255 else { return nil }
        let isRGBA = value.lowercased().hasPrefix("rgba")
        let alphaRange = match.range(at: 4)
        guard isRGBA == (alphaRange.location != NSNotFound) else { return nil }
        let alpha: UInt8
        if isRGBA, let range = Range(alphaRange, in: value), let number = Double(value[range]) {
            alpha = UInt8((number * 255).rounded())
        } else { alpha = 255 }
        return ClipboardColor(red: UInt8(red), green: UInt8(green), blue: UInt8(blue), alpha: alpha)
    }

    private static func component(_ match: NSTextCheckingResult, _ index: Int, in value: String) -> Int? {
        guard let range = Range(match.range(at: index), in: value) else { return nil }
        return Int(value[range])
    }
}

public struct ClipboardColor: Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let alpha: UInt8
}

public enum PasteboardIO {
    public static func snapshot(_ pasteboard: NSPasteboard) throws -> [Representation] {
        let count = pasteboard.changeCount
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { throw ClipboardError.invalidContent }
        let prohibited = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]
        var representations: [Representation] = []
        for (itemIndex, item) in items.enumerated() {
            guard !item.types.contains(where: { prohibited.contains($0.rawValue) }) else { throw ClipboardError.invalidContent }
            let itemValues = try ContentCodec.supportedTypes.compactMap { type -> Representation? in
                let key = NSPasteboard.PasteboardType(type)
                guard item.types.contains(key) else { return nil }
                guard let data = item.data(forType: key) else { throw ClipboardError.invalidContent }
                return Representation(type: type, data: data, itemIndex: itemIndex)
            }
            guard !itemValues.isEmpty else { throw ClipboardError.invalidContent }
            representations.append(contentsOf: itemValues)
        }
        guard count == pasteboard.changeCount else { throw ClipboardError.changedDuringRead }
        return representations
    }
    @discardableResult
    public static func write(_ representations: [Representation], to pasteboard: NSPasteboard) throws -> Int {
        guard !representations.isEmpty else { throw ClipboardError.invalidContent }
        let grouped = Dictionary(grouping: representations, by: \.itemIndex)
        let indices = grouped.keys.sorted()
        guard indices == Array(0..<indices.count) else { throw ClipboardError.invalidContent }
        let items = try indices.map { index -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for value in grouped[index]!.sorted(by: { $0.type < $1.type }) {
                guard item.setData(value.data, forType: NSPasteboard.PasteboardType(value.type)) else { throw ClipboardError.pasteboardWrite }
            }
            return item
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(items) else { throw ClipboardError.pasteboardWrite }
        return pasteboard.changeCount
    }
}
