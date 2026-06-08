# InputSwitcher

> 一个 macOS 菜单栏小工具：根据你**光标聚焦在哪里**，自动切换中/英文输入法。

再也不用手动切输入法了。它能精确到 **应用内的不同区域** —— 比如在 VSCode 里，代码编辑器和终端自动用英文，AI 助手侧边栏自动用中文。

## 它能做什么

通过 macOS 辅助功能（Accessibility）实时读取当前聚焦的控件，按你设定的规则自动切换输入法。支持的识别维度：

- **按应用**：例如「企业微信 → 中文」「微信 → 中文」
- **按网站**：例如「overleaf.com → 英文」（支持 Chrome / Safari / Edge / Arc）
- **按应用内区域**：靠网页/Electron 控件的 DOM class 识别，例如：
  - VSCode / [code-server](https://github.com/coder/code-server) 的**代码编辑器** → 英文
  - VSCode 的**集成终端** → 英文
  - CodeBuddy / Copilot Chat **AI 侧边栏** → 中文
- **按窗口标题**：例如系统「终端」里跑 `claude` 时 → 中文，普通命令行 → 英文
- **按运行的命令**：VSCode 终端里跑 `claude` 时 → 中文（靠辅助功能描述识别）

桌面版 VSCode 和浏览器里的网页版 code-server **同一套规则都生效**，因为识别的是控件特征而非应用本身。

## 安装

### 方式一：下载 Release（推荐普通用户）

1. 从 [Releases](../../releases) 下载 `InputSwitcher.zip` 并解压。
2. 因为没有 Apple 付费公证，从网络下载的 app 会被 Gatekeeper 拦截。打开**终端**，运行一行命令去掉隔离标记（把路径换成你解压的实际位置）：
   ```bash
   xattr -dr com.apple.quarantine ~/Downloads/InputSwitcher.app
   ```
3. 双击 `InputSwitcher.app` 启动。

### 方式二：自己编译（推荐开发者，最干净）

需要 macOS 自带的 Swift 工具链（装了 Xcode 或 Command Line Tools 即可，`xcode-select --install`）。

```bash
git clone https://github.com/<你的用户名>/InputSwitcher.git
cd InputSwitcher
bash build.sh
```

`build.sh` 会编译并把 app 安装到 `~/Applications/InputSwitcher.app`，然后启动它。

## 首次使用：授予辅助功能权限（必须）

这个工具靠系统辅助功能 API 读取焦点，所以**必须授权**，否则无法工作：

1. 启动后，点菜单栏的键盘图标 → **「重新请求辅助功能权限」**（或手动打开「系统设置 → 隐私与安全性 → 辅助功能」）。
2. 把 **InputSwitcher** 勾选上。
3. 如果是自己编译的：勾选后重新运行 `bash build.sh` 一次让权限生效。

> 注意：辅助功能权限绑定到 app 的签名/路径。如果你重新编译（重新签名），可能需要重新勾选一次。

## 配置规则

点菜单栏图标 → **「规则设置…」**，打开图形界面。规则**从上往下匹配，命中第一条即生效**，所以"特例"要放在"通用"上面。

三种加规则的方式：

1. **快捷键捕获（最方便）**：把光标点进你想配置的输入框/区域，直接按 **`⌃⌥⌘K`**（Control+Option+Command+K），程序会自动识别出当前控件特征，弹窗让你选「匹配范围 + 输入法」，无需懂任何技术细节。
2. **从模板添加**：内置常见场景（VSCode 编辑器/终端/AI 侧边栏、企业微信、Overleaf、Claude Code 等），一键添加。
3. **手动添加**：选「按应用 / 按网站 / VSCode 区域 / 按窗口标题」，填关键词即可，不用写正则。

规则保存在 `~/.config/inputswitcher/rules.json`，也可手动编辑，保存后自动热重载。

### 默认中文用的是哪个输入法？

默认规则里的中文目标是**系统自带的简体拼音**（人人都有、最稳定）。如果你想用搜狗 / 微信 / 豆包等第三方输入法，在「规则设置」里把对应规则的「切换到」改成你的输入法即可。

> 提示：部分第三方输入法（如豆包）被切换 API 选中后引擎加载较慢，可能出现"图标已切换但仍打英文"，这是该输入法自身的问题。若遇到，建议中文场景改用系统简体拼音。

## 常见问题

**Q：切换不生效？**
先确认辅助功能权限已勾选。VSCode / 浏览器这类应用首次需要 1~2 秒"唤醒"辅助功能树，刚启动时头一两次可能没反应，再点一下即可。

**Q：网页版编辑器（code-server）识别不了？**
确保你用的是 Chrome / Safari / Edge / Arc 之一。识别靠的是网页控件特征，与具体网址无关，所以动态域名也没问题。

**Q：快捷键 `⌃⌥⌘K` 没反应？**
可能与其他软件冲突。当前快捷键写在 `Sources/HotkeyManager.swift` 里，可自行修改 keyCode/modifiers 后重新编译。

**Q：想开机自启？**
菜单里有「开机自动启动」开关，首次运行会自动开启。

## 工作原理（简述）

- `NSWorkspace` 监听前台应用切换；`AXObserver` 监听焦点元素变化。
- 对 Chromium/Electron 应用（VSCode、Chrome、Edge）设置 `AXManualAccessibility` 唤醒其辅助功能树。
- 读取焦点元素的 `AXRole / AXDOMClassList / AXDescription`、祖先链上的 `AXWebArea` 标题与 URL、窗口标题，组成上下文。
- 针对 Chromium 焦点切换瞬间的"脏帧"，采用**双帧确认 + 轮询兜底**保证稳定。
- 用 Carbon 的 `TISSelectInputSource` 执行切换。

## 系统要求

- macOS 12.0+
- Apple Silicon 或 Intel（自行编译则自动适配本机架构；Release 提供 universal binary）

## License

[MIT](LICENSE)
