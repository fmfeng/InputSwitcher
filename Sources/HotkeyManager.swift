import Cocoa

/// 全局快捷键监听。默认 ⌃⌥⌘K（Control+Option+Command+K）。
/// 复用 App 已有的辅助功能权限。
final class HotkeyManager {

    /// 按下捕获键时回调（已在主线程）
    var onCapture: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?

    // 默认快捷键：Control + Option + Command + K
    private var keyCode: UInt16 = 40  // K
    private var modifiers: NSEvent.ModifierFlags = [.control, .option, .command]

    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.matches(event) == true {
                self?.fire()
                return nil
            }
            return event
        }
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
    }

    func update(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        s += HotkeyManager.keyName(keyCode)
        return s
    }

    // MARK: - 内部

    private func handle(_ event: NSEvent) {
        if matches(event) { fire() }
    }

    private func matches(_ event: NSEvent) -> Bool {
        guard event.keyCode == keyCode else { return false }
        let relevant: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        let pressed = event.modifierFlags.intersection(relevant)
        return pressed == modifiers
    }

    private func fire() {
        DispatchQueue.main.async { [weak self] in
            self?.onCapture?()
        }
    }

    private static func keyName(_ code: UInt16) -> String {
        switch code {
        case 49: return "Space"
        case 0: return "A"
        case 34: return "I"
        case 40: return "K"
        default: return "Key(\(code))"
        }
    }
}
