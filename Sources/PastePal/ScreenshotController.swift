import PastePalLocalization
import AppKit
import ScreenCaptureKit
import KeyboardShortcuts
import ClipboardCore

extension KeyboardShortcuts.Name {
    static let captureRegion = Self("captureRegion", default: ScreenshotShortcutPolicy.defaultShortcut)
}

enum ScreenshotPermission {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }
    @discardableResult static func request() -> Bool { isGranted || CGRequestScreenCaptureAccess() }
    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct ScreenshotFrame {
    let bounds: CGRect
    let image: CGImage
    var scale: CGFloat { CGFloat(image.width) / bounds.width }

    func pixelCrop(for selection: CGRect) -> CGRect {
        let area = bounds.intersection(selection)
        guard !area.isNull else { return .null }
        return CGRect(x: (area.minX - bounds.minX) * scale,
                      y: (bounds.maxY - area.maxY) * CGFloat(image.height) / bounds.height,
                      width: area.width * scale,
                      height: area.height * CGFloat(image.height) / bounds.height)
    }

    static func png(selection: CGRect, frames: [ScreenshotFrame], annotations: [ScreenshotAnnotation] = []) throws -> Data {
        let visible = frames.filter { !$0.bounds.intersection(selection).isEmpty }
        guard selection.width >= 1, selection.height >= 1, let scale = visible.map(\.scale).max() else {
            throw ScreenshotFailure.emptySelection
        }
        let width = Int(ceil(selection.width * scale)), height = Int(ceil(selection.height * scale))
        guard width <= 32_768, height <= 32_768, width * height <= 100_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ScreenshotFailure.tooLarge
        }
        context.interpolationQuality = .none
        for frame in visible {
            let area = selection.intersection(frame.bounds)
            guard let crop = frame.image.cropping(to: frame.pixelCrop(for: selection)) else { continue }
            context.draw(crop, in: CGRect(x: (area.minX - selection.minX) * scale,
                                         y: (area.minY - selection.minY) * scale,
                                         width: area.width * scale, height: area.height * scale))
        }
        guard let source = context.makeImage() else { throw ScreenshotFailure.encoding }
        let obscurer = ScreenshotObscureRenderer(image: source, bounds: selection)
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -selection.minX, y: -selection.minY)
        context.clip(to: selection)
        ScreenshotAnnotationRenderer.draw(annotations: annotations, in: context, obscurer: obscurer)
        context.restoreGState()
        guard let image = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ScreenshotFailure.encoding
        }
        return data
    }
}

enum ScreenshotFailure: LocalizedError {
    case permission, emptySelection, tooLarge, encoding, displaysChanged, windowUnavailable
    var errorDescription: String? {
        switch self {
        case .permission: return L("截屏需要屏幕录制权限。请在设置的隐私与权限中开启；普通剪贴板记录不受影响。")
        case .emptySelection: return L("请拖动选择截屏区域。")
        case .tooLarge: return L("截屏区域过大，请缩小区域后重试。")
        case .encoding: return L("无法生成截屏图片，请重试。")
        case .windowUnavailable: return L("未找到可截取的窗口，请重新选择。")
        case .displaysChanged: return L("显示器配置已变化，请重新截屏。")
        }
    }
}

enum ScreenshotCaptureMode { case region, window }

@MainActor final class ScreenshotController {
    private let pasteboard: NSPasteboard
    private let monitor: ClipboardMonitor
    private let permission: () -> Bool
    private let capture: () async throws -> [ScreenshotFrame]
    private let listWindows: () async throws -> [ScreenshotWindowCandidate]
    private let captureWindow: (CGWindowID) async throws -> ScreenshotFrame
    private var pins: [ScreenshotPinnedImageController] = []
    private var exports: [ScreenshotExportController] = []
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var previousApplication: NSRunningApplication?
    private(set) var selector: ScreenshotSelection?
    private(set) var exportPreview: ScreenshotExportController?
    private var exportOptions = ScreenshotBeautyOptions()
    private(set) var isActive = false
    var onError: ((String) -> Void)?
    var beforeCapture: (() -> Void)?

    init(monitor: ClipboardMonitor, pasteboard: NSPasteboard = .general,
         permission: @escaping () -> Bool = { ScreenshotPermission.isGranted || CGRequestScreenCaptureAccess() },
         capture: @escaping () async throws -> [ScreenshotFrame] = ScreenshotController.captureDisplays,
         listWindows: @escaping () async throws -> [ScreenshotWindowCandidate] = ScreenshotWindowCapture.candidates,
         captureWindow: @escaping (CGWindowID) async throws -> ScreenshotFrame = ScreenshotWindowCapture.capture) {
        self.monitor = monitor; self.pasteboard = pasteboard
        self.permission = permission; self.capture = capture
        self.listWindows = listWindows; self.captureWindow = captureWindow
    }

    func start(mode: ScreenshotCaptureMode = .region) {
        guard !isActive else { return }
        guard permission() else { onError?(ScreenshotFailure.permission.localizedDescription); return }
        previousApplication = NSWorkspace.shared.frontmostApplication
        isActive = true; exportOptions = ScreenshotBeautyOptions()
        let generation = UUID(); self.generation = generation
        beforeCapture?()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                // 让历史面板与状态菜单先完成隐藏。
                try await Task.sleep(for: .milliseconds(120))
                let candidates = mode == .window ? try await listWindows() : []
                if mode == .window && candidates.isEmpty { throw ScreenshotFailure.windowUnavailable }
                let frames = try await capture()
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                guard !frames.isEmpty else { throw ScreenshotFailure.displaysChanged }
                let pick: ((CGWindowID) -> Void)? = mode == .window ? { [weak self] in self?.captureSelectedWindow($0) } : nil
                let selector = ScreenshotSelection(frames: frames, windowCandidates: candidates, onPickWindow: pick) { [weak self] rect in self?.finish(rect) }
                self.selector = selector
                selector.onSave = { [weak self] in self?.previewExport($0) }
                selector.show()
                self.task = nil
            } catch is CancellationError { if self.generation == generation { self.cleanup() } }
            catch { if self.generation == generation { self.cleanup(); self.onError?(error.localizedDescription) } }
        }
    }

    func cancel() { task?.cancel(); cleanup() }

    private func captureSelectedWindow(_ id: CGWindowID) {
        guard isActive else { return }
        let generation = self.generation
        selector?.close(); selector = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let frame = try await captureWindow(id)
                try Task.checkCancellation()
                guard self.generation == generation else { return }
                let selection = ScreenshotSelection(frames: [frame], initialSelection: frame.bounds) { [weak self] in self?.finish($0) }
                selector = selection; task = nil
                selection.onSave = { [weak self] in self?.previewExport($0) }
                selection.show()
            } catch is CancellationError { if self.generation == generation { cleanup() } }
            catch { if self.generation == generation { cleanup(); onError?(error.localizedDescription) } }
        }
    }


    private func previewExport(_ rect: CGRect) {
        guard let selector, exportPreview == nil else { return }
        do {
            let data = try ScreenshotFrame.png(selection: rect, frames: selector.frames, annotations: selector.annotations)
            guard let image = NSBitmapImageRep(data: data)?.cgImage else { throw ScreenshotFailure.encoding }
            let exporter = ScreenshotExportController(image: image, options: exportOptions, returnToEditing: true)
            let currentGeneration = generation
            exporter.onClose = { [weak self, weak exporter] in
                guard let self, let exporter, generation == currentGeneration else { return }
                exportOptions = exporter.options; exportPreview = nil
                if exporter.didSave { cleanup() }
                else if selector.resumeAfterExport() == false { cleanup(); onError?(ScreenshotFailure.displaysChanged.localizedDescription) }
            }
            exportPreview = exporter; selector.suspendForExport(); exporter.showWindow(nil)
        } catch { cleanup(); onError?(error.localizedDescription) }
    }

    private func finish(_ rect: CGRect?) {
        guard let selector else { return }
        guard let rect else { cleanup(); return }
        do {
            let data = try ScreenshotFrame.png(selection: rect, frames: selector.frames, annotations: selector.annotations)
            let action = selector.outputAction
            cleanup()
            try deliverPNG(data, action: action, originalFrame: rect)
        } catch { cleanup(); onError?(error.localizedDescription) }
    }

    func deliverPNG(_ data: Data, action: ScreenshotOutputAction, originalFrame: CGRect? = nil) throws {
        if action == .clipboard { try writePNG(data); return }
        guard let image = NSBitmapImageRep(data: data)?.cgImage else { throw ScreenshotFailure.encoding }
        if action == .pin {
            let pin = ScreenshotPinnedImageController(image: image, originalFrame: originalFrame)
            pin.onClose = { [weak self, weak pin] in self?.pins.removeAll { $0 === pin } }
            pins.append(pin); pin.showWindow(nil); pin.window?.orderFrontRegardless()
        } else {
            let exporter = ScreenshotExportController(image: image)
            exporter.onClose = { [weak self, weak exporter] in self?.exports.removeAll { $0 === exporter } }
            exports.append(exporter); exporter.showWindow(nil)
        }
    }

    func writePNG(_ data: Data) throws {
        let count = try PasteboardIO.write([Representation(type: NSPasteboard.PasteboardType.png.rawValue, data: data)], to: pasteboard)
        monitor.noteScreenshotWrite(count: count)
        monitor.poll()
    }

    private func cleanup() {
        generation = UUID()
        if let exportPreview { self.exportPreview = nil; exportPreview.onClose = nil; exportPreview.close() }
        selector?.close(); selector = nil; task = nil; isActive = false
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
           let previousApplication, previousApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication.activate(options: [])
        }
        previousApplication = nil
    }

    private static func captureDisplays() async throws -> [ScreenshotFrame] {
        let screens = NSScreen.screens.map { ($0.frame, ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value, $0.backingScaleFactor) }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var frames: [ScreenshotFrame] = []
        for (bounds, id, scale) in screens {
            try Task.checkCancellation()
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw ScreenshotFailure.displaysChanged }
            let configuration = SCStreamConfiguration()
            configuration.width = Int((bounds.width * scale).rounded())
            configuration.height = Int((bounds.height * scale).rounded())
            configuration.showsCursor = false
            configuration.capturesAudio = false
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            frames.append(ScreenshotFrame(bounds: bounds, image: image))
        }
        guard screens.map({ $0.0 }) == NSScreen.screens.map(\.frame) else { throw ScreenshotFailure.displaysChanged }
        return frames
    }
}
