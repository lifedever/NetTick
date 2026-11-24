#!/bin/bash
# 把 index.html 里的每个样张截成 png/<id>.png（2x）：bash render.sh
set -euo pipefail
cd "$(dirname "$0")"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
mkdir -p png
shot() {  # shot <id> <宽> <高>
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
        --window-size="$2,$3" --screenshot="$PWD/png/$1.png" \
        "file://$PWD/index.html?frame=$1" >/dev/null 2>&1
    echo "  png/$1.png"
}
shot menubar 1100 310
shot popover-light 560 600
shot popover-dark 560 600
for id in rank rank-dark curve month settings; do shot "$id" 1240 760; done
shot notify 560 170
