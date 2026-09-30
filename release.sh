#!/bin/zsh
# 發佈新版到 GitHub Releases：./release.sh 1.1.0 "這版改了什麼"
# 會改 app/Info.plist 的版本號並 commit、打包成 zip、打 tag、上傳。已經裝好的 app 會自動發現新版。
# 需要：gh（GitHub CLI）已登入；repo 要是公開的，別人的 app 才讀得到新版資訊。
set -e
cd "$(dirname "$0")"
VER="$1"
NOTES="${2:-Agent Island $1}"
[ -z "$VER" ] && { echo "用法：./release.sh <版本號，例如 1.1.0> [這版的說明]"; exit 1; }
git diff --quiet && git diff --cached --quiet || { echo "還有沒 commit 的修改，先 commit 再發佈"; exit 1; }

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VER" app/Info.plist
git diff --quiet || git commit -qam "Version $VER / 版本 $VER"   # 版本號已經是這版就不用另外 commit
UNIVERSAL=1 ./scripts/bundle.sh dist/"Agent Island.app"   # M 系列＋Intel 都能用
ZIP="dist/Agent-Island-$VER.zip"
rm -f "$ZIP"
ditto -c -k --keepParent dist/"Agent Island.app" "$ZIP"
git tag "v$VER"
git push -q
git push -q origin "v$VER"
gh release create "v$VER" "$ZIP" --title "Agent Island $VER" --notes "$NOTES"
echo "已發佈 $VER：$(gh release view "v$VER" --json url -q .url)"
