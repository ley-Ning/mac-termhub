#!/bin/zsh
# 组装 TermHub.app：SwiftPM 产物 + Info.plist -> .app bundle + ad-hoc 签名
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP_NAME="TermHub"
BUNDLE_ID="com.termhub.app"
BUILD_DIR=".build"
APP_DIR="build/${APP_NAME}.app"

echo "==> swift build (${CONFIG})"
swift build -c "$CONFIG" --skip-update

BIN="${BUILD_DIR}/${CONFIG}/${APP_NAME}"
[[ -f "$BIN" ]] || { echo "二进制不存在：$BIN"; exit 1; }

echo "==> 组装 ${APP_DIR}"
rm -rf "$APP_DIR"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"
cp "$BIN" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp App/Info.plist "${APP_DIR}/Contents/Info.plist"

# 资源目录（编译后的 asset catalog 若存在）
if [[ -d "${BUILD_DIR}/${CONFIG}/TermHub.resources" ]]; then
  cp -R "${BUILD_DIR}/${CONFIG}/TermHub.resources/." "${APP_DIR}/Contents/Resources/"
fi

echo "==> ad-hoc 签名"
codesign --force --sign - "$APP_DIR"

echo "==> 完成：${APP_DIR}"
