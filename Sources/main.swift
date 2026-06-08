import Cocoa
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private let ax = AXManager()
    private let inputSource = InputSource()
    private let hotkey = HotkeyManager()
    private var captureSheet: CaptureSheet?
    private var captureWindow: NSWindow?

    // 调试：记录最近一次命中
    private var lastHitName: String = "—"
    private var lastContext: String = "—"

    private let statusMenuItem = NSMenuItem(title: "当前：未开始", action: nil, keyEquivalent: "")
    private let hitMenuItem = NSMenuItem(title: "命中规则：—", action: nil, keyEquivalent: "")
    private let toggleMenuItem = NSMenuItem(title: "暂停切换", action: #selector(toggleEnabled), keyEquivalent: "")
    private let loginItemMenuItem = NSMenuItem(title: "开机自动启动", action: nil, keyEquivalent: "")
    private var ruleWindow: RuleWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()

        // 1) 检查辅助功能权限
        if !ensureAXPermission() {
            statusMenuItem.title = "当前：缺少辅助功能权限"
        }

        // 2) 加载规则 + 热重载
        Config.shared.onReload = { [weak self] in
            self?.refreshMenu()
            self?.inputSource.invalidateCache()
            self?.updateTitlePolling()
        }
        Config.shared.load()
        updateTitlePolling()

        // 3) 启动焦点监听
        ax.onContextChange = { [weak self] ctx in
            self?.handleContext(ctx)
        }
        ax.start()

        // 4) 全局快捷键捕获（⌃⌥空格）
        hotkey.onCapture = { [weak self] in
            self?.captureFocusedAndAddRule()
        }
        hotkey.start()

        // 5) 首次运行自动注册开机自启
        enableLoginItemIfFirstRun()

        refreshMenu()
    }

    // MARK: - 开机自启（需 macOS 13+）

    private func enableLoginItemIfFirstRun() {
        guard #available(macOS 13.0, *) else { return }
        let key = "didSetupLoginItem"
        if !UserDefaults.standard.bool(forKey: key) {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
        }
    }

    @objc private func toggleLoginItem() {
        guard #available(macOS 13.0, *) else { return }
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled {
                try svc.unregister()
            } else {
                try svc.register()
            }
        } catch {
            NSLog("[InputSwitcher] 切换开机自启失败：\(error)")
        }
        refreshMenu()
    }

    // MARK: - 快捷键捕获焦点 -> 添加规则

    private func captureFocusedAndAddRule() {
        // 此刻焦点还在目标区域，立即抓取
        guard let ctx = ax.captureCurrentContext() else {
            NSSound.beep()
            return
        }
        let sheet = CaptureSheet(context: ctx)
        sheet.onDone = { [weak self] rule in
            guard let self = self else { return }
            var rules = Config.shared.ruleSet.rules
            // class 类规则插到最前（更精确，优先级更高）；其余追加到末尾
            if rule.domClassAny != nil {
                rules.insert(rule, at: 0)
            } else {
                rules.append(rule)
            }
            Config.shared.replaceRules(rules)
            self.refreshMenu()
            self.inputSource.invalidateCache()
            self.updateTitlePolling()
            self.ruleWindow?.reloadFromConfig()
        }
        // 用独立窗口展示（此时本 App 不在前台）
        let win = sheet.makeWindow()
        win.center()
        captureSheet = sheet
        captureWindow = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        sheet.retainSelf()
    }

    // MARK: - 核心：上下文 -> 规则 -> 切换

    private func handleContext(_ ctx: FocusContext) {
        lastContext = ctx.debugLine
        guard Config.shared.ruleSet.enabled else {
            updateDebugMenu(hit: "（已暂停）")
            return
        }
        if let rule = Config.shared.ruleSet.firstMatch(ctx) {
            let before = InputSource.currentID() ?? "nil"
            let changed = inputSource.switchTo(rule.inputSource)
            lastHitName = rule.name + (changed ? " ✓切换" : "")
            updateDebugMenu(hit: rule.name)
            DebugLog.write("命中[\(rule.name)] 目标=\(rule.inputSource) 切前=\(before) 切换=\(changed) | \(ctx.debugLine)")
        } else {
            // 未命中：按设定不切换
            updateDebugMenu(hit: "无（保持现状）")
            DebugLog.write("未命中 | \(ctx.debugLine)")
        }
    }

    /// 根据规则里「含窗口标题条件」的规则，决定哪些 App 需要标题轮询。
    private func updateTitlePolling() {
        var ids = Set<String>()
        for rule in Config.shared.ruleSet.rules where rule.winTitleRegex != nil {
            if let b = rule.bundleId { ids.insert(b) }
        }
        ax.titlePollingBundleIds = ids
    }

    // MARK: - 权限

    @discardableResult
    private func ensureAXPermission() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: - 菜单栏

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            // 固定键盘图标（模板图标，自动适配深浅色菜单栏）
            if let img = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "InputSwitcher") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "⌨"
            }
        }
        let menu = NSMenu()
        menu.addItem(statusMenuItem)
        menu.addItem(hitMenuItem)
        menu.addItem(.separator())
        menu.addItem(toggleMenuItem)
        menu.addItem(NSMenuItem(title: "规则设置…", action: #selector(openRuleWindow), keyEquivalent: ","))
        let captureHint = NSMenuItem(title: "💡 在目标输入框按 \(hotkey.displayString) 即可捕获添加规则", action: nil, keyEquivalent: "")
        captureHint.isEnabled = false
        menu.addItem(captureHint)
        menu.addItem(NSMenuItem(title: "打开规则文件 (JSON)", action: #selector(openRules), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "重置为默认规则", action: #selector(resetRules), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "重新请求辅助功能权限", action: #selector(reauth), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(loginItemMenuItem)
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))

        loginItemMenuItem.action = #selector(toggleLoginItem)

        // target 指到自己
        for item in menu.items where item.action != nil {
            item.target = self
        }
        statusItem.menu = menu
    }

    private func refreshMenu() {
        let enabled = Config.shared.ruleSet.enabled
        toggleMenuItem.title = enabled ? "暂停切换" : "恢复切换"
        statusMenuItem.title = enabled
            ? "当前：运行中（\(Config.shared.ruleSet.rules.count) 条规则）"
            : "当前：已暂停"
        if #available(macOS 13.0, *) {
            loginItemMenuItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        } else {
            loginItemMenuItem.isHidden = true
        }
    }

    private func updateDebugMenu(hit: String) {
        // 仅更新菜单内文字，图标保持固定不变
        hitMenuItem.title = "命中：\(hit)"
    }

    // MARK: - 菜单动作

    @objc private func toggleEnabled() {
        let newVal = !Config.shared.ruleSet.enabled
        Config.shared.setEnabled(newVal)
        refreshMenu()
    }

    @objc private func openRules() {
        NSWorkspace.shared.open(Config.shared.fileURL)
    }

    @objc private func openRuleWindow() {
        if ruleWindow == nil {
            ruleWindow = RuleWindowController()
            ruleWindow?.onSaved = { [weak self] in
                self?.refreshMenu()
                self?.inputSource.invalidateCache()
            }
        }
        ruleWindow?.reloadFromConfig()
        NSApp.activate(ignoringOtherApps: true)
        ruleWindow?.showWindow(nil)
        ruleWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func resetRules() {
        Config.shared.writeDefault()
        // writeDefault 后文件监听会触发 reload；保险起见手动刷新
        refreshMenu()
    }

    @objc private func reauth() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - 入口

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // 无 Dock 图标
let delegate = AppDelegate()
app.delegate = delegate
app.run()
