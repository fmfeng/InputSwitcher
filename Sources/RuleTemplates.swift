import Foundation

/// 内置规则模板，给不想折腾的用户一键添加常见场景。
enum RuleTemplates {

    private static let EN = "com.apple.keylayout.ABC"
    private static let ZH = "com.apple.inputmethod.SCIM.ITABC"

    struct Template {
        let menuTitle: String
        let rule: Rule
        /// class 类规则应插到列表最前（优先级高）
        var prependToTop: Bool { rule.domClassAny != nil }
    }

    static func all() -> [Template] {
        return [
            Template(menuTitle: "代码编辑器 → 英文（VSCode / code-server 通用）",
                     rule: Rule(name: "代码编辑器→英文", domClassAny: ["native-edit-context"], inputSource: EN)),
            Template(menuTitle: "VSCode 终端 → 英文（通用）",
                     rule: Rule(name: "VSCode终端→英文", domClassAny: ["xterm-helper-textarea"], inputSource: EN)),
            Template(menuTitle: "AI 侧边栏 → 中文（CodeBuddy/Copilot 通用）",
                     rule: Rule(name: "AI侧边栏→中文", domClassAny: ["ql-editor"], inputSource: ZH)),
            Template(menuTitle: "企业微信 → 中文",
                     rule: Rule(name: "企业微信→中文", bundleId: "com.tencent.WeWorkMac", inputSource: ZH)),
            Template(menuTitle: "微信 → 中文",
                     rule: Rule(name: "微信→中文", bundleId: "com.tencent.xinWeChat", inputSource: ZH)),
            Template(menuTitle: "Overleaf → 英文",
                     rule: Rule(name: "Overleaf→英文", urlRegex: "overleaf\\.com", inputSource: EN)),
            Template(menuTitle: "终端里跑 Claude Code → 中文",
                     rule: Rule(name: "终端·ClaudeCode→中文", bundleId: "com.apple.Terminal",
                                winTitleRegex: "Claude Code", inputSource: ZH)),
        ]
    }
}
