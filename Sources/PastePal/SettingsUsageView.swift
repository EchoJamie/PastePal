import PastePalLocalization
import AppKit
import KeyboardShortcuts

@MainActor
final class SettingsUsageView: NSStackView {
    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 16
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh(shortcuts: AppShortcutStore, screenshotEnabled: Bool) {
        for view in arrangedSubviews {
            removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        var history = [
            (globalShortcut(.showHistory), L("呼出历史")),
            (shortcuts.display(for: .beginSearch), L("搜索")),
            (L("空格"), L("预览所选内容")),
            (shortcuts.display(for: .usePlainText), L("纯文本使用"))
        ]
        let positions = AppShortcutAction.allCases.filter { $0.position != nil }
        if positions.allSatisfy({ shortcuts.shortcut(for: $0) == $0.defaultShortcut }) {
            history.append(("⌘1–9", L("使用第 1–9 条")))
        } else {
            history += positions.map { (shortcuts.display(for: $0), $0.title) }
        }
        addSection(L("历史"), entries: history)
        addSection(L("分组"), entries: [
            ("Tab / ⇧Tab", L("切换分组／范围")),
            (shortcuts.display(for: .addToGroup), L("加入分组"))
        ])
        addSection(L("截图"), entries: [
            (globalShortcut(.captureRegion), L("开始截屏"))
        ] + ScreenshotAnnotationModel.Tool.allCases.map { ($0.shortcut, $0.title) } + [
            ("⌘P", L("贴图置顶")), ("⌘S", L("美化并保存"))
        ], sectionNote: screenshotEnabled ? nil : L("未启用"))
    }

    private func globalShortcut(_ name: KeyboardShortcuts.Name) -> String {
        KeyboardShortcuts.getShortcut(for: name)?.description ?? L("未设置")
    }

    private func addSection(_ title: String, entries: [(String, String)], sectionNote: String? = nil) {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        let divider = NSBox()
        divider.boxType = .separator
        section.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        section.setCustomSpacing(16, after: divider)
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let headingRow = NSStackView(views: [heading])
        headingRow.spacing = 8
        headingRow.alignment = .firstBaseline
        if let sectionNote {
            let note = NSTextField(labelWithString: sectionNote)
            note.font = .systemFont(ofSize: 11)
            note.textColor = .secondaryLabelColor
            headingRow.addArrangedSubview(note)
        }
        section.addArrangedSubview(headingRow)
        section.setCustomSpacing(16, after: headingRow)
        var cells: [NSView] = []
        for entry in entries {
            let (keys, purpose) = entry
            let label = NSTextField(wrappingLabelWithString: purpose)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.widthAnchor.constraint(equalToConstant: 88).isActive = true
            let keyLabel = NSTextField(string: keys)
            keyLabel.isEditable = false
            keyLabel.isSelectable = false
            keyLabel.isBezeled = true
            keyLabel.bezelStyle = .roundedBezel
            keyLabel.focusRingType = .none
            keyLabel.font = .systemFont(ofSize: 12)
            keyLabel.alignment = .center
            keyLabel.drawsBackground = true
            keyLabel.backgroundColor = .controlBackgroundColor
            keyLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            let preferredWidth = keyLabel.widthAnchor.constraint(equalToConstant: 140)
            preferredWidth.priority = NSLayoutConstraint.Priority(999)
            NSLayoutConstraint.activate([
                preferredWidth,
                keyLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
                keyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 140)
            ])
            let row = NSStackView(views: [label, keyLabel, NSView()])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 14
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 20).isActive = true
            cells.append(row)
        }
        for index in stride(from: 0, to: cells.count, by: 2) {
            let pair = NSStackView(views: [cells[index], index + 1 < cells.count ? cells[index + 1] : NSView()])
            pair.orientation = .horizontal
            pair.alignment = .top
            pair.distribution = .fillEqually
            pair.spacing = 28
            pair.arrangedSubviews[0].widthAnchor.constraint(equalTo: pair.arrangedSubviews[1].widthAnchor).isActive = true
            section.addArrangedSubview(pair)
            pair.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        }
        addArrangedSubview(section)
        section.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
}
