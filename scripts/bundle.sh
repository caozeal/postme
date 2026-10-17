#!/usr/bin/env bash
# 把 SwiftPM 的 release 产物组装成行为正确的 .app 并做 ad-hoc 签名。
# 关键顺序:先放好所有文件(含 Info.plist),最后一步再签名——之后任何改动都会使签名失效。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="postme"
CONFIG="${CONFIG:-release}"
BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"
EXECUTABLE="$BIN_PATH/$APP_NAME"
if [[ ! -f "$EXECUTABLE" ]]; then
    echo "错误:未找到可执行文件 $EXECUTABLE" >&2
    exit 1
fi

echo "==> 重组 $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$EXECUTABLE" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

# 应用图标(由 scripts/render_icon.swift + iconutil 生成,已入库)
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# v1 无资源;若将来 SwiftPM 生成资源包,一并拷入,避免运行时找不到 Bundle.module
if compgen -G "$BIN_PATH/${APP_NAME}_*.bundle" > /dev/null; then
    cp -R "$BIN_PATH"/${APP_NAME}_*.bundle "$APP_DIR/Contents/Resources/"
fi

echo "==> ad-hoc 签名"
codesign --force --sign - --timestamp=none "$APP_DIR"

echo "==> 完成:$APP_DIR"
codesign --verify --verbose=2 "$APP_DIR" 2>&1 | tail -1
