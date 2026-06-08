import Carbon
import Foundation

/// 输入法切换器：封装 TIS API，带去抖（同一目标不重复切换）。
final class InputSource {

    /// 当前已选中的输入法 ID（缓存，避免重复切换）
    private var lastSelectedID: String?

    /// 缓存：ID -> TISInputSource，避免每次都遍历
    private var cache: [String: TISInputSource] = [:]

    /// 读取系统“当前键盘输入法”的 ID
    static func currentID() -> String? {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        guard let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    /// 一个可供界面下拉使用的输入法条目
    struct Item {
        let id: String
        let localizedName: String
    }

    /// 列出所有「可选中」的键盘输入法（供配置界面下拉用）。
    /// 已去重：同名只保留第一个可选中的。
    static func selectableList() -> [Item] {
        guard let cfList = TISCreateInputSourceList(nil, true)?.takeRetainedValue() else { return [] }
        let list = cfList as! [TISInputSource]
        var result: [Item] = []
        var seenNames = Set<String>()
        for s in list {
            func prop(_ k: CFString) -> String? {
                guard let p = TISGetInputSourceProperty(s, k) else { return nil }
                return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
            }
            func boolProp(_ k: CFString) -> Bool {
                guard let p = TISGetInputSourceProperty(s, k) else { return false }
                return Unmanaged<CFBoolean>.fromOpaque(p).takeUnretainedValue() == kCFBooleanTrue
            }
            guard boolProp(kTISPropertyInputSourceIsSelectCapable) else { continue }
            guard let cat = prop(kTISPropertyInputSourceCategory),
                  cat == (kTISCategoryKeyboardInputSource as String) else { continue }
            guard let id = prop(kTISPropertyInputSourceID) else { continue }
            let name = prop(kTISPropertyLocalizedName) ?? id
            // 同名去重（如两个“微信输入法”），但 ABC 等系统项保留
            let key = name
            if seenNames.contains(key) { continue }
            seenNames.insert(key)
            result.append(Item(id: id, localizedName: name))
        }
        return result
    }

    /// 按 ID 查找一个可选中的输入法
    private func find(_ id: String) -> TISInputSource? {
        if let cached = cache[id] { return cached }
        // includeAllInstalled=true 才能拿到 IME 的子模式（如豆包 .pinyin）
        guard let cfList = TISCreateInputSourceList(nil, true)?.takeRetainedValue() else { return nil }
        let list = cfList as! [TISInputSource]
        for s in list {
            guard let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { continue }
            let sid = Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
            if sid == id {
                cache[id] = s
                return s
            }
        }
        return nil
    }

    private func isSelectable(_ s: TISInputSource) -> Bool {
        guard let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceIsSelectCapable) else { return false }
        return Unmanaged<CFBoolean>.fromOpaque(p).takeUnretainedValue() == kCFBooleanTrue
    }

    /// 切换到指定输入法 ID。返回是否真正执行了切换。
    @discardableResult
    func switchTo(_ id: String) -> Bool {
        // 去抖：如果我们上次就切到了它，并且系统当前确实还是它，则跳过
        if lastSelectedID == id, InputSource.currentID() == id {
            return false
        }
        guard let src = find(id) else {
            NSLog("[InputSwitcher] 找不到输入法: \(id)")
            return false
        }
        guard isSelectable(src) else {
            NSLog("[InputSwitcher] 输入法不可选中（可能未启用）: \(id)")
            return false
        }
        let err = TISSelectInputSource(src)
        if err == noErr {
            lastSelectedID = id
            // 二次确认：部分场景（webview 抢回 / IME 内部档位）切换会被覆盖，
            // 延迟校验系统真实状态，被改回了就再切一次。
            scheduleVerify(id: id, src: src, attempt: 0)
            return true
        } else {
            NSLog("[InputSwitcher] 切换失败 err=\(err): \(id)")
            return false
        }
    }

    private func scheduleVerify(id: String, src: TISInputSource, attempt: Int) {
        guard attempt < 3 else { return }
        let delay = 0.3 + Double(attempt) * 0.3   // 0.3 / 0.6 / 0.9s
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            // 只有当我们"期望的目标"仍是 id 时才纠正（避免和后续切换打架）
            guard self.lastSelectedID == id else { return }
            let cur = InputSource.currentID()
            if cur != id {
                DebugLog.write("二次校验：期望=\(id) 实际=\(cur ?? "nil")，重切")
                TISSelectInputSource(src)
                self.scheduleVerify(id: id, src: src, attempt: attempt + 1)
            }
        }
    }

    /// 外部上下文变化但目标相同时，可调用此方法让下次 switchTo 强制校验系统真实状态
    func invalidateCache() {
        lastSelectedID = nil
    }
}
