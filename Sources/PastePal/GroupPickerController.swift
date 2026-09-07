import PastePalLocalization
import AppKit
import ClipboardCore

final class GroupPickerTable: NSTableView {
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else {
            super.keyDown(with: event); return
        }
        switch event.keyCode {
        case 36, 76, 49: onConfirm?()
        case 53: onCancel?()
        default: super.keyDown(with: event)
        }
    }
}

final class GroupPickerController: NSViewController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let model: AppModel
    private let entryID: String?
    var onChooseGroup: ((String) -> Void)?
    private let search = NSSearchField()
    private let table = GroupPickerTable()
    private let empty = NSTextField(labelWithString: "")
    private var available: [ClipGroup] = []
    private var results: [ClipGroup] = []
    var onClose: (() -> Void)?

    var visibleGroupNames: [String] { results.map(\.name) }
    var searchControl: NSSearchField { search }

    init(model: AppModel, entryID: String? = nil) {
        self.model = model; self.entryID = entryID
        super.init(nibName: nil, bundle: nil)
        view = NSView()
        buildUI(); reloadGroups()
    }
    required init?(coder: NSCoder) { fatalError() }
    func focus() { view.window?.makeFirstResponder(search) }
    func close() { let callback = onClose; onClose = nil; callback?() }
    func reloadGroups() {
        let memberships = entryID.map(model.groupIDs(for:)) ?? []
        available = model.groups.filter { !memberships.contains($0.id) }
        applyFilter()
    }
    private func buildUI() {
        let content = view
        let heading = NSTextField(labelWithString: entryID == nil ? L("管理分组") : L("将所选内容加入分组"))
        heading.font = .systemFont(ofSize: 19, weight: .semibold)
        search.placeholderString = L("筛选分组"); search.delegate = self; search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel(entryID == nil ? L("筛选要管理的分组") : L("筛选可加入的分组"))
        let column = NSTableColumn(identifier: .init("group")); column.width = 360
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 30
        table.delegate = self; table.dataSource = self; table.allowsMultipleSelection = false
        table.target = self; table.doubleAction = #selector(addSelected)
        table.setAccessibilityLabel(entryID == nil ? L("分组列表") : L("可加入的分组"))
        table.onConfirm = { [weak self] in self?.addSelected() }
        table.onCancel = { [weak self] in self?.close() }
        let scroll = ScrollerlessScrollView(); scroll.documentView = table; scroll.drawsBackground = false; scroll.borderType = .noBorder
        table.backgroundColor = .clear
        empty.font = .systemFont(ofSize: 12); empty.textColor = .secondaryLabelColor; empty.alignment = .center
        let hint = NSTextField(labelWithString: L("输入筛选，↑↓ 选择，列表中空格 / 回车确认，Esc 返回历史"))
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        let add = NSButton(title: entryID == nil ? L("编辑分组") : L("加入"), target: self, action: #selector(addSelected)); add.bezelStyle = .rounded; add.keyEquivalent = "\r"
        let cancel = NSButton(title: L("返回历史"), target: self, action: #selector(cancel)); cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [hint, NSView(), cancel, add]); buttons.orientation = .horizontal; buttons.spacing = 8
        buttons.views[1].setContentHuggingPriority(.defaultLow, for: .horizontal)
        [heading, search, scroll, empty, buttons].forEach { content.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            heading.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            search.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            buttons.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            buttons.heightAnchor.constraint(equalToConstant: 28)
        ])
    }
    private func applyFilter() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        results = query.isEmpty ? available : available.filter { $0.name.range(of: query, options: [.caseInsensitive, .literal]) != nil }
        table.reloadData()
        if !results.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        empty.stringValue = available.isEmpty ? L("没有可用分组，可通过顶部 + 新建") : L("没有匹配的分组")
        empty.isHidden = !results.isEmpty
    }
    func controlTextDidChange(_ notification: Notification) { applyFilter() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { addSelected(); return true }
        if commandSelector == #selector(NSResponder.moveDown(_:)), !results.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false); view.window?.makeFirstResponder(table); return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { close(); return true }
        return false
    }
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let field = NSTextField(labelWithString: results[row].name)
        field.font = .systemFont(ofSize: 13); field.lineBreakMode = .byTruncatingTail
        return field
    }
    @objc func addSelected() {
        guard results.indices.contains(table.selectedRow) else { return }
        let groupID = results[table.selectedRow].id
        if let entryID {
            model.add(entryID: entryID, toGroup: groupID)
            close()
        } else {
            let choose = onChooseGroup
            close()
            choose?(groupID)
        }
    }
    @objc private func cancel() { close() }
}
