import PastePalLocalization
import AppKit
import ScreenCaptureKit

struct ScreenshotWindowCandidate {
    let id: CGWindowID
    let title: String
    let bounds: CGRect
}

@MainActor enum ScreenshotWindowCapture {
    static func appKitBounds(_ rect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }
    static func candidates() async throws -> [ScreenshotWindowCandidate] {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let windows = Dictionary(uniqueKeysWithValues: content.windows.filter {
            $0.windowLayer == 0 && $0.frame.width > 1 && $0.frame.height > 1 &&
            $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
        }.map { ($0.windowID, $0) })
        let ordered = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return ordered.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? UInt32, let window = windows[id] else { return nil }
            let app = window.owningApplication?.applicationName ?? L("窗口")
            let title = window.title.flatMap { $0.isEmpty ? nil : $0 } ?? app
            return ScreenshotWindowCandidate(id: id, title: title, bounds: appKitBounds(window.frame, primaryTop: top))
        }
    }
    static func capture(id: CGWindowID) async throws -> ScreenshotFrame {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == id }) else { throw ScreenshotFailure.windowUnavailable }
        let bounds = appKitBounds(window.frame, primaryTop: NSScreen.screens.first?.frame.maxY ?? 0)
        let scale = NSScreen.screens.filter { !$0.frame.intersection(bounds).isEmpty }.map(\.backingScaleFactor).max() ?? 1
        let config = SCStreamConfiguration()
        config.width = Int(ceil(bounds.width * scale)); config.height = Int(ceil(bounds.height * scale))
        guard config.width > 0, config.height > 0, config.width * config.height <= 100_000_000 else { throw ScreenshotFailure.tooLarge }
        config.showsCursor = false; config.capturesAudio = false; config.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
        return ScreenshotFrame(bounds: bounds, image: image)
    }
}
