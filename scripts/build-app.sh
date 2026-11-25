#!/bin/bash
# 构建 NetTick.app（只出本机架构）。
#
#   ./scripts/build-app.sh             # 版本号取最近的 git tag，没有就 0.1.0；NETTICK_VERSION=x.y.z 可指定
#   ./scripts/build-app.sh --install   # 构建后替换 /Applications/NetTick.app 并启动
#   ./scripts/build-app.sh --dmg       # 另打 DMG（发版用，见 scripts/release.sh）
#
# 产物：build/NetTick.app，加 --dmg 时还有 build/NetTick-<版本>-<架构>.dmg
# （DMG 的名字是和 App 里自动更新的约定：按名字里的架构找包，改名 = 已装的版本找不到更新）
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

VERSION="${NETTICK_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
ARCH="$(uname -m)"
APP="$ROOT/build/NetTick.app"

# 开头清干净：cp -R 到已存在的目录是「拷进去」不是「替换」，会把新 app 嵌进旧 app（PasteMemo 踩过）
rm -rf "$ROOT/build"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 固定的本机证书：通知、登录项这些按签名认 App，ad-hoc 签名每次构建都像换了个 App
DEV_CERT="NetTick Dev"
if security find-identity -p codesigning 2>/dev/null | grep -q "$DEV_CERT"; then
    SIGN_ID="$DEV_CERT"
else
    SIGN_ID="-"
    echo "▸ 没找到证书「${DEV_CERT}」，先用 ad-hoc 签名（跑 scripts/setup-dev-cert.sh 生成）"
fi

[ -f assets/NetTick.icns ] || ./scripts/make-icon.sh

# SDK 版本必须显式喂给链接器（TabFlick 2026-09-15 踩）：否则 LC_BUILD_VERSION 的 sdk
# 退成部署目标 14.0，整个 app 拿不到 macOS 26+ 的外观，编译签名全程不报错。
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
SWIFT_SDK_FLAGS=(-Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$SDK_PATH")

echo "▸ 编译（${ARCH}）…"
# 产物路径向 SwiftPM 要，不写死（Xcode 27 起老路径还在但不再更新，写死会拷到旧产物）
BIN_DIR="$(swift build -c release --arch "$ARCH" "${SWIFT_SDK_FLAGS[@]}" --show-bin-path | tail -1)"
rm -f "$BIN_DIR/NetTick"
swift build -c release --arch "$ARCH" "${SWIFT_SDK_FLAGS[@]}"
[ -f "$BIN_DIR/NetTick" ] || { echo "✗ 找不到产物：$BIN_DIR/NetTick"; exit 1; }
STALE="$(find Sources -name '*.swift' -newer "$BIN_DIR/NetTick" -print -quit)"
[ -z "$STALE" ] || { echo "✗ 源码比产物新（${STALE}），构建没生效"; exit 1; }
LINKED_SDK="$(otool -l "$BIN_DIR/NetTick" | awk '/LC_BUILD_VERSION/{f=1} f&&/sdk/{print $2; exit}')"
[ "${LINKED_SDK%%.*}" -ge 26 ] 2>/dev/null || { echo "✗ 产物链接的 SDK 是 ${LINKED_SDK:-未知}，不是本机 SDK"; exit 1; }

echo "▸ 组装 bundle…"
cp "$BIN_DIR/NetTick" "$APP/Contents/MacOS/NetTick"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" packaging/Info.plist > "$APP/Contents/Info.plist"
cp assets/NetTick.icns "$APP/Contents/Resources/NetTick.icns"
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do cp -R "$bundle" "$APP/Contents/Resources/"; done
shopt -u nullglob

codesign --force --deep --sign "$SIGN_ID" "$APP"
codesign --verify --strict "$APP" && echo "  签名校验通过（${SIGN_ID}）"

if [[ " $* " == *" --dmg "* ]]; then
    echo "▸ 打包 DMG…"
    DMG="$ROOT/build/NetTick-$VERSION-$ARCH.dmg"
    STAGE="$ROOT/build/dmg-stage"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"
    ditto "$APP" "$STAGE/NetTick.app"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "NetTick $VERSION" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
    rm -rf "$STAGE"
    echo "  ${DMG}（$(du -h "$DMG" | cut -f1)）"
fi

if [[ " $* " == *" --install "* ]]; then
    echo "▸ 安装到 /Applications…"
    RUNNING="$(pgrep -f "/Applications/NetTick.app/Contents/MacOS/NetTick" || true)"
    if [ -n "$RUNNING" ]; then
        osascript -e 'tell application "NetTick" to quit' 2>/dev/null || true
        for _ in $(seq 1 20); do pgrep -f "/Applications/NetTick.app/Contents/MacOS/NetTick" >/dev/null || break; sleep 0.25; done
        # 只对刚才那个 PID 发 SIGTERM，不按名字批量杀
        for pid in $RUNNING; do kill "$pid" 2>/dev/null || true; done
        sleep 0.5
    fi
    rm -rf /Applications/NetTick.app
    cp -R "$APP" /Applications/NetTick.app
    xattr -dr com.apple.quarantine /Applications/NetTick.app 2>/dev/null || true
    open -a /Applications/NetTick.app
    echo "  已安装并启动：/Applications/NetTick.app"
fi
echo "✅ ${APP}（${VERSION}，build ${BUILD_NUMBER}）"
