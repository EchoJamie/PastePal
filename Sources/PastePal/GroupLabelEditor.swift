import PastePalLocalization
import AppKit

final class GroupLabelEditor: NSStackView, NSTextFieldDelegate {
    let groupID: String
    let nameControl = NSTextField()
    let earlierControl = NSButton(title: L("前移"), target: nil, action: nil)
    let laterControl = NSButton(title: L("后移"), target: nil, action: nil)
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onMove: ((Int) -> Void)?

    init(groupID: String, name: String) {
        self.groupID = groupID
        super.init(frame: .zero)
        orientation = .horizontal; alignment = .centerY; spacing = 4
        nameControl.stringValue = name; nameControl.delegate = self
        nameControl.font = .systemFont(ofSize: 12)
        nameControl.setAccessibilityLabel(L("编辑分组名称"))
        nameControl.widthAnchor.constraint(equalToConstant: 150).isActive = true
        earlierControl.target = self; earlierControl.action = #selector(earlier)
        laterControl.target = self; laterControl.action = #selector(later)
        let save = NSButton(title: L("保存"), target: self, action: #selector(submit))
        let cancel = NSButton(title: L("取消"), target: self, action: #selector(cancel))
        [nameControl, earlierControl, laterControl, save, cancel].forEach(addArrangedSubview)
        for button in [earlierControl, laterControl, save, cancel] {
            button.bezelStyle = .rounded; button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
        }
        nameControl.nextKeyView = earlierControl
        earlierControl.nextKeyView = laterControl; laterControl.nextKeyView = save
        save.nextKeyView = cancel; cancel.nextKeyView = nameControl
    }
    required init?(coder: NSCoder) { fatalError() }
    func focus() { window?.makeFirstResponder(nameControl) }
    @objc func submit() { onSubmit?(nameControl.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
    @objc func cancel() { onCancel?() }
    @objc private func earlier() { onMove?(-1) }
    @objc private func later() { onMove?(1) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { submit(); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { cancel(); return true }
        return false
    }
}
