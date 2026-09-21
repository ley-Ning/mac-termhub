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

# 稳定签名身份：自签名 "TermHub Dev"（导入登录钥匙串后长期不变）。
# ad-hoc 签名每次编译都变，macOS 钥匙串 ACL 跟着签名走，会导致每次读密码都弹系统密码框；
# 稳定身份下"始终允许"一次即永久生效。
# TERMHUB_SIGN=adhoc 可跳过稳定签名（钥匙串锁定时 codesign 取私钥会无限挂起，用此开关快速出包）。
if [[ "${TERMHUB_SIGN:-}" == "adhoc" ]]; then
  echo "==> ad-hoc 签名（TERMHUB_SIGN=adhoc 快速模式；钥匙串解锁后去掉该变量恢复稳定签名）"
  codesign --force --sign - "$APP_DIR"
else
  IDENTITY="$(security find-identity 2>/dev/null | grep -o 'TermHub Dev' | head -1 || true)"
sign_with_identity() {
  codesign --force --sign "$IDENTITY" "$1" 2>/dev/null
}
if [[ -n "$IDENTITY" ]] && sign_with_identity "$APP_DIR"; then
  echo "==> codesign（稳定身份：$IDENTITY）"
  # MCP / 冒烟二进制也读钥匙串，同样用稳定身份（存在才签）
  for bin in TermHubMCP TermHubSmoke; do
    if [[ -f "${BUILD_DIR}/release/${bin}" ]]; then
      sign_with_identity "${BUILD_DIR}/release/${bin}" || true
    fi
  done
else
  echo "==> ad-hoc 签名（稳定身份不可用：钥匙串可能已锁，解锁登录钥匙串后自动恢复）"
  codesign --force --sign - "$APP_DIR"
fi
fi

echo "==> 完成：${APP_DIR}"
