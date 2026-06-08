import Foundation

/// 负责规则的加载、默认写入、热重载。
/// 规则文件路径：~/.config/inputswitcher/rules.json
final class Config {

    static let shared = Config()

    private(set) var ruleSet: RuleSet = Config.defaultRuleSet()
    private var source: DispatchSourceFileSystemObject?
    var onReload: (() -> Void)?

    var fileURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/inputswitcher/rules.json")
    }

    /// 初始化：若文件不存在则写入默认规则，然后加载并开始监听变化。
    func load() {
        let url = fileURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: url.path) {
            writeDefault()
        }
        reloadFromDisk()
        startWatching()
    }

    private func reloadFromDisk() {
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(RuleSet.self, from: data)
            ruleSet = decoded
            NSLog("[InputSwitcher] 已加载规则 \(decoded.rules.count) 条，enabled=\(decoded.enabled)")
        } catch {
            NSLog("[InputSwitcher] 规则文件解析失败，使用内置默认：\(error)")
            ruleSet = Config.defaultRuleSet()
        }
    }

    func writeDefault() {
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            let data = try enc.encode(Config.defaultRuleSet())
            try data.write(to: fileURL)
            NSLog("[InputSwitcher] 已写入默认规则到 \(fileURL.path)")
        } catch {
            NSLog("[InputSwitcher] 写入默认规则失败：\(error)")
        }
    }

    func setEnabled(_ on: Bool) {
        ruleSet.enabled = on
        save()
    }

    /// 把内存中的 ruleSet 写回磁盘（界面增删改后调用）。
    func save() {
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try enc.encode(ruleSet).write(to: fileURL)
            NSLog("[InputSwitcher] 规则已保存")
        } catch {
            NSLog("[InputSwitcher] 保存规则失败：\(error)")
        }
    }

    /// 替换整个规则列表并保存
    func replaceRules(_ rules: [Rule]) {
        ruleSet.rules = rules
        save()
    }

    // MARK: - 文件监听（热重载）

    private func startWatching() {
        stopWatching()
        let fd = open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            guard let self = self else { return }
            // 某些编辑器是替换文件（rename/delete），需要重新建立监听
            self.reloadFromDisk()
            self.onReload?()
            self.startWatching()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func stopWatching() {
        source?.cancel()
        source = nil
    }

    // MARK: - 默认规则（你的 6 条）

    static func defaultRuleSet() -> RuleSet {
        let EN = "com.apple.keylayout.ABC"
        // 默认中文用苹果系统简体拼音（人人都有、稳定）。
        // 想用搜狗/微信/豆包等第三方输入法，在「规则设置」里改即可。
        let ZH = "com.apple.inputmethod.SCIM.ITABC"

        return RuleSet(enabled: true, rules: [
            // ===== VSCode 区域规则：不限定 App，只靠 DOM class 匹配 =====
            // 这样「桌面版 VSCode」和「浏览器里的 code-server」都能命中，一劳永逸。

            // 1) CodeBuddy / Copilot Chat 侧边栏 → 中文
            Rule(name: "AI侧边栏→中文",
                 domClassAny: ["ql-editor"], inputSource: ZH),

            // 2) 代码编辑器 → 英文
            Rule(name: "代码编辑器→英文",
                 domClassAny: ["native-edit-context"], inputSource: EN),

            // 3a) 内置终端里跑 Claude → 中文（靠 AXDescription 含 claude 识别，须在“终端→英文”之前）
            Rule(name: "VSCode终端·Claude→中文",
                 domClassAny: ["xterm-helper-textarea"],
                 descRegex: "claude", inputSource: ZH),

            // 3b) 内置终端其余 → 英文
            Rule(name: "VSCode终端→英文",
                 domClassAny: ["xterm-helper-textarea"], inputSource: EN),

            // ===== 应用级规则 =====
            // 4) 企业微信 → 中文
            Rule(name: "企业微信→中文",
                 bundleId: "com.tencent.WeWorkMac", inputSource: ZH),

            // ===== 浏览器网址规则（放在 App 规则之后、浏览器默认之前）=====
            // 5) Overleaf → 英文
            Rule(name: "Overleaf→英文",
                 urlRegex: "overleaf\\.com", inputSource: EN),

            // ===== 终端 App（系统“终端”）=====
            // 6) 终端里跑 Claude Code → 中文（靠窗口标题识别；必须排在“终端默认英文”之前）
            Rule(name: "终端·ClaudeCode→中文",
                 bundleId: "com.apple.Terminal",
                 winTitleRegex: "Claude Code", inputSource: ZH),

            // 7) 终端其余（普通命令行）→ 英文
            Rule(name: "终端·命令行→英文",
                 bundleId: "com.apple.Terminal", inputSource: EN),
        ])
    }
}
