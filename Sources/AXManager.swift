import Cocoa
import ApplicationServices

/// 负责：
/// 1. 监听前台应用切换
/// 2. 对前台应用安装 AXObserver，监听焦点元素变化
/// 3. 唤醒 Chromium/Electron 应用的 AX 树
/// 4. 采集 FocusContext，回调出去
final class AXManager {

    /// 焦点上下文变化时回调（已在主线程）
    var onContextChange: ((FocusContext) -> Void)?

    private var currentObserver: AXObserver?
    private var currentAppElement: AXUIElement?
    private var currentPid: pid_t = 0
    private var wokenPids = Set<pid_t>()

    /// 哪些 bundleId 需要轮询窗口标题（由 main 根据「含窗口标题条件的规则」设置）。
    /// 终端这类“焦点不变但标题变”的场景，靠轮询补足。
    var titlePollingBundleIds = Set<String>()
    private var titleTimer: Timer?
    private var lastFingerprint: String = ""

    // 浏览器 bundleId（用于决定是否尝试取 URL）
    private let browserBundleIds: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac",
        "com.google.Chrome.canary", "company.thebrowser.Browser" // Arc
    ]

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(appActivated(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        // 处理启动时已经在前台的应用
        if let app = NSWorkspace.shared.frontmostApplication {
            attach(to: app)
        }
    }

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        attach(to: app)
    }

    // MARK: - 给前台应用安装观察者

    private func attach(to app: NSRunningApplication) {
        let pid = app.processIdentifier
        // 先移除旧的
        detach()

        currentPid = pid
        let axApp = AXUIElementCreateApplication(pid)
        currentAppElement = axApp

        // 唤醒 Chromium/Electron 的 AX 树
        wakeChromiumIfNeeded(axApp, pid)

        // 创建 AXObserver
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon = refcon else { return }
            let mgr = Unmanaged<AXManager>.fromOpaque(refcon).takeUnretainedValue()
            mgr.handleFocusChanged()
        }
        let err = AXObserverCreate(pid, callback, &observer)
        guard err == .success, let obs = observer else {
            NSLog("[InputSwitcher] AXObserverCreate 失败 err=\(err.rawValue) app=\(app.localizedName ?? "?")")
            // 即使没法监听变化，也尝试读一次当前焦点
            emitCurrentFocus()
            return
        }
        currentObserver = obs

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // 监听焦点元素变化
        AXObserverAddNotification(obs, axApp, kAXFocusedUIElementChangedNotification as CFString, refcon)
        // 有些应用焦点切换体现在窗口/value 变化，多订阅几个增强可靠性
        AXObserverAddNotification(obs, axApp, kAXFocusedWindowChangedNotification as CFString, refcon)
        AXObserverAddNotification(obs, axApp, kAXApplicationActivatedNotification as CFString, refcon)

        CFRunLoopAddSource(CFRunLoopGetMain(),
                           AXObserverGetRunLoopSource(obs),
                           .defaultMode)

        // Chromium 唤醒后 AX 树构建需要一点时间，延迟读一次首焦点
        emitCurrentFocus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.emitCurrentFocus()
        }

        // 开启轮询兜底：Chromium 应用焦点事件常漏发/读到旧值，靠轮询纠正
        startPollingIfNeeded(bundleId: app.bundleIdentifier ?? "")
    }

    // MARK: - 焦点指纹轮询（兜底：终端识别程序 + Chromium 焦点纠正）

    private func startPollingIfNeeded(bundleId: String) {
        stopTitlePolling()
        // 需要轮询的情况：①配了窗口标题规则的 App（如终端）②Chromium 系应用
        let needPoll = titlePollingBundleIds.contains(bundleId) || isChromium(bundleId)
        guard needPoll else { return }
        lastFingerprint = ""
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // 仅当该 App 仍在前台时才评估
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleId else { return }
            guard let ctx = self.readFocusContext() else { return }
            // 指纹用与匹配相关的字段（不含 url，避免脏帧抖动）
            let fp = self.matchSignature(ctx)
            if fp != self.lastFingerprint {
                self.lastFingerprint = fp
                // 轮询发现变化后，也走双帧确认，过滤脏帧
                if self.isChromium(ctx.bundleId) {
                    self.emitConfirmed(attempt: 0, lastSig: nil)
                } else {
                    self.onContextChange?(ctx)
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        titleTimer = t
    }

    private func stopTitlePolling() {
        titleTimer?.invalidate()
        titleTimer = nil
    }

    private func detach() {
        stopTitlePolling()
        if let obs = currentObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(obs),
                                  .defaultMode)
        }
        currentObserver = nil
        currentAppElement = nil
    }

    // MARK: - 焦点变化处理

    private func handleFocusChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.emitConfirmed(attempt: 0, lastSig: nil)
        }
    }

    /// 决定切换结果的“签名”——只取真正参与匹配的字段。
    /// url 不进签名：它在 Chromium 焦点切换瞬间最不可靠，且 class 规则优先级更高。
    private func matchSignature(_ ctx: FocusContext) -> String {
        return "\(ctx.bundleId)|\(ctx.role)|\(ctx.domClasses.sorted().joined(separator: ","))|\(ctx.axDescription)|\(ctx.windowTitle)"
    }

    /// 双帧确认：连续两次读到的“匹配签名”一致才采信，过滤 Chromium 半更新脏帧。
    /// 非 Chromium 应用（终端、原生 App）不抖动，直接采信第一帧。
    private func emitConfirmed(attempt: Int, lastSig: String?) {
        guard let ctx = readFocusContext() else { return }

        // 非 Chromium：直接用
        if !isChromium(ctx.bundleId) {
            onContextChange?(ctx)
            return
        }

        // 还没就绪（输入框无 class / 停在外层容器）：唤醒并重试
        if looksUnsettled(ctx), attempt < 8 {
            forceWakeFrontmost()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.emitConfirmed(attempt: attempt + 1, lastSig: nil)
            }
            return
        }

        let sig = matchSignature(ctx)
        // 与上一帧一致 → 确认，采信
        if let last = lastSig, last == sig {
            onContextChange?(ctx)
            return
        }
        // 不一致或首帧 → 80ms 后再读一帧确认
        if attempt < 8 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.emitConfirmed(attempt: attempt + 1, lastSig: sig)
            }
            return
        }
        // 兜底：实在确认不下来，也采信当前帧
        onContextChange?(ctx)
    }

    /// 判断上下文是否"还没就绪"：是输入控件却没读到任何 DOM class，
    /// 或焦点还停在外层容器上。
    private func looksUnsettled(_ ctx: FocusContext) -> Bool {
        // 文本输入控件却没有 class —— 典型的"树没建好"
        if (ctx.role == "AXTextArea" || ctx.role == "AXTextField"), ctx.domClasses.isEmpty {
            return true
        }
        // 焦点停在外层容器（webview/分组），还没下沉到具体输入框
        if ctx.role == "AXWebArea" || ctx.role == "AXGroup" || ctx.role == "AXScrollArea" || ctx.role.isEmpty {
            return true
        }
        return false
    }

    private func isChromium(_ bundleId: String) -> Bool {
        if bundleId == "com.microsoft.VSCode" { return true }
        return browserBundleIds.contains(bundleId)
    }

    /// 强制重新唤醒当前前台应用的 AX 树（刷新后需要）。
    private func forceWakeFrontmost() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    private func emitCurrentFocus() {
        guard let ctx = readFocusContext() else { return }
        onContextChange?(ctx)
    }

    /// 供「快捷键捕获」按需调用：立即读一次当前焦点上下文。
    func captureCurrentContext() -> FocusContext? {
        return readFocusContext()
    }

    // MARK: - Chromium 唤醒

    private func wakeChromiumIfNeeded(_ axApp: AXUIElement, _ pid: pid_t) {
        if wokenPids.contains(pid) { return }
        wokenPids.insert(pid)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    // MARK: - 采集上下文

    private func readFocusContext() -> FocusContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var ctx = FocusContext.empty()
        ctx.bundleId = app.bundleIdentifier ?? ""
        ctx.appName = app.localizedName ?? ""

        // 焦点元素
        var focused: AnyObject?
        let err = AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let focusedEl = focused else {
            // 读不到焦点元素（可能 Chromium 尚未唤醒完成）。仍返回 app 级上下文，便于按 bundleId 命中。
            return ctx
        }
        let el = focusedEl as! AXUIElement

        ctx.role = axString(el, kAXRoleAttribute as String) ?? ""
        ctx.domIdentifier = axString(el, "AXDOMIdentifier") ?? ""
        ctx.domClasses = axDomClassList(el)
        ctx.axDescription = axString(el, kAXDescriptionAttribute as String) ?? ""

        // 沿祖先链找最近的 AXWebArea 标题
        ctx.webAreaTitle = nearestWebAreaTitle(el)

        // 沿祖先链找最近的 AXWindow 标题（终端用来识别运行的程序）
        ctx.windowTitle = nearestWindowTitle(el, axApp: axApp)

        // 浏览器才尝试取 URL
        if browserBundleIds.contains(ctx.bundleId) {
            ctx.url = currentBrowserURL(el, bundleId: ctx.bundleId)
        }

        return ctx
    }

    private func axString(_ el: AXUIElement, _ attr: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    private func axDomClassList(_ el: AXUIElement) -> [String] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(el, "AXDOMClassList" as CFString, &value) == .success else { return [] }
        if let arr = value as? [String] { return arr }
        return []
    }

    private func parent(_ el: AXUIElement) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &value) == .success else { return nil }
        return (value as! AXUIElement?)
    }

    private func nearestWebAreaTitle(_ el: AXUIElement) -> String {
        var cur: AXUIElement? = el
        for _ in 0..<12 {
            guard let c = cur else { break }
            if axString(c, kAXRoleAttribute as String) == "AXWebArea" {
                return axString(c, kAXTitleAttribute as String) ?? ""
            }
            cur = parent(c)
        }
        return ""
    }

    /// 找窗口标题：先沿焦点元素祖先链找 AXWindow；找不到则取 app 的 focusedWindow。
    private func nearestWindowTitle(_ el: AXUIElement, axApp: AXUIElement) -> String {
        var cur: AXUIElement? = el
        for _ in 0..<15 {
            guard let c = cur else { break }
            if axString(c, kAXRoleAttribute as String) == "AXWindow" {
                return axString(c, kAXTitleAttribute as String) ?? ""
            }
            cur = parent(c)
        }
        // 回退：直接问 app 的聚焦窗口
        var win: AnyObject?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &win) == .success,
           let w = win {
            return axString(w as! AXUIElement, kAXTitleAttribute as String) ?? ""
        }
        return ""
    }

    /// 取浏览器 URL：优先沿祖先链找 AXWebArea 的 AXURL；失败回退 AppleScript。
    private func currentBrowserURL(_ el: AXUIElement, bundleId: String) -> String {
        var cur: AXUIElement? = el
        for _ in 0..<12 {
            guard let c = cur else { break }
            if axString(c, kAXRoleAttribute as String) == "AXWebArea" {
                var value: AnyObject?
                if AXUIElementCopyAttributeValue(c, "AXURL" as CFString, &value) == .success {
                    if let url = value as? URL { return url.absoluteString }
                    if let s = value as? String { return s }
                }
            }
            cur = parent(c)
        }
        return appleScriptURL(bundleId: bundleId)
    }

    private func appleScriptURL(bundleId: String) -> String {
        let script: String
        switch bundleId {
        case "com.apple.Safari":
            script = "tell application \"Safari\" to return URL of front document"
        case "com.google.Chrome", "com.google.Chrome.canary":
            script = "tell application \"Google Chrome\" to return URL of active tab of front window"
        case "com.microsoft.edgemac":
            script = "tell application \"Microsoft Edge\" to return URL of active tab of front window"
        default:
            return ""
        }
        var err: NSDictionary?
        if let s = NSAppleScript(source: script), let out = s.executeAndReturnError(&err).stringValue {
            return out
        }
        return ""
    }
}
