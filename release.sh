#!/bin/bash
# 打包发布版：编译 universal binary（Intel + Apple Silicon），生成可分发的 .app 和 .zip。
# 产物在 dist/ 目录。用于 GitHub Release。
set -e

PROJ_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="InputSwitcher"
DIST="$PROJ_DIR/dist"
APP="$DIST/$APP_NAME.app"
MACOS_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"

echo "▶ 清理旧产物 ..."
rm -rf "$DIST"
mkdir -p "$MACOS_DIR" "$RES_DIR"

echo "▶ 复制 Info.plist ..."
cp "$PROJ_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"

echo "▶ 编译 universal binary（arm64 + x86_64）..."
swiftc \
    "$PROJ_DIR"/Sources/*.swift \
    -o "$MACOS_DIR/$APP_NAME" \
    -framework Cocoa \
    -framework ApplicationServices \
    -framework Carbon \
    -target arm64-apple-macos12.0 \
    -O &
PID_ARM=$!

swiftc \
    "$PROJ_DIR"/Sources/*.swift \
    -o "$MACOS_DIR/${APP_NAME}_x86" \
    -framework Cocoa \
    -framework ApplicationServices \
    -framework Carbon \
    -target x86_64-apple-macos12.0 \
    -O || echo "（x86_64 编译失败，可能缺少对应 SDK，将只发布 arm64）"

wait $PID_ARM

# 合并成 universal
if [ -f "$MACOS_DIR/${APP_NAME}_x86" ]; then
    lipo -create -output "$MACOS_DIR/$APP_NAME.universal" \
        "$MACOS_DIR/$APP_NAME" "$MACOS_DIR/${APP_NAME}_x86"
    mv "$MACOS_DIR/$APP_NAME.universal" "$MACOS_DIR/$APP_NAME"
    rm -f "$MACOS_DIR/${APP_NAME}_x86"
    echo "✅ 已生成 universal binary"
else
    echo "⚠️  仅 arm64（Apple Silicon）"
fi

echo "▶ ad-hoc 签名 ..."
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "（codesign 跳过）"

echo "▶ 打包 zip ..."
cd "$DIST"
zip -r -q "$APP_NAME.zip" "$APP_NAME.app"

echo ""
echo "✅ 完成！发布产物："
echo "   $APP"
echo "   $DIST/$APP_NAME.zip   ← 上传到 GitHub Release"
echo ""
echo "架构信息："
lipo -info "$MACOS_DIR/$APP_NAME"
