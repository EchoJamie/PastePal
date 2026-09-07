import PastePalLocalization
import AppKit
import ClipboardCore

final class AppModel {
    let store: HistoryStore
    let settings: SettingsStore
    let monitor: ClipboardMonitor
    let paste: PasteCoordinator
    private let pasteboard: NSPasteboard
    private let linkMetadataLoader: LinkMetadataLoading
    private let sourceIconProvider: (SourceApplication) -> Data?
    private let captureInbox: CaptureInbox
    private let captureDrainLock = NSLock()
    private var captureDrainScheduled = false
    private let publicationLock = NSLock()
    private var pendingPublication: (HistoryOverview, String?)?
    private var publicationScheduled = false
    private let worker = DispatchQueue(label: "local.pastepal.operations", qos: .userInitiated)
    private let retentionClock: () -> Date
    private let retentionInterval: TimeInterval
    private var retentionTimer: DispatchSourceTimer?
    private let retentionUpdateLock = NSLock()
    private var retentionRevision = 0
    private var pendingLinkEntries: Set<String> = []
    private var acceptsMetadata = true
    private let maximumPendingLinkEntries = 34
    private let sourceIconCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 128; cache.totalCostLimit = 8 * 1_024 * 1_024
        return cache
    }()
    private var missingSourceIcons: Set<String> = []
    private(set) var entries: [HistoryEntry] = []
    private(set) var groups: [ClipGroup] = []
    private(set) var entryCount = 0
    private(set) var status: String?
    private(set) var busy = false
    var onChange: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onFeedback: ((String) -> Void)?
    var onAccessibilityRequired: (() -> Void)?

    init(directory: URL, settings: SettingsStore, pasteboard: NSPasteboard = .general, linkMetadataLoader: LinkMetadataLoading = LinkMetadataFetcher(), sourceResolver: ClipboardSourceResolving? = nil, sourceIconProvider: @escaping (SourceApplication) -> Data? = AppModel.applicationIconPNG, fault: ((HistoryStore.Checkpoint) throws -> Void)? = nil, retentionClock: @escaping () -> Date = Date.init, retentionInterval: TimeInterval = 15 * 60, paste: PasteCoordinator = PasteCoordinator()) throws {
        self.retentionClock = retentionClock; self.retentionInterval = max(0.01, retentionInterval)
        self.settings = settings; self.pasteboard = pasteboard; self.paste = paste
        self.linkMetadataLoader = linkMetadataLoader; self.sourceIconProvider = sourceIconProvider
        store = try HistoryStore(directory: directory, fault: fault)
        captureInbox = try CaptureInbox(directory: directory)
        monitor = ClipboardMonitor(settings: settings, pasteboard: pasteboard, sourceResolver: sourceResolver)
        monitor.onCapture = { [weak self] values, source in self?.capture(values, source: source) }
        monitor.onStatus = { [weak self] message in
            if let message { self?.status = message; self?.onChange?() }
        }
    }
    deinit { retentionTimer?.cancel(); monitor.stop() }
    func start() {
        guard retentionTimer == nil else { return }
        scheduleCaptureDrain()
        runRetentionMaintenance()
        let timer = DispatchSource.makeTimerSource(queue: worker)
        timer.schedule(deadline: .now() + retentionInterval, repeating: retentionInterval,
                       leeway: .milliseconds(Int(min(60, retentionInterval / 10) * 1000)))
        timer.setEventHandler { [weak self] in
            guard let self, self.acceptsMetadata, self.settings.retentionMode == .time else { return }
            self.performRetentionMaintenance()
        }
        retentionTimer = timer; timer.resume()
        monitor.start()
    }
    func runRetentionMaintenance() {
        worker.async { [weak self] in self?.performRetentionMaintenance() }
    }
    private func performRetentionMaintenance() {
        do {
            try store.applyRetention(settings.retentionPolicy, now: retentionClock())
            publish()
        } catch { report(error.localizedDescription) }
    }
    func prepareToQuit(_ completion: @escaping () -> Void) {
        busy = true; onChange?(); monitor.stop()
        retentionTimer?.cancel(); retentionTimer = nil
        worker.async {
            self.acceptsMetadata = false; self.pendingLinkEntries.removeAll(); self.linkMetadataLoader.cancelAll()
            _ = self.drainCaptures(maximum: Int.max)
            DispatchQueue.main.async(execute: completion)
        }
    }
    func refresh() {
        worker.async { [weak self] in
            guard let self else { return }
            do { try self.publishSnapshot() }
            catch { self.report(error.localizedDescription) }
        }
    }
    private func capture(_ values: [Representation], source: SourceApplication?) {
        do {
            try captureInbox.append(values, source: source, icon: source.flatMap(cachedSourceIcon), capturedAt: retentionClock())
            scheduleCaptureDrain()
        } catch { report(L("无法暂存本次复制，内容仍在系统剪贴板中。请释放空间后重新复制。\(error.localizedDescription)")) }
    }
    private func scheduleCaptureDrain() {
        let upperBound = captureDrainLock.withLock { () -> UInt64? in
            guard !captureDrainScheduled, captureInbox.hasPending else { return nil }
            captureDrainScheduled = true
            return captureInbox.pendingUpperBound
        }
        if let upperBound { worker.async { [weak self] in self?.processCaptureBatch(through: upperBound) } }
    }
    private func processCaptureBatch(through upperBound: UInt64) {
        let succeeded = drainCaptures(maximum: 8, through: upperBound)
        captureDrainLock.withLock { captureDrainScheduled = false }
        if succeeded { scheduleCaptureDrain() }
    }
    private func drainCaptures(maximum: Int, through upperBound: UInt64 = UInt64.max) -> Bool {
        var changed = false
        do {
            for _ in 0..<maximum {
                let processed = try autoreleasepool { () -> Bool in
                    guard let capture = try captureInbox.peek(before: upperBound) else { return false }
                    do {
                        let content = try ContentCodec.decode(capture.values)
                        let entry = try store.record(content, source: capture.source, sourceIcon: capture.icon,
                                                     policy: settings.retentionPolicy, now: capture.capturedAt, retentionNow: retentionClock())
                        changed = true
                        fetchLinkMetadata(for: entry)
                    } catch ClipboardError.invalidContent { }
                    try captureInbox.acknowledge(capture.sequence)
                    return true
                }
                if !processed { break }
            }
            if changed { publish() }
            return true
        } catch {
            if changed { publish() }
            report(L("复制内容已暂存，保存历史失败；后续复制或重新启动时会重试。\(error.localizedDescription)"))
            return false
        }
    }
    private func fetchLinkMetadata(for entry: HistoryEntry) {
        guard acceptsMetadata, entry.linkMetadata == nil, let url = entry.linkURL, (try? store.contains(id: entry.id)) == true else { return }
        if (try? store.reuseLinkMetadata(id: entry.id, expectedFingerprint: entry.fingerprint, url: url)) == true {
            publish(); return
        }
        guard pendingLinkEntries.count < maximumPendingLinkEntries,
              pendingLinkEntries.insert(entry.id).inserted else { return }
        let id = entry.id, fingerprint = entry.fingerprint
        linkMetadataLoader.fetch(url) { [weak self] payload in
            guard let self else { return }
            self.worker.async {
                self.pendingLinkEntries.remove(id)
                guard self.acceptsMetadata else { return }
                if (try? self.store.updateLinkMetadata(id: id, expectedFingerprint: fingerprint, payload: payload)) == true {
                    self.publish()
                }
            }
        }
    }
    func use(id: String, plainText: Bool = false, copyOnly: Bool = false) {
        guard !busy else { return }
        guard copyOnly || paste.trusted else {
            if let onAccessibilityRequired { onAccessibilityRequired() }
            else { onFeedback?(L("使用贴伴需要辅助功能权限，请在设置中授权后继续。")) }
            return
        }
        busy = true; onChange?()
        let target = paste.target, direct = !copyOnly
        let captureBarrier = captureInbox.pendingUpperBound
        worker.async { [weak self] in
            guard let self else { return }
            guard self.drainCaptures(maximum: Int.max, through: captureBarrier) else {
                DispatchQueue.main.async { self.busy = false; self.onChange?() }
                return
            }
            var writtenCount: Int?
            do {
                let values = try self.store.content(id: id).output(plainText: plainText)
                try DispatchQueue.main.sync {
                    if !copyOnly && !self.paste.trusted {
                        throw NSError(domain: "PastePal.Accessibility", code: 1, userInfo: [NSLocalizedDescriptionKey: L("辅助功能权限已撤销，请在设置中重新授权。")])
                    }
                    let count = try PasteboardIO.write(values, to: self.pasteboard)
                    self.monitor.noteOwnWrite(count: count, representations: values)
                    writtenCount = count
                }
                try self.store.markUsed(id: id, policy: self.settings.retentionPolicy, now: self.retentionClock())
                try self.publishSnapshot()
                DispatchQueue.main.async {
                    self.status = nil; self.busy = false; self.onChange?()
                    if direct {
                        self.onDismiss?()
                        self.paste.paste(to: target, expectedChangeCount: writtenCount!) { [weak self] message in
                            if let message { self?.onFeedback?(message) }
                        }
                    } else { self.onDismiss?() }
                }
            } catch {
                let message = writtenCount == nil ? error.localizedDescription : L("内容已复制，但历史顺序更新失败。请手动粘贴。\(error.localizedDescription)")
                DispatchQueue.main.async { self.busy = false; self.status = message; self.onChange?(); self.onFeedback?(message) }
            }
        }
    }
    func setPaused(_ paused: Bool) {
        settings.paused = paused; monitor.resetBaseline(); onChange?()
    }
    func delete(id: String) { mutate { try self.store.delete(id: id) } }
    func clear() { mutate { try self.store.clearUngrouped() } }
    func createGroup(name: String, completion: ((Result<ClipGroup, Error>) -> Void)? = nil) {
        worker.async {
            do {
                let group = try self.store.createGroup(name: name)
                try self.publishSnapshot()
                DispatchQueue.main.async { completion?(.success(group)) }
            } catch {
                if let completion { DispatchQueue.main.async { completion(.failure(error)) } }
                else { self.report(error.localizedDescription) }
            }
        }
    }
    func renameGroup(id: String, name: String) { mutate { try self.store.renameGroup(id: id, name: name) } }
    func moveGroup(id: String, offset: Int) { mutate { try self.store.moveGroup(id: id, offset: offset) } }
    func deleteGroup(id: String) { mutate { try self.store.deleteGroup(id: id, policy: self.settings.retentionPolicy, now: self.retentionClock()) } }
    func add(entryID: String, toGroup groupID: String) { mutate { try self.store.add(entryID: entryID, toGroup: groupID) } }
    func remove(entryID: String, fromGroup groupID: String) { mutate { try self.store.remove(entryID: entryID, fromGroup: groupID, policy: self.settings.retentionPolicy, now: self.retentionClock()) } }
    func entryIDs(in groupID: String) -> Set<String> { (try? store.entryIDs(in: groupID)) ?? [] }
    func groupIDs(for entryID: String) -> Set<String> { (try? store.groupIDs(for: entryID)) ?? [] }
    func containsEntry(id: String) -> Bool { (try? store.contains(id: id)) == true }
    var ungroupedEntryCount: Int { (try? store.ungroupedEntryCount()) ?? 0 }
    func retentionRemovalCount(for policy: HistoryRetentionPolicy, now: Date = Date()) -> Int {
        (try? store.retentionRemovalCount(for: policy, now: now)) ?? 0
    }
    func setLimit(_ limit: Int, completion: @escaping (Bool) -> Void) {
        var policy = settings.retentionPolicy
        policy.count = limit
        setRetentionPolicy(policy, completion: completion)
    }
    func setRetentionPolicy(_ policy: HistoryRetentionPolicy, completion: @escaping (Bool) -> Void) {
        do {
            let revision = try retentionUpdateLock.withLock {
                try settings.saveRetentionPolicy(policy)
                retentionRevision += 1
                return retentionRevision
            }
            worker.async {
                let current = self.retentionUpdateLock.withLock {
                    self.retentionRevision == revision ? self.settings.retentionPolicy : nil
                }
                guard let current else { return }
                do {
                    try self.store.applyRetention(current, now: self.retentionClock())
                    self.publish()
                } catch {
                    let message = L("保留设置已保存，后台清理失败，将在后续维护时重试。\(error.localizedDescription)")
                    DispatchQueue.main.async {
                        guard self.retentionUpdateLock.withLock({ self.retentionRevision == revision }) else { return }
                        self.status = message; self.onChange?()
                    }
                }
            }
            completion(true)
        } catch { completion(false) }
    }
    func loadContent(id: String, completion: @escaping (Result<ClipboardContent, Error>) -> Void) {
        worker.async {
            let result = Result { try self.store.content(id: id) }
            DispatchQueue.main.async { completion(result) }
        }
    }
    private func mutate(_ action: @escaping () throws -> Void) {
        let captureBarrier = captureInbox.pendingUpperBound
        worker.async {
            guard self.drainCaptures(maximum: Int.max, through: captureBarrier) else { return }
            do { try action(); self.publish() } catch { self.report(error.localizedDescription) }
        }
    }
    private func publish() {
        do {
            try publishSnapshot()
        } catch { report(error.localizedDescription) }
    }
    private func publishSnapshot() throws {
        let snapshot = try store.overview(), warning = store.cleanupWarning
        let schedule = publicationLock.withLock { () -> Bool in
            pendingPublication = (snapshot, warning)
            guard !publicationScheduled else { return false }
            publicationScheduled = true
            return true
        }
        if schedule {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let publication = self.publicationLock.withLock { () -> (HistoryOverview, String?)? in
                    defer { self.pendingPublication = nil; self.publicationScheduled = false }
                    return self.pendingPublication
                }
                guard let (snapshot, warning) = publication else { return }
                self.apply(snapshot); self.status = warning; self.onChange?()
            }
        }
    }
    private func apply(_ snapshot: HistoryOverview) {
        entries = snapshot.entries; groups = snapshot.groups; entryCount = snapshot.count
    }
    private func report(_ message: String) { DispatchQueue.main.async { self.status = message; self.onChange?() } }
    private func cachedSourceIcon(_ source: SourceApplication) -> Data? {
        let key = source.bundleID as NSString
        if let data = sourceIconCache.object(forKey: key) { return data as Data }
        if missingSourceIcons.contains(source.bundleID) { return nil }
        let data = sourceIconProvider(source)
        if let data { sourceIconCache.setObject(data as NSData, forKey: key, cost: data.count) }
        else {
            if missingSourceIcons.count >= 128 { missingSourceIcons.removeAll(keepingCapacity: true) }
            missingSourceIcons.insert(source.bundleID)
        }
        return data
    }
    static func applicationIconPNG(_ source: SourceApplication) -> Data? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleID),
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128), from: .zero, operation: .copy, fraction: 1)
        context.flushGraphics(); NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}
