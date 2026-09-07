import PastePalLocalization
import AppKit
import ClipboardCore

struct ClipboardApplicationDescriptor: Equatable {
    let bundleID: String
    let name: String
}

protocol ClipboardSourceResolving: AnyObject {
    var currentBundleID: String? { get }
    func start()
    func stop()
    func source(declaredBundleID: String?, changeCount: Int) -> SourceApplication?
    func didConsume(changeCount: Int)
}

final class ClipboardSourceResolver: ClipboardSourceResolving {
    private struct Activation {
        let previous: ClipboardApplicationDescriptor?
        let changeCount: Int
    }

    private let pasteboard: NSPasteboard
    private let ownBundleID: String
    private let notificationCenter: NotificationCenter?
    private let currentApplicationProvider: () -> ClipboardApplicationDescriptor?
    private let applicationLookup: (String) -> ClipboardApplicationDescriptor?
    private let maximumActivations: Int
    private var currentApplication: ClipboardApplicationDescriptor?
    private var activations: [Activation] = []
    private var activationOverflow = false
    private var observer: NSObjectProtocol?
    private(set) var isObserving = false

    var currentBundleID: String? { currentApplication?.bundleID }

    init(
        pasteboard: NSPasteboard,
        ownBundleID: String = AppIdentity.bundleID,
        initialApplication: ClipboardApplicationDescriptor? = ClipboardSourceResolver.frontmostApplication(),
        notificationCenter: NotificationCenter? = NSWorkspace.shared.notificationCenter,
        currentApplicationProvider: @escaping () -> ClipboardApplicationDescriptor? = ClipboardSourceResolver.frontmostApplication,
        applicationLookup: @escaping (String) -> ClipboardApplicationDescriptor? = ClipboardSourceResolver.installedApplication,
        maximumActivations: Int = 16
    ) {
        self.pasteboard = pasteboard
        self.ownBundleID = ownBundleID
        self.currentApplication = initialApplication
        self.notificationCenter = notificationCenter
        self.currentApplicationProvider = currentApplicationProvider
        self.applicationLookup = applicationLookup
        self.maximumActivations = maximumActivations
    }

    func start() {
        guard observer == nil else { return }
        if let application = currentApplicationProvider() {
            noteActivation(application, observedChangeCount: pasteboard.changeCount)
        }
        guard let notificationCenter else { return }
        observer = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.noteActivation(Self.descriptor(application), observedChangeCount: self.pasteboard.changeCount)
        }
        isObserving = true
    }

    func stop() {
        if let observer, let notificationCenter { notificationCenter.removeObserver(observer) }
        observer = nil
        isObserving = false
    }

    func noteActivation(_ application: ClipboardApplicationDescriptor?, observedChangeCount: Int) {
        let application = application.flatMap { valid($0) ? $0 : nil }
        guard application?.bundleID != currentApplication?.bundleID else {
            currentApplication = application
            return
        }
        guard !activationOverflow else { currentApplication = application; return }
        guard activations.count < maximumActivations else {
            activations.removeAll(keepingCapacity: true)
            activationOverflow = true
            currentApplication = application
            return
        }
        activations.append(Activation(previous: currentApplication, changeCount: observedChangeCount))
        currentApplication = application
    }

    func source(declaredBundleID: String?, changeCount: Int) -> SourceApplication? {
        guard declaredBundleID != ownBundleID else { return nil }
        if let declaredBundleID,
           let declared = applicationLookup(declaredBundleID),
           valid(declared), declared.bundleID != ownBundleID {
            return SourceApplication(bundleID: declared.bundleID, name: declared.name, attribution: .declared)
        }
        guard !activationOverflow else { return nil }
        let candidate: ClipboardApplicationDescriptor?
        if let activation = activations.first(where: { $0.changeCount == changeCount }) {
            candidate = activation.previous
        } else {
            candidate = currentApplication
        }
        guard let candidate, valid(candidate), candidate.bundleID != ownBundleID else { return nil }
        return SourceApplication(bundleID: candidate.bundleID, name: candidate.name, attribution: .foreground)
    }

    func didConsume(changeCount: Int) {
        activations.removeAll(keepingCapacity: true)
        activationOverflow = false
    }

    deinit { stop() }

    private func valid(_ application: ClipboardApplicationDescriptor) -> Bool {
        !application.bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !application.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func descriptor(_ application: NSRunningApplication) -> ClipboardApplicationDescriptor? {
        guard let bundleID = application.bundleIdentifier, let name = application.localizedName else { return nil }
        return ClipboardApplicationDescriptor(bundleID: bundleID, name: name)
    }

    private static func frontmostApplication() -> ClipboardApplicationDescriptor? {
        NSWorkspace.shared.frontmostApplication.flatMap(descriptor)
    }

    private static func installedApplication(_ bundleID: String) -> ClipboardApplicationDescriptor? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let displayName = FileManager.default.displayName(atPath: url.path)
        let name = displayName.hasSuffix(".app") ? String(displayName.dropLast(4)) : displayName
        return ClipboardApplicationDescriptor(bundleID: bundleID, name: name)
    }
}

final class ClipboardMonitor {
    private let pasteboard: NSPasteboard
    private let settings: SettingsStore
    private let sourceResolver: ClipboardSourceResolving
    private var screenshotWriteCount: Int?
    private var gate: RecordingGate
    private var timer: Timer?
    var onCapture: (([Representation], SourceApplication?) -> Void)?
    var onStatus: ((String?) -> Void)?

    init(settings: SettingsStore, pasteboard: NSPasteboard = .general, sourceResolver: ClipboardSourceResolving? = nil) {
        self.settings = settings
        self.pasteboard = pasteboard
        self.sourceResolver = sourceResolver ?? ClipboardSourceResolver(pasteboard: pasteboard)
        gate = RecordingGate(initialCount: pasteboard.changeCount)
    }

    func start() {
        guard timer == nil else { return }
        sourceResolver.start()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = 0.03
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        sourceResolver.stop()
    }

    deinit { stop() }

    func resetBaseline() {
        let count = pasteboard.changeCount
        gate.resetBaseline(count)
        sourceResolver.didConsume(changeCount: count)
    }

    func noteOwnWrite(count: Int, representations: [Representation]) {
        gate.noteOwnWrite(count: count, representations: representations)
        sourceResolver.didConsume(changeCount: count)
    }

    func noteScreenshotWrite(count: Int) { screenshotWriteCount = count }

    func poll() {
        let count = pasteboard.changeCount
        let isScreenshot = screenshotWriteCount == count
        defer { screenshotWriteCount = nil }
        guard gate.hasChange(count) else {
            sourceResolver.didConsume(changeCount: count)
            return
        }
        if settings.paused {
            consumeSkipped(count: count)
            return
        }
        do {
            let values = try PasteboardIO.snapshot(pasteboard)
            let declaredBundleID = pasteboard.string(forType: .init("org.nspasteboard.source"))
            let source = isScreenshot
                ? SourceApplication(bundleID: AppIdentity.bundleID, name: AppIdentity.displayName, attribution: .declared)
                : sourceResolver.source(declaredBundleID: declaredBundleID, changeCount: count)
            guard count == pasteboard.changeCount else { return }
            let excluded = source.map { settings.excludedApps.contains($0.bundleID) }
                ?? sourceResolver.currentBundleID.map(settings.excludedApps.contains)
                ?? false
            let accepted = gate.consume(count: count, representations: values, paused: false, excluded: excluded)
            sourceResolver.didConsume(changeCount: count)
            guard accepted else { return }
            if !values.isEmpty { onCapture?(values, source) }
            onStatus?(nil)
        } catch ClipboardError.changedDuringRead { return }
        catch ClipboardError.invalidContent {
            consumeSkipped(count: count)
            if pasteboard.types == nil { onStatus?(L("暂时无法读取剪贴板；如系统提示，请允许访问。")) }
        } catch { onStatus?(L("剪贴板读取异常：\(error.localizedDescription)")) }
    }

    private func consumeSkipped(count: Int) {
        _ = gate.consume(count: count, representations: [], paused: settings.paused, excluded: true)
        sourceResolver.didConsume(changeCount: count)
    }
}
