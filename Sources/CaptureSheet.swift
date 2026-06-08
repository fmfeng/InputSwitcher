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

    private var imeItems: [InputSource.Item] = []
    private var options: [PrecisionOption] = []

    /// 一个「匹配精确度」选项：人话标题 + 如何生成规则
    private struct PrecisionOption {
        let title: String
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
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "根据捕获的焦点添加规则"
        buildOptions()
        buildUI()
        return window
    }

    // MARK: - 根据捕获内容生成「精确度」候选

    private func buildOptions() {
        options.removeAll()

        let host = CaptureSheet.host(from: ctx.url)
        let appName = ctx.appName.isEmpty ? ctx.bundleId : ctx.appName
        let primaryClass = CaptureSheet.primaryClass(ctx.domClasses)

        // 有 DOM class（网页/Electron 里的某类控件）
        if let cls = primaryClass {
            options.append(PrecisionOption(title: "这一类输入框，在任何地方都算（推荐）") { ime, name in
                Rule(name: name, domClassAny: [cls], inputSource: ime)
            })
            if !host.isEmpty {
                options.append(PrecisionOption(title: "仅「\(host)」网站上的这类输入框") { ime, name in
                    Rule(name: name, domClassAny: [cls],
                         urlRegex: NSRegularExpression.escapedPattern(for: host), inputSource: ime)
                })
            }
            if !ctx.bundleId.isEmpty {
                options.append(PrecisionOption(title: "仅「\(appName)」应用里的这类输入框") { ime, name in
                    Rule(name: name, bundleId: self.ctx.bundleId, domClassAny: [cls], inputSource: ime)
                })
            }
        }

        // 有网址：整站规则
        if !host.isEmpty {
            options.append(PrecisionOption(title: "整个「\(host)」网站") { ime, name in
                Rule(name: name, urlRegex: NSRegularExpression.escapedPattern(for: host), inputSource: ime)
            })
        }

        // 总是可以：整个应用
        if !ctx.bundleId.isEmpty {
            options.append(PrecisionOption(title: "整个「\(appName)」应用") { ime, name in
                Rule(name: name, bundleId: self.ctx.bundleId, inputSource: ime)
            })
        }

        // 兜底：万一啥都没抓到
        if options.isEmpty {
            options.append(PrecisionOption(title: "整个当前应用") { ime, name in
                Rule(name: name, bundleId: self.ctx.bundleId, inputSource: ime)
            })
        }
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

        imeItems = InputSource.selectableList()
        for i in imeItems { imePopup.addItem(withTitle: i.localizedName) }
        // 默认中文豆包
        if let idx = imeItems.firstIndex(where: { $0.id == "com.bytedance.inputmethod.doubaoime.pinyin" }) {
            imePopup.selectItem(at: idx)
        }

        nameField.placeholderString = "留空自动命名"

        let rows = NSStackView(views: [
            labeledRow(label("匹配范围："), precisionPopup),
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

        precisionPopup.widthAnchor.constraint(equalToConstant: 360).isActive = true
        imePopup.widthAnchor.constraint(equalToConstant: 360).isActive = true
        nameField.widthAnchor.constraint(equalToConstant: 360).isActive = true

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
        if let cls = CaptureSheet.primaryClass(ctx.domClasses) {
            let zone = Rule.zoneName(for: ctx.domClasses)
            lines.append("· 控件：\(zone ?? cls)")
        }
        let host = CaptureSheet.host(from: ctx.url)
        if !host.isEmpty { lines.append("· 网站：\(host)") }
        if !ctx.windowTitle.isEmpty { lines.append("· 窗口标题：\(ctx.windowTitle)") }
        return lines.joined(separator: "\n")
    }

    // MARK: - 保存

    @objc private func save() {
        let idx = precisionPopup.indexOfSelectedItem
        guard idx >= 0, idx < options.count else { closeSheet(); return }
        let ime = imeItems[safe: imePopup.indexOfSelectedItem]?.id
            ?? "com.bytedance.inputmethod.doubaoime.pinyin"

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
        let host = CaptureSheet.host(from: ctx.url)
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

    /// 从 URL 提取主机名（去掉 www.）
    static func host(from url: String) -> String {
        guard !url.isEmpty, let u = URL(string: url), let h = u.host else { return "" }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? {
        return indices.contains(i) ? self[i] : nil
    }
}
