#!/bin/bash
# 发一版：构建 DMG → 验包 → 打 tag → 推 main 和 tag → 建 GitHub Release。
# App 里的自动更新从 Release 的最新一版取包（UpdateChecker.repo）。
#
#   ./scripts/release.sh 0.2.0              # 更新说明用上一个 tag 以来的提交标题
#   ./scripts/release.sh 0.2.0 notes.md     # 用指定文件当更新说明
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?用法：scripts/release.sh <x.y.z> [更新说明文件]}"
NOTES_FILE="${2:-}"
TAG="v$VERSION"
REPO="lifedever/NetTick"   # 和 Sources/NetTick/UpdateChecker.swift 里的 repo 一致
CERT="NetTick Dev"
fail() { echo "✗ $*"; exit 1; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "版本号要写成 x.y.z"
[ "$(git branch --show-current)" = main ] || fail "不在 main 分支"
[ -z "$(git status --porcelain)" ] || fail "有没提交的改动"
git remote get-url origin >/dev/null 2>&1 || fail "没有 origin 远端"
! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || fail "tag $TAG 已经有了"
PREV="$(git describe --tags --abbrev=0 2>/dev/null || true)"
if [ -n "$PREV" ]; then
    [ "$(printf '%s\n%s\n' "${PREV#v}" "$VERSION" | sort -V | tail -1)" = "$VERSION" ] && [ "${PREV#v}" != "$VERSION" ] \
        || fail "$VERSION 不比上一版 ${PREV} 新"
fi
# ad-hoc 签的包对不上已装版本的签名，App 里的更新会拒装；通知、登录项也会把它当成另一个 App
IDENTITIES="$(security find-identity -p codesigning 2>/dev/null || true)"
grep -q "$CERT" <<< "$IDENTITIES" || fail "本机没有证书「${CERT}」（scripts/setup-dev-cert.sh）"
[ -z "$NOTES_FILE" ] || [ -f "$NOTES_FILE" ] || fail "找不到更新说明文件 $NOTES_FILE"

NETTICK_VERSION="$VERSION" ./scripts/build-app.sh --dmg

APP="$PWD/build/NetTick.app"
DMG="$PWD/build/NetTick-$VERSION-$(uname -m).dmg"
echo "▸ 验包…"
[ -f "$DMG" ] || fail "没有 $DMG"
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$VERSION" ] || fail "包里的版本号不是 $VERSION"
# 先存下来再 grep：管道里 grep -q 一匹配就退出，codesign 收到 SIGPIPE，pipefail 下整条判失败（0.2.0 发版时踩过）
SIGNINFO="$(codesign -dvv "$APP" 2>&1)"
grep -q "Authority=$CERT" <<< "$SIGNINFO" || fail "包不是用「${CERT}」签的"
ATTACH="$(hdiutil attach "$DMG" -nobrowse -noverify)"
MNT="$(grep -m1 -o '/Volumes/.*' <<< "$ATTACH")"
OK=1
[ -d "$MNT/NetTick.app" ] || OK=0
[ -e "$MNT/NetTick.app/Contents/NetTick.app" ] && OK=0   # 嵌套 .app（cp -R 拷进已存在目录）
codesign --verify --strict "$MNT/NetTick.app" 2>/dev/null || OK=0
hdiutil detach "$MNT" -quiet
[ "$OK" = 1 ] || fail "DMG 里的 NetTick.app 不对"
echo "  ${VERSION}，$(uname -m)，签名 ${CERT}，DMG 正常"

NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT
if [ -n "$NOTES_FILE" ]; then
    cp "$NOTES_FILE" "$NOTES"
else
    git log --format='- %s' ${PREV:+"$PREV"..HEAD} > "$NOTES"
fi

echo "▸ 打 tag ${TAG}，推送，建 Release…"
git tag -a "$TAG" -m "$TAG"
git push origin main
git push origin "$TAG"
gh release create "$TAG" "$DMG" --repo "$REPO" --title "$TAG" --notes-file "$NOTES"
echo "✅ 已发布 https://github.com/$REPO/releases/tag/$TAG"
