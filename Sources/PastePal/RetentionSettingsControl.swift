import PastePalLocalization
import AppKit
import ClipboardCore

@MainActor
final class RetentionSettingsControl: NSStackView, NSTextFieldDelegate {
    let quantity = NSTextField()
    let unit = NSPopUpButton()
    let feedback = NSTextField(wrappingLabelWithString: "")
    private let readPolicy: () -> HistoryRetentionPolicy
    private let savePolicy: (HistoryRetentionPolicy, @escaping (Bool) -> Void) -> Void
    private var submission = 0

    init(readPolicy: @escaping () -> HistoryRetentionPolicy,
         savePolicy: @escaping (HistoryRetentionPolicy, @escaping (Bool) -> Void) -> Void) {
        self.readPolicy = readPolicy
        self.savePolicy = savePolicy
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 6
        quantity.widthAnchor.constraint(equalToConstant: 88).isActive = true
        quantity.setAccessibilityLabel(L("未分组历史保留数量"))
        quantity.delegate = self
        quantity.target = self; quantity.action = #selector(commitQuantity)
        unit.addItems(withTitles: [L("天"), L("条")])
        unit.setAccessibilityLabel(L("未分组历史保留单位"))
        unit.target = self; unit.action = #selector(changeUnit)
        let controls = NSStackView(views: [quantity, unit])
        controls.orientation = .horizontal; controls.spacing = 8
        addArrangedSubview(controls)
        feedback.font = .systemFont(ofSize: 11)
        feedback.textColor = .secondaryLabelColor
        feedback.setAccessibilityLabel(L("保留设置状态"))
        addArrangedSubview(feedback)
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload() {
        let policy = readPolicy()
        unit.selectItem(at: policy.mode == .time ? 0 : 1)
        quantity.stringValue = String(policy.mode == .time ? policy.days : policy.count)
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        commitQuantity()
    }
    @objc func changeUnit() {
        let policy = readPolicy()
        quantity.stringValue = String(unit.indexOfSelectedItem == 0 ? policy.days : policy.count)
        commitQuantity()
    }
    @objc func commitQuantity() {
        guard let value = Int(quantity.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else {
            reload()
            feedback.stringValue = L("请输入正整数，已恢复原设置。")
            return
        }
        var policy = readPolicy()
        policy.mode = unit.indexOfSelectedItem == 0 ? .time : .count
        if policy.mode == .time { policy.days = value } else { policy.count = value }
        guard policy != readPolicy() else { reload(); feedback.stringValue = ""; return }
        submission += 1
        let currentSubmission = submission
        savePolicy(policy) { [weak self] success in
            guard let self, self.submission == currentSubmission else { return }
            self.reload()
            self.feedback.stringValue = success ? "" : L("保存失败，已恢复原设置。请检查记录状态后重试。")
        }
    }
}
