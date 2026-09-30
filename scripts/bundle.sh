#!/bin/zsh
# 把整個 app 打包到指定位置：./scripts/bundle.sh "<路徑>/Agent Island.app"
# build.sh（裝到自己電腦）和 release.sh（發佈到 GitHub）都用這個。
set -e
cd "$(dirname "$0")/.."
APP="$1"
[ -z "$APP" ] && { echo "用法：scripts/bundle.sh <app 路徑>"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# 指定最低支援 macOS 14：不指定的話會用 SDK 的版本（比系統還新），系統會拒絕打開
# UNIVERSAL=1（release.sh 用）：同時編譯 M 系列和 Intel 兩種晶片，合成一個執行檔；平常開發只編 M 系列，比較快
# DEV=1（build.sh 用）：測試版，多了示範模式和測試用的啟動參數；release.sh 不加，發佈的是正式版
FLAGS=()
[ "$DEV" = "1" ] && FLAGS=(-D DEV)
if [ "$UNIVERSAL" = "1" ]; then
  TMP=$(mktemp -d)
  swiftc -O $FLAGS -target arm64-apple-macos14.0 Sources/*.swift -o "$TMP/arm64"
  swiftc -O $FLAGS -target x86_64-apple-macos14.0 Sources/*.swift -o "$TMP/x86_64"
  lipo -create "$TMP/arm64" "$TMP/x86_64" -output "$APP/Contents/MacOS/AgentIsland"
  rm -rf "$TMP"
else
  swiftc -O $FLAGS -target arm64-apple-macos14.0 Sources/*.swift -o "$APP/Contents/MacOS/AgentIsland"
fi
cp app/Info.plist "$APP/Contents/Info.plist"
cp app/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"   # 第三方授權（設定 → 關於 裡看得到）
# hook 程式、音效都打包進 app（系統通知由 app 自己發），別人裝好 app 就能用，不需要這個 repo
ditto hook "$APP/Contents/Resources/hook"
ditto sounds "$APP/Contents/Resources/sounds"
find "$APP/Contents/Resources/hook" -name "__pycache__" -prune -exec rm -rf {} +
# 內部版號：跟著 git 的提交次數往上加（對外的版本號在 app/Info.plist，發佈時由 release.sh 改）
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD)" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1
