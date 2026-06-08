import Foundation

/// 单条规则。所有指定了的字段之间是 AND 关系；未指定（nil）的字段忽略。
/// 字段语义：
///   bundleId       —— 精确匹配前台应用 bundle id
///   domClassAny    —— AXDOMClassList 中“包含其中任意一个” class 即算命中
///   webTitleRegex  —— 最近 AXWebArea 标题匹配该正则
///   urlRegex       —— 浏览器 URL 匹配该正则
///   role           —— 精确匹配 AXRole
struct Rule: Codable {
    var name: String
    var bundleId: String?
    var domClassAny: [String]?
    var webTitleRegex: String?
    var winTitleRegex: String?   // 窗口标题正则（终端识别运行的程序，如 "Claude Code"）
    var descRegex: String?       // AXDescription 正则（VSCode 终端识别运行的命令，如 "claude"）
    var urlRegex: String?
    var role: String?
    var inputSource: String      // 命中后切到的输入法 ID

    init(name: String,
         bundleId: String? = nil,
         domClassAny: [String]? = nil,
         webTitleRegex: String? = nil,
         winTitleRegex: String? = nil,
         descRegex: String? = nil,
         urlRegex: String? = nil,
         role: String? = nil,
         inputSource: String) {
        self.name = name
        self.bundleId = bundleId
        self.domClassAny = domClassAny
        self.webTitleRegex = webTitleRegex
        self.winTitleRegex = winTitleRegex
        self.descRegex = descRegex
        self.urlRegex = urlRegex
        self.role = role
        self.inputSource = inputSource
    }

    func matches(_ ctx: FocusContext) -> Bool {
        if let b = bundleId, b != ctx.bundleId { return false }
        if let role = role, role != ctx.role { return false }
        if let classes = domClassAny {
            let hit = classes.contains { ctx.domClasses.contains($0) }
            if !hit { return false }
        }
        if let re = webTitleRegex, !Rule.regexHit(re, ctx.webAreaTitle) { return false }
        if let re = winTitleRegex, !Rule.regexHit(re, ctx.windowTitle) { return false }
        if let re = descRegex, !Rule.regexHit(re, ctx.axDescription) { return false }
        if let re = urlRegex, !Rule.regexHit(re, ctx.url) { return false }
        // 至少要有一个条件被指定，避免空规则匹配一切
        let hasAnyCondition = bundleId != nil || role != nil || domClassAny != nil
            || webTitleRegex != nil || winTitleRegex != nil || descRegex != nil || urlRegex != nil
        return hasAnyCondition
    }

    private static func regexHit(_ pattern: String, _ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return re.firstMatch(in: text, options: [], range: range) != nil
    }

    /// 给配置界面用的“人话”条件描述
    var conditionSummary: String {
        var parts: [String] = []
        if let b = bundleId { parts.append("应用=\(AppCatalog.displayName(for: b))") }
        if let c = domClassAny, !c.isEmpty {
            let zone = Rule.zoneName(for: c)
            parts.append(zone ?? "区域class=\(c.joined(separator: "/"))")
        }
        if let t = webTitleRegex { parts.append("网页标题含「\(t)」") }
        if let t = winTitleRegex { parts.append("窗口标题含「\(t)」") }
        if let d = descRegex { parts.append("运行命令含「\(d)」") }
        if let u = urlRegex { parts.append("网址含「\(Rule.prettyURL(u))」") }
        if let r = role { parts.append("role=\(r)") }
        return parts.isEmpty ? "（无条件）" : parts.joined(separator: " 且 ")
    }

    /// 把 domClass 映射成 VSCode 区域的人话名
    static func zoneName(for classes: [String]) -> String? {
        if classes.contains("ql-editor") { return "VSCode·AI侧边栏" }
        if classes.contains("native-edit-context") { return "VSCode·代码编辑器" }
        if classes.contains("xterm-helper-textarea") { return "VSCode·终端" }
        return nil
    }

    /// 把正则里的转义还原成给人看的样子（overleaf\.com -> overleaf.com）
    static func prettyURL(_ regex: String) -> String {
        return regex.replacingOccurrences(of: "\\.", with: ".")
                    .replacingOccurrences(of: "^https?://", with: "")
    }
}

/// 规则集合 + 全局设置
struct RuleSet: Codable {
    var enabled: Bool                // 总开关
    var rules: [Rule]                // 按顺序匹配，第一条命中即用

    /// 返回第一条命中的规则
    func firstMatch(_ ctx: FocusContext) -> Rule? {
        return rules.first { $0.matches(ctx) }
    }
}
