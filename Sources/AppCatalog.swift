import Cocoa

/// 提供「正在运行的应用」列表（供配置界面下拉选择），
/// 以及 bundleId -> 显示名 的映射。
enum AppCatalog {

    struct App {
        let bundleId: String
        let name: String
    }

    /// 当前正在运行、且是普通图形应用的列表，按名称排序、去重。
    static func runningApps() -> [App] {
        var seen = Set<String>()
        var result: [App] = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular else { continue }   // 只要有界面的常规 App
            guard let bid = app.bundleIdentifier, !bid.isEmpty else { continue }
            if seen.contains(bid) { continue }
            seen.insert(bid)
            result.append(App(bundleId: bid, name: app.localizedName ?? bid))
        }
        // 常用但可能没在运行的，补充进去
        for (bid, name) in knownApps {
            if !seen.contains(bid) {
                seen.insert(bid)
                result.append(App(bundleId: bid, name: name))
            }
        }
        return result.sorted { $0.name < $1.name }
    }

    /// 已知应用的友好名（即使没运行也能显示）
    static let knownApps: [String: String] = [
        "com.microsoft.VSCode": "Visual Studio Code",
        "com.tencent.WeWorkMac": "企业微信",
        "com.tencent.xinWeChat": "微信",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.google.Chrome": "Google Chrome",
        "com.apple.Safari": "Safari",
    ]

    /// 给定 bundleId 返回友好显示名
    static func displayName(for bundleId: String) -> String {
        if let n = knownApps[bundleId] { return n }
        // 在运行列表里找
        for app in NSWorkspace.shared.runningApplications {
            if app.bundleIdentifier == bundleId { return app.localizedName ?? bundleId }
        }
        return bundleId
    }
}
