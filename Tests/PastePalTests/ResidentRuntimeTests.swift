import XCTest
import AppKit
import ClipboardCore
@testable import PastePal

final class ResidentRuntimeTests: AppTestSupport {
    @MainActor func testRepeatedModelStartStopReleasesOwnersAndDrainsCaptures() async throws {
        let settings = SettingsStore(defaults: defaults)
        try settings.saveRetentionPolicy(.init(mode: .count, count: 10000, days: 30))
        for cycle in 0..<40 {
            var model: AppModel? = try AppModel(directory: directory, settings: settings, pasteboard: board,
                linkMetadataLoader: ResidentNoMetadataLoader(), retentionInterval: 0.02)
            weak var releasedModel: AppModel?
            weak var releasedMonitor: ClipboardMonitor?
            weak var releasedStore: HistoryStore?
            releasedModel = model; releasedMonitor = model?.monitor; releasedStore = model?.store
            model?.start(); model?.start()
            for item in 0..<10 {
                try PasteboardIO.write(values("resident-\(cycle)-\(item) " + String(repeating: "x", count: 4096)), to: board)
                model?.monitor.poll()
            }
            await withCheckedContinuation { continuation in model?.prepareToQuit { continuation.resume() } }
            XCTAssertEqual(try model?.store.overview().count, (cycle + 1) * 10)
            XCTAssertLessThanOrEqual(model?.entries.count ?? 0, 128)
            model = nil
            try await waitUntil { releasedModel == nil && releasedMonitor == nil && releasedStore == nil }
            XCTAssertNil(releasedModel); XCTAssertNil(releasedMonitor); XCTAssertNil(releasedStore)
        }
        print("RESIDENT_CHECK model_cycles=40 captures=400 all_owners_released=true")
    }

    @MainActor func testRepeatedScreenshotAuxiliaryWindowsReleaseImagesAndControllers() async throws {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(data: nil, width: 1024, height: 768, bitsPerComponent: 8,
            bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1024, height: 768))
        let image = try XCTUnwrap(context.makeImage())
        for _ in 0..<50 {
            weak var exporter: ScreenshotExportController?
            weak var pin: ScreenshotPinnedImageController?
            weak var exportWindow: NSWindow?
            weak var pinWindow: NSWindow?
            weak var rendered: CGImage?
            autoreleasepool {
                let export = ScreenshotExportController(image: image)
                let pinned = ScreenshotPinnedImageController(image: image)
                exporter = export; pin = pinned
                exportWindow = export.window; pinWindow = pinned.window; rendered = export.renderedImage
                export.close(); pinned.close()
            }
            try await Task.sleep(for: .milliseconds(10))
            XCTAssertNil(exporter); XCTAssertNil(pin)
            XCTAssertNil(exportWindow); XCTAssertNil(pinWindow); XCTAssertNil(rendered)
        }
        print("RESIDENT_CHECK auxiliary_window_cycles=50 windows_shown=false all_owners_released=true")
    }

    @MainActor func testRepeatedSearchBurstsReleaseCancelledQueries() async throws {
        let store = try HistoryStore(directory: directory)
        _ = try store.record(ContentCodec.decode(values("latest")), limit: 10)
        for _ in 0..<30 {
            var coordinator: HistorySearchCoordinator? = HistorySearchCoordinator(directory: directory)
            weak var releasedCoordinator: HistorySearchCoordinator?
            releasedCoordinator = coordinator
            for index in 0..<100 {
                coordinator?.submit(query: "obsolete-\(index)", groupID: nil) { _ in }
            }
            let finished = expectation(description: "latest query")
            coordinator?.submit(query: "latest", groupID: nil) { result in
                XCTAssertEqual(try? result.get().count, 1)
                finished.fulfill()
            }
            await fulfillment(of: [finished], timeout: 3)
            coordinator?.cancel(); coordinator = nil
            try await waitUntil { releasedCoordinator == nil }
            XCTAssertNil(releasedCoordinator)
        }
        print("RESIDENT_CHECK search_bursts=30 submitted_queries=3030 coordinators_released=true")
    }
}

private final class ResidentNoMetadataLoader: LinkMetadataLoading {
    func fetch(_ url: URL, completion: @escaping (LinkMetadataPayload) -> Void) {
        completion(LinkMetadataPayload(status: .failed))
    }
    func cancelAll() {}
}
