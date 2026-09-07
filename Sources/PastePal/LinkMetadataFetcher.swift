import Foundation
import ImageIO
import UniformTypeIdentifiers
import ClipboardCore

protocol LinkMetadataLoading: AnyObject {
    func fetch(_ url: URL, completion: @escaping (LinkMetadataPayload) -> Void)
    func cancelAll()
}

final class LinkMetadataFetcher: LinkMetadataLoading {
    typealias Completion = (LinkMetadataPayload) -> Void
    private let queue = DispatchQueue(label: "local.pastepal.link-metadata")
    private let downloader: BoundedLinkDownloader
    private var pending: [URL] = []
    private var completions: [String: [Completion]] = [:]
    private var active = 0
    private var outstandingCallbacks = 0
    private var cancelled = false
    private let maximumConcurrentPages = 2
    private let maximumOutstandingPages: Int

    init(configuration: URLSessionConfiguration = .ephemeral, maximumOutstandingPages: Int = 34) {
        self.maximumOutstandingPages = max(maximumOutstandingPages, 2)
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpAdditionalHeaders = ["User-Agent": "PastePal/0.1 LinkPreview"]
        downloader = BoundedLinkDownloader(configuration: configuration)
    }

    deinit { downloader.cancelAll() }

    func fetch(_ url: URL, completion: @escaping Completion) {
        queue.async {
            guard !self.cancelled else { return }
            let key = url.absoluteString
            guard self.outstandingCallbacks < self.maximumOutstandingPages else {
                completion(LinkMetadataPayload(status: .failed))
                return
            }
            self.outstandingCallbacks += 1
            if self.completions[key] != nil {
                self.completions[key]?.append(completion)
                return
            }
            self.completions[key] = [completion]
            self.pending.append(url)
            self.startPending()
        }
    }

    func cancelAll() {
        queue.async {
            self.cancelled = true
            self.pending.removeAll()
            self.completions.removeAll()
            self.outstandingCallbacks = 0
            self.downloader.cancelAll()
        }
    }

    private func startPending() {
        while !cancelled, active < maximumConcurrentPages, !pending.isEmpty {
            let url = pending.removeFirst()
            active += 1
            fetchPage(url) { payload in
                self.queue.async { self.finish(url, payload: payload) }
            }
        }
    }

    private func finish(_ url: URL, payload: LinkMetadataPayload) {
        guard !cancelled else { return }
        active -= 1
        let callbacks = completions.removeValue(forKey: url.absoluteString) ?? []
        outstandingCallbacks = max(0, outstandingCallbacks - callbacks.count)
        callbacks.forEach { $0(payload) }
        startPending()
    }

    private func fetchPage(_ originalURL: URL, completion: @escaping Completion) {
        guard originalURL.absoluteString.utf8.count <= 4_096 else {
            completion(LinkMetadataPayload(status: .failed)); return
        }
        load(originalURL, maximumBytes: 1_000_000, expectedPrefixes: ["text/", "application/xhtml+xml"], overflowPolicy: .keepPrefix) { page in
            guard let page, let html = Self.decode(page.data, encodingName: page.response.textEncodingName, isTruncated: page.isTruncated) else {
                completion(LinkMetadataPayload(status: .failed)); return
            }
            let baseURL = page.response.url ?? originalURL
            let parsed = Self.parse(html, baseURL: baseURL, isTruncated: page.isTruncated)
            let iconURL = parsed.iconURL ?? Self.faviconURL(for: baseURL)
            self.loadImage(parsed.previewURL, maximumBytes: 2_000_000) { previewData in
                let preview = previewData.flatMap { Self.pngThumbnail($0, maximumPixelSize: 800) }
                if iconURL == parsed.previewURL, let previewData {
                    let icon = Self.pngThumbnail(previewData, maximumPixelSize: 128)
                    completion(LinkMetadataPayload(status: .ready, title: parsed.title, siteName: parsed.siteName, iconPNG: icon, previewPNG: preview))
                    return
                }
                self.loadImage(iconURL, maximumBytes: 750_000) { iconData in
                    let icon = iconData.flatMap { Self.pngThumbnail($0, maximumPixelSize: 128) }
                    completion(LinkMetadataPayload(status: .ready, title: parsed.title, siteName: parsed.siteName, iconPNG: icon, previewPNG: preview))
                }
            }
        }
    }

    private func loadImage(_ url: URL?, maximumBytes: Int, completion: @escaping (Data?) -> Void) {
        guard let url else { completion(nil); return }
        load(url, maximumBytes: maximumBytes, expectedPrefixes: ["image/"]) { completion($0?.data) }
    }

    private func load(_ url: URL, maximumBytes: Int, expectedPrefixes: [String], overflowPolicy: BoundedLinkDownloader.OverflowPolicy = .reject, completion: @escaping (BoundedLinkDownloader.ResponseData?) -> Void) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.absoluteString.utf8.count <= 4_096 else {
            completion(nil); return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.httpShouldHandleCookies = false
        request.setValue("bytes=0-\(maximumBytes - 1)", forHTTPHeaderField: "Range")
        downloader.load(request, maximumBytes: maximumBytes, expectedPrefixes: expectedPrefixes, overflowPolicy: overflowPolicy, completion: completion)
    }

    private struct ParsedPage {
        let title: String?
        let siteName: String?
        let iconURL: URL?
        let previewURL: URL?
    }

    private static func parse(_ html: String, baseURL: URL, isTruncated: Bool) -> ParsedPage {
        var metadata: [String: String] = [:]
        for tag in matches(#"(?is)<meta\b[^>]*>"#, in: html) {
            let attributes = attributes(in: tag)
            guard let key = (attributes["property"] ?? attributes["name"])?.lowercased(), let content = attributes["content"] else { continue }
            if metadata[key] == nil { metadata[key] = clean(content) }
        }
        let closedTitle = firstMatch(#"(?is)<title\b[^>]*>(.*?)</title>"#, group: 1, in: html).map(clean)
        let titleTag = closedTitle ?? (isTruncated ? firstMatch(#"(?is)<title\b[^>]*>([^<]*)$"#, group: 1, in: html).map(clean) : nil)
        let title = limited(metadata["og:title"] ?? metadata["twitter:title"] ?? titleTag, maximum: 300)
        let siteName = limited(metadata["og:site_name"], maximum: 120)
        var iconURL: URL?
        for tag in matches(#"(?is)<link\b[^>]*>"#, in: html) {
            let attributes = attributes(in: tag)
            guard attributes["rel"]?.lowercased().split(whereSeparator: \.isWhitespace).contains(where: { $0.contains("icon") }) == true,
                  let href = attributes["href"], let url = URL(string: href, relativeTo: baseURL)?.absoluteURL else { continue }
            iconURL = url; break
        }
        let previewValue = metadata["og:image"] ?? metadata["twitter:image"] ?? metadata["twitter:image:src"]
        let previewURL = previewValue.flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
        return ParsedPage(title: title, siteName: siteName, iconURL: iconURL, previewURL: previewURL)
    }

    private static func decode(_ data: Data, encodingName: String?, isTruncated: Bool) -> String? {
        let encoding: String.Encoding?
        switch encodingName?.lowercased() {
        case "utf-16", "utf-16le", "utf-16be": encoding = .utf16
        case "iso-8859-1", "latin1": encoding = .isoLatin1
        case "windows-1252": encoding = .windowsCP1252
        case .some(_): encoding = nil
        case nil: encoding = nil
        }
        func decoded(_ encoding: String.Encoding) -> String? {
            if let text = String(data: data, encoding: encoding) { return text }
            // 字节边界可能落在最后一个多字节字符中。
            if isTruncated, !data.isEmpty {
                for count in 1...min(3, data.count) {
                    if let text = String(data: data.dropLast(count), encoding: encoding) { return text }
                }
            }
            return nil
        }
        if let encoding, let text = decoded(encoding) { return text }
        return decoded(.utf8) ?? decoded(.utf16)
    }

    private static func faviconURL(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        components.path = "/favicon.ico"; components.query = nil; components.fragment = nil
        return components.url
    }

    private static func pngThumbnail(_ data: Data, maximumPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 20_000, height <= 20_000,
              Int64(width) * Int64(height) <= 40_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    private static func attributes(in tag: String) -> [String: String] {
        guard let expression = try? NSRegularExpression(pattern: #"(?is)([a-z_:][-a-z0-9_:.]*)\s*=\s*(?:\"([^\"]*)\"|'([^']*)')"#) else { return [:] }
        var result: [String: String] = [:]
        for match in expression.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
            guard let keyRange = Range(match.range(at: 1), in: tag) else { continue }
            let valueRange = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
            guard let range = Range(valueRange, in: tag) else { continue }
            result[String(tag[keyRange]).lowercased()] = clean(String(tag[range]))
        }
        return result
    }

    private static func matches(_ pattern: String, in value: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap { match in
            Range(match.range, in: value).map { String(value[$0]) }
        }
    }

    private static func firstMatch(_ pattern: String, group: Int, in value: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: group), in: value) else { return nil }
        return String(value[range])
    }

    private static func clean(_ value: String) -> String {
        var result = value.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
        if let expression = try? NSRegularExpression(pattern: #"&#(?:x([0-9a-fA-F]+)|([0-9]+));"#, options: .caseInsensitive) {
            for match in expression.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                let hexRange = Range(match.range(at: 1), in: result)
                let decimalRange = Range(match.range(at: 2), in: result)
                let scalar = hexRange.flatMap { UInt32(result[$0], radix: 16) }
                    ?? decimalRange.flatMap { UInt32(result[$0], radix: 10) }
                guard let scalar, let unicode = UnicodeScalar(scalar), let range = Range(match.range, in: result) else { continue }
                result.replaceSubrange(range, with: String(unicode))
            }
        }
        let entities = [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"), ("&amp;", "&")]
        for (entity, replacement) in entities { result = result.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive) }
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func limited(_ value: String?, maximum: Int) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return String(value.prefix(maximum))
    }
}
