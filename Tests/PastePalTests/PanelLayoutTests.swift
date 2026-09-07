import PastePalLocalization
import XCTest
import AppKit
@testable import PastePal

final class PanelLayoutTests: XCTestCase {
    func testPanelUsesFullScreenWidthAndRealBottomEdge() {
        let screen = NSRect(x: 0, y: 0, width: 1_728, height: 1_117)

        XCTAssertEqual(
            PanelLayout.frame(in: screen),
            NSRect(x: 0, y: 0, width: 1_728, height: PanelLayout.height)
        )
    }

    func testHistoryPanelDoesNotConstrainBottomEdgeToVisibleFrame() {
        let proposed = NSRect(x: -1_920, y: -240, width: 1_920, height: PanelLayout.height)
        let panel = HistoryPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        XCTAssertEqual(panel.constrainFrameRect(proposed, to: NSScreen.main), proposed)
    }

    func testPanelPreservesNegativeMultiDisplayCoordinates() {
        let primary = NSRect(x: 0, y: 0, width: 1_728, height: 1_117)
        let secondary = NSRect(x: -1_920, y: -240, width: 1_920, height: 1_080)

        XCTAssertEqual(
            PanelLayout.frame(
                at: NSPoint(x: -960, y: 200),
                screenFrames: [primary, secondary],
                fallback: primary
            ),
            NSRect(x: -1_920, y: -240, width: 1_920, height: PanelLayout.height)
        )
    }

    func testPanelFallsBackToMainScreenWhenPointerIsOutsideKnownFrames() {
        let main = NSRect(x: 0, y: 0, width: 1_728, height: 1_117)

        XCTAssertEqual(
            PanelLayout.frame(at: NSPoint(x: 4_000, y: 4_000), screenFrames: [], fallback: main),
            PanelLayout.frame(in: main)
        )
    }

    func testEntranceOffsetRespectsReduceMotion() {
        XCTAssertEqual(PanelLayout.entranceOffset(reduceMotion: false), -PanelLayout.height)
        XCTAssertEqual(PanelLayout.entranceOffset(reduceMotion: true), 0)
    }

    @MainActor func testMaterialMaskDoesNotDimContentAndRespectsReducedTransparency() {
        let background = PanelBackground(frame: NSRect(x: 0, y: 0, width: 300, height: 356))
        let content = NSTextField(labelWithString: "清晰的卡片内容")
        background.contentView.addSubview(content)
        background.updateMaterialMask(reduceTransparency: false)
        XCTAssertNotNil(background.effectView.maskImage)
        XCTAssertTrue(background.effectView.superview === background.contentView.superview)
        XCTAssertFalse(content.isDescendant(of: background.effectView))
        XCTAssertEqual(background.contentView.alphaValue, 1)
        XCTAssertEqual(background.alphaValue, 1)
        XCTAssertEqual(content.alphaValue, 1)
        background.updateMaterialMask(reduceTransparency: true)
        XCTAssertNil(background.effectView.maskImage)
        XCTAssertEqual(background.alphaValue, 1)
        XCTAssertEqual(content.alphaValue, 1)
    }
}

final class PanelAppearanceTests: AppTestSupport {
    @MainActor func testToolbarAndCardsFitPanelAcrossWidthsAndSearch() async throws {
        let (model, panel) = try await makePanel((1...12).map { "内容\($0)" })
        for index in 1...10 {
            let group = try model.store.createGroup(name: "长分组名称\(index)")
            if index == 1 {
                for entry in model.entries { try model.store.add(entryID: entry.id, toGroup: group.id) }
            }
        }
        model.refresh()
        try await waitUntil { model.groups.count == 10 }
        let window = try XCTUnwrap(panel.window)
        defer { panel.dismiss() }
        for width: CGFloat in [900, 1280, 1680] {
            window.setFrame(NSRect(x: 0, y: 0, width: width, height: 356), display: false)
            panel.prepareForDisplay()
            for searching in [false, true] {
                if searching { panel.selectGroup(model.groups.first?.id); panel.beginSearch(selectAll: false) }
                let root = try XCTUnwrap(window.contentView)
                root.layoutSubtreeIfNeeded(); panel.historyView.layoutSubtreeIfNeeded()
                let toolbar = try XCTUnwrap(searching ? panel.searchControl.superview?.superview : panel.searchTriggerControl.superview)
                let toolbarRect = toolbar.convert(toolbar.bounds, to: root)
                let hintRect = panel.shortcutHintControl.convert(panel.shortcutHintControl.bounds, to: root)
                let viewport = panel.historyScrollView.convert(panel.historyScrollView.bounds, to: root)
                let item = try XCTUnwrap(panel.historyView.item(at: IndexPath(item: 0, section: 0)))
                XCTAssertTrue(root.bounds.contains(toolbarRect))
                XCTAssertFalse(toolbarRect.intersects(hintRect))
                XCTAssertTrue(root.bounds.contains(viewport))
                XCTAssertGreaterThan(item.view.frame.width, 0)
                XCTAssertLessThanOrEqual(item.view.frame.height, viewport.height)
                XCTAssertFalse(panel.shortcutHintControl.toolTip?.isEmpty ?? true)

            }
        }
    }
}
