#!/bin/zsh
# 一键热更新本地 TermHub：拉最新代码 → 稳定签名打包 → 替换运行中的 App → 重启
# 用法：./scripts/update-local.sh [--check-only]
#   --check-only 只报告远端是否有新提交，不做任何变更
set -uo pipefail

REPO="$HOME/WorkBuddy/TermHub"
APP_SRC="$REPO/build/TermHub.app"
APP_DST="/Applications/TermHub.app"
export https_proxy="${https_proxy:-http://127.0.0.1:7897}"

cd "$REPO" || { echo "❌ 仓库不存在：$REPO"; exit 1; }

echo "==> 检查远端更新（origin/main）"
git fetch origin main --quiet 2>/dev/null || { echo "⚠️ 无法访问远端（代理 ${https_proxy}）"; exit 2; }
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main)
if [[ "$1" == "--check-only" ]]; then
  if [[ "$LOCAL" == "$REMOTE" ]]; then
    echo "UP_TO_DATE $LOCAL"
  else
    echo "UPDATE_AVAILABLE $(git log --oneline HEAD..origin/main | wc -l | tr -d ' ') 个新提交"
    git log --oneline HEAD..origin/main | head -5
  fi
  exit 0
fi

if [[ "$LOCAL" == "$REMOTE" ]]; then
  echo "✅ 已是最新（$LOCAL）"
  NEED_REBUILD=0
else
  echo "==> 拉取 $(git log --oneline HEAD..origin/main | wc -l | tr -d ' ') 个新提交"
  git pull --ff-only origin main --quiet || { echo "❌ 拉取失败（本地有未提交改动？）"; exit 3; }
  NEED_REBUILD=1
fi

# 本地源码有未打包改动时也重建（比较 App mtime 与最新源文件 mtime 太脆，直接始终重建）
echo "==> 重新打包（稳定签名）"
if ! ./scripts/build-app.sh release; then
  echo "❌ 打包失败"
  exit 4
fi

echo "==> 退出运行中的 TermHub"
osascript -e 'tell application "TermHub" to quit' 2>/dev/null
sleep 2

# 装到 /Applications（若用户从那里跑）；否则直接跑 build 里的
if [[ -d "$APP_DST" ]]; then
  echo "==> 替换 $APP_DST"
  rm -rf "$APP_DST" && cp -R "$APP_SRC" "$APP_DST"
  open "$APP_DST"
else
  open "$APP_SRC"
fi
echo "✅ 热更新完成，TermHub 已重启（$(git log -1 --format='%h %s')）"
