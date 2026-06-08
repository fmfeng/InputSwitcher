import Cocoa

/// 规则配置窗口：列表 + 增删改 + 上下移。无需手写 JSON。
final class RuleWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    private var rules: [Rule] = []
    private var tableView: NSTableView!
    var onSaved: (() -> Void)?

    convenience init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        win.title = "InputSwitcher 规则设置"
        win.center()
        self.init(window: win)
        buildUI()
    }

    func reloadFromConfig() {
        rules = Config.shared.ruleSet.rules
        tableView?.reloadData()
    }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // 顶部说明
        let hint = NSTextField(labelWithString: "规则从上往下匹配，命中第一条即生效。把「特例」放在「通用」上面。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hint)

        // 表格
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        tableView = NSTableView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 28
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(editSelected)
        tableView.target = self

        let cName = NSTableColumn(identifier: .init("name")); cName.title = "规则名"; cName.width = 180
        let cCond = NSTableColumn(identifier: .init("cond")); cCond.title = "条件"; cCond.width = 320
        let cIME  = NSTableColumn(identifier: .init("ime"));  cIME.title = "切换到"; cIME.width = 150
        tableView.addTableColumn(cName)
        tableView.addTableColumn(cCond)
        tableView.addTableColumn(cIME)
        scroll.documentView = tableView
        content.addSubview(scroll)

        // 按钮们
        let addBtn = makeButton("添加", #selector(addRule))
        let tplBtn = makeButton("从模板添加", #selector(addFromTemplate))
        let editBtn = makeButton("编辑", #selector(editSelected))
        let delBtn = makeButton("删除", #selector(deleteSelected))
        let upBtn = makeButton("上移", #selector(moveRuleUp))
        let downBtn = makeButton("下移", #selector(moveRuleDown))
        let resetBtn = makeButton("恢复默认", #selector(resetDefault))

        let btnStack = NSStackView(views: [addBtn, tplBtn, editBtn, delBtn, upBtn, downBtn, resetBtn])
        btnStack.orientation = .horizontal
        btnStack.spacing = 8
        btnStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(btnStack)

        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: btnStack.topAnchor, constant: -12),

            btnStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            btnStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])

        reloadFromConfig()
    }

    private func makeButton(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    // MARK: - TableView

    func numberOfRows(in tableView: NSTableView) -> Int { rules.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let rule = rules[row]
        let id = tableColumn?.identifier.rawValue ?? ""
        let text: String
        switch id {
        case "name": text = rule.name
        case "cond": text = rule.conditionSummary
        case "ime":  text = InputSwitcherIMEName.display(rule.inputSource)
        default: text = ""
        }
        let cell = NSTextField(labelWithString: text)
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }

    // MARK: - 操作

    @objc private func addRule() {
        presentEditor(for: nil)
    }

    private var templates: [RuleTemplates.Template] = []

    @objc private func addFromTemplate(_ sender: NSButton) {
        templates = RuleTemplates.all()
        let menu = NSMenu()
        for (i, t) in templates.enumerated() {
            let item = NSMenuItem(title: t.menuTitle, action: #selector(templatePicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            menu.addItem(item)
        }
        // 在按钮下方弹出
        let location = NSPoint(x: 0, y: sender.bounds.height + 4)
        menu.popUp(positioning: nil, at: location, in: sender)
    }

    @objc private func templatePicked(_ sender: NSMenuItem) {
        let t = templates[sender.tag]
        // 去重：同名已存在就不重复加
        if rules.contains(where: { $0.name == t.rule.name }) {
            let a = NSAlert()
            a.messageText = "已存在同名规则「\(t.rule.name)」"
            a.runModal()
            return
        }
        if t.prependToTop {
            rules.insert(t.rule, at: 0)
        } else {
            rules.append(t.rule)
        }
        persist()
    }

    @objc private func editSelected() {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        presentEditor(for: row)
    }

    @objc private func deleteSelected() {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        rules.remove(at: row)
        persist()
    }

    @objc private func moveRuleUp() {
        let row = tableView.selectedRow
        guard row > 0 else { return }
        rules.swapAt(row, row - 1)
        persist()
        tableView.selectRowIndexes([row - 1], byExtendingSelection: false)
    }

    @objc private func moveRuleDown() {
        let row = tableView.selectedRow
        guard row >= 0, row < rules.count - 1 else { return }
        rules.swapAt(row, row + 1)
        persist()
        tableView.selectRowIndexes([row + 1], byExtendingSelection: false)
    }

    @objc private func resetDefault() {
        let alert = NSAlert()
        alert.messageText = "恢复为默认规则？"
        alert.informativeText = "这会覆盖你现在的所有规则。"
        alert.addButton(withTitle: "恢复默认")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            rules = Config.defaultRuleSet().rules
            persist()
        }
    }

    private func persist() {
        Config.shared.replaceRules(rules)
        tableView.reloadData()
        onSaved?()
    }

    // MARK: - 弹出编辑器

    private func presentEditor(for row: Int?) {
        let editor = RuleEditorSheet(rule: row.map { rules[$0] })
        editor.onDone = { [weak self] newRule in
            guard let self = self else { return }
            if let row = row {
                self.rules[row] = newRule
            } else {
                self.rules.append(newRule)
            }
            self.persist()
        }
        guard let window = self.window else { return }
        window.beginSheet(editor.makeWindow(), completionHandler: nil)
        editor.retainSelf()   // 防止被释放
    }
}

/// 输入法 ID -> 友好名（缓存一次）
enum InputSwitcherIMEName {
    private static var map: [String: String] = {
        var m: [String: String] = [:]
        for item in InputSource.selectableList() { m[item.id] = item.localizedName }
        return m
    }()
    static func display(_ id: String) -> String { map[id] ?? id }
    static func refresh() {
        map = [:]
        for item in InputSource.selectableList() { map[item.id] = item.localizedName }
    }
}
