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

# 应用图标（独立于 SwiftPM 资源，配合 Info.plist 的 CFBundleIconFile）
cp App/Resources/Icon.icns "${APP_DIR}/Contents/Resources/Icon.icns"
# 多语言资源（key=中文原文的英文映射表；zh-Hans 为开发语言占位）
cp -R App/Resources/en.lproj App/Resources/zh-Hans.lproj "${APP_DIR}/Contents/Resources/" 2>/dev/null || true

# 普通构建不查询登录钥匙串，也不要求 macOS 密码。发布者如需证书签名，
# 须主动提供 TERMHUB_SIGN_IDENTITY；证书/私钥的访问仅属于该显式发布操作。
if [[ -n "${TERMHUB_SIGN_IDENTITY:-}" ]]; then
  echo "==> 使用显式指定的发布签名身份"
  codesign --force --sign "$TERMHUB_SIGN_IDENTITY" "$APP_DIR"
else
  echo "==> ad-hoc 签名（无需访问登录钥匙串）"
  codesign --force --sign - "$APP_DIR"
fi

echo "==> 完成：${APP_DIR}"
