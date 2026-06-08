import Cocoa

/// 「快捷键捕获焦点」后弹出的窗口：
/// 展示刚捕获到的指纹（人话），让用户选「匹配精确度」+ 输入法，无需理解 DOM class。
final class CaptureSheet: NSObject {

    private let ctx: FocusContext
    var onDone: ((Rule) -> Void)?

    private var window: NSWindow!
    private var selfRef: CaptureSheet?

    private let precisionPopup = NSPopUpButton()
    private let imePopup = NSPopUpButton()
    private let nameField = NSTextField()
    private let warningLabel = NSTextField(labelWithString: "")

    private var imeItems: [InputSource.Item] = []
    private var options: [PrecisionOption] = []

    /// 一个候选规则选项：人话标题 + 如何生成规则。
    /// rank 越小越推荐（越独特、越不容易撞车）。warning 非空时给出冲突提示。
    private struct PrecisionOption {
        let title: String
        let rank: Int
        let warning: String?
        let build: (_ ime: String, _ name: String) -> Rule
    }

    init(context: FocusContext) {
        self.ctx = context
        super.init()
    }

    func retainSelf() { selfRef = self }
    private func releaseSelf() { selfRef = nil }

    func makeWindow() -> NSWindow {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "根据捕获的焦点添加规则"
        buildOptions()
        buildUI()
        return window
    }

    // MARK: - 根据捕获内容生成候选「识别依据」

    private func buildOptions() {
        options.removeAll()

        let host = effectiveHost()
        let appName = ctx.appName.isEmpty ? ctx.bundleId : ctx.appName
        let primaryClass = CaptureSheet.primaryClass(ctx.domClasses)
        let descKeyword = CaptureSheet.descKeyword(ctx.axDescription)

        // ① 最稳：控件描述（desc）——语义化、最耐升级，且通常最独特
        //    例如 AI 聊天框 desc 含 "Chat Input"，终端含运行的命令名
        if let kw = descKeyword {
            options.append(PrecisionOption(
                title: "靠控件描述「\(kw)」识别（最稳，推荐）",
                rank: 0, warning: nil) { ime, name in
                Rule(name: name, descRegex: NSRegularExpression.escapedPattern(for: kw), inputSource: ime)
            })
        }

        // ② DOM class —— 较稳，但可能与别的区域撞车，检测冲突
        if let cls = primaryClass {
            let conflict = CaptureSheet.classConflict(cls)
            let warn = conflict.map { "⚠️ 此类型与已有规则「\($0)」相同，可能互相干扰" }
            let rank = conflict == nil ? 1 : 5   // 撞车则排后面
            let recommend = (descKeyword == nil && conflict == nil) ? "（推荐）" : ""
            options.append(PrecisionOption(
                title: "靠控件类型识别，在任何地方都算\(recommend)",
                rank: rank, warning: warn) { ime, name in
                Rule(name: name, domClassAny: [cls], inputSource: ime)
            })
            // class + 限定网站/应用（缩小范围，降低撞车影响）
            if let conflict = conflict {
                _ = conflict
                if !host.isEmpty {
                    options.append(PrecisionOption(
                        title: "靠控件类型 + 仅「\(host)」网站",
                        rank: 3, warning: nil) { ime, name in
                        Rule(name: name, domClassAny: [cls],
                             urlRegex: NSRegularExpression.escapedPattern(for: host), inputSource: ime)
                    })
                }
                if !ctx.bundleId.isEmpty {
                    options.append(PrecisionOption(
                        title: "靠控件类型 + 仅「\(appName)」应用",
                        rank: 3, warning: nil) { ime, name in
                        Rule(name: name, bundleId: self.ctx.bundleId, domClassAny: [cls], inputSource: ime)
                    })
                }
            }
        }

        // ③ 整个网站
        if !host.isEmpty {
            options.append(PrecisionOption(
                title: "整个「\(host)」网站",
                rank: 2, warning: nil) { ime, name in
                Rule(name: name, urlRegex: NSRegularExpression.escapedPattern(for: host), inputSource: ime)
            })
        }

        // ④ 整个应用
        if !ctx.bundleId.isEmpty {
            options.append(PrecisionOption(
                title: "整个「\(appName)」应用",
                rank: 4, warning: nil) { ime, name in
                Rule(name: name, bundleId: self.ctx.bundleId, inputSource: ime)
            })
        }

        // 兜底
        if options.isEmpty {
            options.append(PrecisionOption(
                title: "整个当前应用",
                rank: 9, warning: nil) { ime, name in
                Rule(name: name, bundleId: self.ctx.bundleId, inputSource: ime)
            })
        }

        // 按 rank 排序：最推荐的在最前面（默认选中）
        options.sort { $0.rank < $1.rank }
    }

    // MARK: - UI

    private func buildUI() {
        let content = window.contentView!

        // 顶部：捕获到的指纹（灰色信息区，人话）
        let infoBox = NSTextField(wrappingLabelWithString: capturedSummary())
        infoBox.font = .systemFont(ofSize: 12)
        infoBox.textColor = .secondaryLabelColor
        infoBox.drawsBackground = true
        infoBox.backgroundColor = .textBackgroundColor
        infoBox.isBezeled = true
        infoBox.translatesAutoresizingMaskIntoConstraints = false

        func label(_ s: String) -> NSTextField {
            let t = NSTextField(labelWithString: s)
            t.alignment = .right
            t.font = .systemFont(ofSize: 12)
            t.widthAnchor.constraint(equalToConstant: 80).isActive = true
            return t
        }

        for o in options { precisionPopup.addItem(withTitle: o.title) }
        precisionPopup.target = self
        precisionPopup.action = #selector(precisionChanged)

        imeItems = InputSource.selectableList()
        for i in imeItems { imePopup.addItem(withTitle: i.localizedName) }
        // 默认中文：系统自带简体拼音（最稳）
        if let idx = imeItems.firstIndex(where: { $0.id == "com.apple.inputmethod.SCIM.ITABC" }) {
            imePopup.selectItem(at: idx)
        }

        nameField.placeholderString = "留空自动命名"

        // 冲突/提示行（随选项变化）
        warningLabel.font = .systemFont(ofSize: 11)
        warningLabel.textColor = .systemOrange
        warningLabel.lineBreakMode = .byWordWrapping
        warningLabel.maximumNumberOfLines = 2

        let rows = NSStackView(views: [
            labeledRow(label("识别依据："), precisionPopup),
            labeledRow(label(""), warningLabel),
            labeledRow(label("切换到："), imePopup),
            labeledRow(label("规则名："), nameField),
        ])
        rows.orientation = .vertical
        rows.spacing = 14
        rows.alignment = .leading
        rows.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(infoBox)
        content.addSubview(rows)

        let okBtn = NSButton(title: "保存规则", target: self, action: #selector(save))
        okBtn.bezelStyle = .rounded
        okBtn.keyEquivalent = "\r"
        let cancelBtn = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancelBtn.bezelStyle = .rounded
        let btnStack = NSStackView(views: [cancelBtn, okBtn])
        btnStack.orientation = .horizontal
        btnStack.spacing = 10
        btnStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(btnStack)

        precisionPopup.widthAnchor.constraint(equalToConstant: 400).isActive = true
        imePopup.widthAnchor.constraint(equalToConstant: 400).isActive = true
        nameField.widthAnchor.constraint(equalToConstant: 400).isActive = true
        warningLabel.widthAnchor.constraint(equalToConstant: 400).isActive = true

        NSLayoutConstraint.activate([
            infoBox.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            infoBox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            infoBox.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            rows.topAnchor.constraint(equalTo: infoBox.bottomAnchor, constant: 18),
            rows.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            rows.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            btnStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            btnStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])

        precisionChanged()   // 初始化警告行
    }

    @objc private func precisionChanged() {
        let idx = precisionPopup.indexOfSelectedItem
        guard idx >= 0, idx < options.count else { warningLabel.stringValue = ""; return }
        warningLabel.stringValue = options[idx].warning ?? ""
    }

    private func labeledRow(_ label: NSTextField, _ control: NSView) -> NSView {
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        return row
    }

    private func capturedSummary() -> String {
        var lines = ["✅ 已捕获焦点："]
        let appName = ctx.appName.isEmpty ? ctx.bundleId : ctx.appName
        if !appName.isEmpty { lines.append("· 应用：\(appName)") }
        if let kw = CaptureSheet.descKeyword(ctx.axDescription) {
            lines.append("· 控件描述：\(kw)")
        }
        if let cls = CaptureSheet.primaryClass(ctx.domClasses) {
            let zone = Rule.zoneName(for: ctx.domClasses)
            lines.append("· 控件类型：\(zone ?? cls)")
        }
        let host = effectiveHost()
        if !host.isEmpty { lines.append("· 网站：\(host)") }
        return lines.joined(separator: "\n")
    }

    // MARK: - 保存

    @objc private func save() {
        let idx = precisionPopup.indexOfSelectedItem
        guard idx >= 0, idx < options.count else { closeSheet(); return }
        let ime = imeItems[safe: imePopup.indexOfSelectedItem]?.id
            ?? "com.apple.inputmethod.SCIM.ITABC"

        let typed = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let autoName = autoGeneratedName(ime: ime)
        let name = typed.isEmpty ? autoName : typed

        let rule = options[idx].build(ime, name)
        onDone?(rule)
        closeSheet()
    }

    private func autoGeneratedName(ime: String) -> String {
        let imeName = InputSwitcherIMEName.display(ime)
        if let zone = Rule.zoneName(for: ctx.domClasses) { return "\(zone)→\(imeName)" }
        if let kw = CaptureSheet.descKeyword(ctx.axDescription) { return "\(kw)→\(imeName)" }
        let host = effectiveHost()
        if !host.isEmpty { return "\(host)→\(imeName)" }
        let appName = ctx.appName.isEmpty ? ctx.bundleId : ctx.appName
        return "\(appName)→\(imeName)"
    }

    @objc private func cancel() { closeSheet() }

    private func closeSheet() {
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            // 独立窗口（快捷键捕获时是独立窗口，不是 sheet）
            window.orderOut(nil)
            window.close()
        }
        releaseSelf()
    }

    // MARK: - 工具

    /// 取最有辨识度的 class：跳过 ql-blank 这种状态类。
    static func primaryClass(_ classes: [String]) -> String? {
        let ignore: Set<String> = ["ql-blank", "monaco-button", "monaco-text-button"]
        return classes.first { !ignore.contains($0) } ?? classes.first
    }

    /// 从控件描述里提取一个稳定、独特的关键词，用于 descRegex 识别。
    /// 例如 "Chat Input (Ask Mode), ask questions..." → "Chat Input"
    ///      "Terminal 1, claude-internal Run the command..." → "claude"
    /// 取不到合适关键词则返回 nil。
    static func descKeyword(_ desc: String) -> String? {
        let d = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        guard d.count >= 2 else { return nil }
        // 已知高价值关键词，命中即用（顺序 = 优先级）
        let known = ["Chat Input", "claude", "gemini", "codex", "aider", "Copilot", "聊天", "对话"]
        for k in known {
            if d.range(of: k, options: .caseInsensitive) != nil { return k }
        }
        // 否则取描述开头到第一个标点/换行前的短语（去掉太长的）
        let separators = CharacterSet(charactersIn: ",，.。:：;；(（\n")
        if let first = d.components(separatedBy: separators).first {
            let phrase = first.trimmingCharacters(in: .whitespaces)
            if phrase.count >= 2 && phrase.count <= 20 { return phrase }
        }
        return nil
    }

    /// 检查某个 DOM class 是否已被现有规则使用（撞车检测）。
    /// 返回冲突规则的名字；无冲突返回 nil。
    static func classConflict(_ cls: String) -> String? {
        for rule in Config.shared.ruleSet.rules {
            if let classes = rule.domClassAny, classes.contains(cls) {
                return rule.name
            }
        }
        return nil
    }

    /// 从 URL 提取主机名（去掉 www.）
    static func host(from url: String) -> String {
        guard !url.isEmpty, let u = URL(string: url), let h = u.host else { return "" }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// 实际可用的主机名。
    /// 当焦点是 VSCode/code-server 的已知区域控件时，URL 不可靠也无意义
    /// （这类控件靠 DOM class 识别，且 Chromium 多标签页时常读到别的标签页 URL），
    /// 此时返回空，不让 URL 干扰捕获。
    private func effectiveHost() -> String {
        // 焦点是已知 IDE 区域（编辑器/终端/AI侧边栏）→ 忽略 URL
        if Rule.zoneName(for: ctx.domClasses) != nil { return "" }
        // 窗口标题表明是 code-server → 也忽略 URL
        if ctx.windowTitle.contains("code-server") { return "" }
        return CaptureSheet.host(from: ctx.url)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? {
        return indices.contains(i) ? self[i] : nil
    }
}
