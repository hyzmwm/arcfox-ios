#!/usr/bin/env bash
# 极狐车况小组件 iOS 版 · 一键推送到 GitHub 触发云编译
# 用法：bash push_github.sh <GitHub用户名> <Personal_Access_Token> [仓库名(默认 arcfox-ios)]
set -euo pipefail
cd "$(dirname "$0")"

USER="${1:?用法: bash push_github.sh <用户名> <token> [仓库名]}"
TOKEN="${2:?缺少 token（GitHub 设置 → Developer settings → Personal access tokens，勾选 repo 权限）}"
REPO="${3:-arcfox-ios}"

git remote remove origin 2>/dev/null || true

# 建仓库（私有）
HTTP=$(curl -s -o create_repo.json -w "%{http_code}" -X POST \
  -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
  https://api.github.com/user/repos -d "{\"name\":\"$REPO\",\"private\":true}")
if [ "$HTTP" != "201" ]; then
  cat create_repo.json
  echo "建仓库失败（HTTP $HTTP）。若仓库已存在可忽略，直接继续推送。"
fi

git remote add origin "https://x-access-token:$TOKEN@github.com/$USER/$REPO.git"
git push -u origin main
echo
echo "已推送。云编译地址: https://github.com/$USER/$REPO/actions"
echo "编译完成（约 6-10 分钟）后，在 Actions 页面下载 artifact「ArcfoxWidget-v3.0-ios-ipa」"
echo "或用: curl -H \"Authorization: Bearer $TOKEN\" -L https://api.github.com/repos/$USER/$REPO/actions/artifacts -o artifacts.json"
