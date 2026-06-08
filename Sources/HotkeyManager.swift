import Cocoa
import Carbon

/// 全局快捷键监听（Carbon RegisterEventHotKey 实现）。
/// 相比 NSEvent.addGlobalMonitor：系统级注册，不依赖辅助功能权限，
/// 不会在权限飘忽/重新签名后"静默掉线"。默认 ⌃⌥⌘K。
final class HotkeyManager {

    /// 按下捕获键时回调（已在主线程）
    var onCapture: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    // 默认快捷键：Control + Option + Command + K
    private var keyCode: UInt32 = UInt32(kVK_ANSI_K)            // K = 40
    private var carbonMods: UInt32 = UInt32(controlKey | optionKey | cmdKey)

    func start() {
        installHandler()
        register()
    }

    func stop() {
        if let h = hotKeyRef { UnregisterEventHotKey(h); hotKeyRef = nil }
        if let h = handlerRef { RemoveEventHandler(h); handlerRef = nil }
    }

    /// 修改快捷键并重新注册（Carbon 修饰键掩码用 controlKey/optionKey/cmdKey/shiftKey）
    func update(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonMods = carbonModifiers
        if let h = hotKeyRef { UnregisterEventHotKey(h); hotKeyRef = nil }
        register()
    }

    var displayString: String {
        var s = ""
        if carbonMods & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonMods & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonMods & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonMods & UInt32(cmdKey) != 0 { s += "⌘" }
        s += HotkeyManager.keyName(keyCode)
        return s
    }

    // MARK: - 内部

    private func installHandler() {
        if handlerRef != nil { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData = userData else { return noErr }
            let mgr = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            mgr.fire()
            return noErr
        }, 1, &spec, selfPtr, &handlerRef)
    }

    private func register() {
        let hotKeyID = EventHotKeyID(signature: OSType(0x49535743) /* 'ISWC' */, id: 1)
        let status = RegisterEventHotKey(keyCode, carbonMods, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            NSLog("[InputSwitcher] 快捷键注册失败 status=\(status)（可能与其他软件冲突）")
        } else {
            NSLog("[InputSwitcher] 快捷键已注册：\(displayString)")
        }
    }

    private func fire() {
        DispatchQueue.main.async { [weak self] in
            self?.onCapture?()
        }
    }

    private static func keyName(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_Space: return "Space"
        default: return "Key(\(code))"
        }
    }
}
