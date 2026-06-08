import Cocoa

/// 添加/编辑单条规则的弹窗。用「类型」下拉简化，普通用户不接触正则。
final class RuleEditorSheet: NSObject {

    enum RuleType: Int, CaseIterable {
        case app = 0        // 按应用
        case website        // 按网站
        case vscodeZone     // VSCode 区域
        case windowTitle    // 按窗口标题（终端运行的程序）

        var title: String {
            switch self {
            case .app: return "按应用（如 企业微信、微信）"
            case .website: return "按网站（如 overleaf.com）"
            case .vscodeZone: return "VSCode 区域（编辑器/终端/AI侧边栏）"
            case .windowTitle: return "按窗口标题（如终端里运行的 Claude Code）"
            }
        }
    }

    private let editing: Rule?
    var onDone: ((Rule) -> Void)?

    private var window: NSWindow!
    private var selfRef: RuleEditorSheet?

    // 控件
    private let nameField = NSTextField()
    private let typePopup = NSPopUpButton()
    private let imePopup = NSPopUpButton()

    // 各类型专属输入区容器
    private let appPopup = NSPopUpButton()
    private let websiteField = NSTextField()
    private let zonePopup = NSPopUpButton()
    private let winAppPopup = NSPopUpButton()
    private let winTitleField = NSTextField()
    private var appRow: NSView!
    private var websiteRow: NSView!
    private var zoneRow: NSView!
    private var winAppRow: NSView!
    private var winTitleRow: NSView!

    private var imeItems: [InputSource.Item] = []
    private var appItems: [AppCatalog.App] = []

    init(rule: Rule?) {
        self.editing = rule
        super.init()
    }

    func retainSelf() { selfRef = self }
    private func releaseSelf() { selfRef = nil }

    func makeWindow() -> NSWindow {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
            styleMask: [.titled], backing: .buffered, defer: false)
        buildUI()
        populateForEditing()
        return window
    }

    private func buildUI() {
        let content = window.contentView!

        func label(_ s: String) -> NSTextField {
            let t = NSTextField(labelWithString: s)
            t.alignment = .right
            t.font = .systemFont(ofSize: 12)
            return t
        }

        // 名称
        nameField.placeholderString = "给规则起个名字"

        // 类型
        for t in RuleType.allCases { typePopup.addItem(withTitle: t.title) }
        typePopup.target = self
        typePopup.action = #selector(typeChanged)

        // 应用下拉
        appItems = AppCatalog.runningApps()
        for a in appItems { appPopup.addItem(withTitle: a.name) }

        // 网站输入
        websiteField.placeholderString = "网址关键词，如 overleaf.com"

        // VSCode 区域
        zonePopup.addItem(withTitle: "代码编辑器")
        zonePopup.addItem(withTitle: "终端")
        zonePopup.addItem(withTitle: "AI 侧边栏（CodeBuddy/Copilot）")

        // 窗口标题：选哪个终端 App + 标题关键词
        for a in appItems { winAppPopup.addItem(withTitle: a.name) }
        // 默认选中“终端”
        if let idx = appItems.firstIndex(where: { $0.bundleId == "com.apple.Terminal" }) {
            winAppPopup.selectItem(at: idx)
        }
        winTitleField.placeholderString = "标题关键词，如 Claude Code"

        // 输入法下拉
        imeItems = InputSource.selectableList()
        for i in imeItems { imePopup.addItem(withTitle: i.localizedName) }

        // 行容器
        appRow = labeledRow(label("应用："), appPopup)
        websiteRow = labeledRow(label("网址："), websiteField)
        zoneRow = labeledRow(label("区域："), zonePopup)
        winAppRow = labeledRow(label("终端App："), winAppPopup)
        winTitleRow = labeledRow(label("标题含："), winTitleField)

        let rows = NSStackView(views: [
            labeledRow(label("名称："), nameField),
            labeledRow(label("类型："), typePopup),
            appRow, websiteRow, zoneRow, winAppRow, winTitleRow,
            labeledRow(label("切换到："), imePopup),
        ])
        rows.orientation = .vertical
        rows.spacing = 12
        rows.alignment = .leading
        rows.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(rows)

        // 底部按钮
        let okBtn = NSButton(title: "保存", target: self, action: #selector(save))
        okBtn.bezelStyle = .rounded
        okBtn.keyEquivalent = "\r"
        let cancelBtn = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancelBtn.bezelStyle = .rounded
        let btnStack = NSStackView(views: [cancelBtn, okBtn])
        btnStack.orientation = .horizontal
        btnStack.spacing = 10
        btnStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(btnStack)

        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            rows.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            rows.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            btnStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            btnStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])

        nameField.widthAnchor.constraint(equalToConstant: 320).isActive = true
        websiteField.widthAnchor.constraint(equalToConstant: 320).isActive = true
        appPopup.widthAnchor.constraint(equalToConstant: 320).isActive = true
        zonePopup.widthAnchor.constraint(equalToConstant: 320).isActive = true
        winAppPopup.widthAnchor.constraint(equalToConstant: 320).isActive = true
        winTitleField.widthAnchor.constraint(equalToConstant: 320).isActive = true
        imePopup.widthAnchor.constraint(equalToConstant: 320).isActive = true

        typeChanged()   // 初始显示
    }

    private func labeledRow(_ label: NSTextField, _ control: NSView) -> NSView {
        label.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        return row
    }

    // MARK: - 类型切换显示

    @objc private func typeChanged() {
        let t = RuleType(rawValue: typePopup.indexOfSelectedItem) ?? .app
        appRow.isHidden = (t != .app)
        websiteRow.isHidden = (t != .website)
        zoneRow.isHidden = (t != .vscodeZone)
        winAppRow.isHidden = (t != .windowTitle)
        winTitleRow.isHidden = (t != .windowTitle)
    }

    // MARK: - 编辑态回填

    private func populateForEditing() {
        // 选中默认输入法（编辑时回填，新增时默认中文豆包）
        let defaultIME = editing?.inputSource ?? "com.bytedance.inputmethod.doubaoime.pinyin"
        if let idx = imeItems.firstIndex(where: { $0.id == defaultIME }) {
            imePopup.selectItem(at: idx)
        }

        guard let r = editing else {
            // 新增：默认“按应用”
            typePopup.selectItem(at: RuleType.app.rawValue)
            typeChanged()
            return
        }
        nameField.stringValue = r.name

        // 判断类型
        if r.winTitleRegex != nil {
            typePopup.selectItem(at: RuleType.windowTitle.rawValue)
            if let bid = r.bundleId, let idx = appItems.firstIndex(where: { $0.bundleId == bid }) {
                winAppPopup.selectItem(at: idx)
            }
            winTitleField.stringValue = Rule.prettyURL(r.winTitleRegex ?? "")
        } else if let classes = r.domClassAny, Rule.zoneName(for: classes) != nil {
            typePopup.selectItem(at: RuleType.vscodeZone.rawValue)
            if classes.contains("native-edit-context") { zonePopup.selectItem(at: 0) }
            else if classes.contains("xterm-helper-textarea") { zonePopup.selectItem(at: 1) }
            else if classes.contains("ql-editor") { zonePopup.selectItem(at: 2) }
        } else if r.urlRegex != nil || r.webTitleRegex != nil {
            typePopup.selectItem(at: RuleType.website.rawValue)
            websiteField.stringValue = Rule.prettyURL(r.urlRegex ?? r.webTitleRegex ?? "")
        } else if let bid = r.bundleId {
            typePopup.selectItem(at: RuleType.app.rawValue)
            if let idx = appItems.firstIndex(where: { $0.bundleId == bid }) {
                appPopup.selectItem(at: idx)
            }
        }
        typeChanged()
    }

    // MARK: - 保存 / 取消

    @objc private func save() {
        let t = RuleType(rawValue: typePopup.indexOfSelectedItem) ?? .app
        let ime = imeItems[safe: imePopup.indexOfSelectedItem]?.id
            ?? "com.bytedance.inputmethod.doubaoime.pinyin"

        var rule = Rule(name: "", bundleId: nil, domClassAny: nil,
                        webTitleRegex: nil, urlRegex: nil, role: nil, inputSource: ime)

        var autoName = ""
        switch t {
        case .app:
            if let app = appItems[safe: appPopup.indexOfSelectedItem] {
                rule.bundleId = app.bundleId
                autoName = "\(app.name)→\(InputSwitcherIMEName.display(ime))"
            }
        case .website:
            let kw = websiteField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !kw.isEmpty else { shake("请填写网址关键词"); return }
            // 把用户输入的 overleaf.com 转成安全正则（点号转义）
            rule.urlRegex = NSRegularExpression.escapedPattern(for: kw)
            autoName = "\(kw)→\(InputSwitcherIMEName.display(ime))"
        case .vscodeZone:
            rule.bundleId = "com.microsoft.VSCode"
            switch zonePopup.indexOfSelectedItem {
            case 0: rule.domClassAny = ["native-edit-context"]; autoName = "VSCode编辑器"
            case 1: rule.domClassAny = ["xterm-helper-textarea"]; autoName = "VSCode终端"
            default: rule.domClassAny = ["ql-editor"]; autoName = "VSCode-AI侧边栏"
            }
            autoName += "→\(InputSwitcherIMEName.display(ime))"
        case .windowTitle:
            let kw = winTitleField.stringValue.trimmingCharacters(in: .whitespaces)
            guard !kw.isEmpty else { shake("请填写窗口标题关键词"); return }
            if let app = appItems[safe: winAppPopup.indexOfSelectedItem] {
                rule.bundleId = app.bundleId
            }
            rule.winTitleRegex = NSRegularExpression.escapedPattern(for: kw)
            autoName = "\(kw)→\(InputSwitcherIMEName.display(ime))"
        }

        let typed = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        rule.name = typed.isEmpty ? autoName : typed

        onDone?(rule)
        closeSheet()
    }

    @objc private func cancel() {
        closeSheet()
    }

    private func closeSheet() {
        if let parent = window.sheetParent {
            parent.endSheet(window)
        }
        releaseSelf()
    }

    private func shake(_ msg: String) {
        let a = NSAlert()
        a.messageText = msg
        a.runModal()
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? {
        return indices.contains(i) ? self[i] : nil
    }
}
