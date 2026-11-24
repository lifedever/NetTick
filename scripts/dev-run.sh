#!/bin/bash
# 开发时代替裸的 `swift run`：带上让链接器写对 SDK 版本的参数（原因见 build-app.sh 的 SWIFT_SDK_FLAGS）。
set -euo pipefail
cd "$(dirname "$0")/.."
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
exec swift run -Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$SDK_PATH" "$@"
