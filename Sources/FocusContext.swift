import Foundation

/// 一次焦点变化所采集到的上下文信息，供规则匹配。
struct FocusContext {
    var bundleId: String          // 前台应用 bundle id
    var appName: String           // 应用名（调试用）
    var role: String              // AXRole，如 AXTextArea / AXTextField
    var domClasses: [String]      // AXDOMClassList，如 ["native-edit-context"]
    var domIdentifier: String     // AXDOMIdentifier
    var axDescription: String     // AXDescription（VSCode 终端会带正在运行的命令名，如 claude-internal）
    var webAreaTitle: String      // 祖先链上最近的 AXWebArea 的标题
    var windowTitle: String       // 祖先链上最近的 AXWindow 的标题（终端用来识别运行的程序）
    var url: String               // 浏览器当前 URL（如能取到）

    static func empty() -> FocusContext {
        FocusContext(bundleId: "", appName: "", role: "", domClasses: [],
                     domIdentifier: "", axDescription: "", webAreaTitle: "", windowTitle: "", url: "")
    }

    var debugLine: String {
        "app=\(appName)[\(bundleId)] role=\(role) dom=\(domClasses) desc=\(axDescription) win=\(windowTitle) web=\(webAreaTitle) url=\(url)"
    }
}
