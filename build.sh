#!/bin/bash
# 一键编译 InputSwitcher 成 .app 并（可选）重启。
# 固定输出路径，保证辅助功能授权一次长期有效。
set -e

PROJ_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="InputSwitcher"
# 固定安装到 ~/Applications，路径稳定 => 授权不失效
OUT_DIR="$HOME/Applications"
APP="$OUT_DIR/$APP_NAME.app"
MACOS_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"

echo "▶ 编译 $APP_NAME ..."

# 1) 关掉已在运行的旧实例
pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true
sleep 0.3

# 2) 建 .app 骨架
mkdir -p "$MACOS_DIR" "$RES_DIR"
cp "$PROJ_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"

# 3) 编译所有 Swift 源文件
swiftc \
    "$PROJ_DIR"/Sources/*.swift \
    -o "$MACOS_DIR/$APP_NAME" \
    -framework Cocoa \
    -framework ApplicationServices \
    -framework Carbon \
    -O

echo "✅ 编译完成 -> $APP"

# 4) 代码签名（ad-hoc），让辅助功能权限按 bundle 稳定记忆
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "（codesign 跳过）"

# 5) 启动
if [ "$1" != "--no-run" ]; then
    echo "▶ 启动 ..."
    open "$APP"
    echo "若首次运行，请在『系统设置→隐私与安全性→辅助功能』勾选 InputSwitcher，然后重新运行本脚本。"
fi
