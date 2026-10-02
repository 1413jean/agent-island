#!/bin/zsh
# 下載固定版本的 Sparkle（自動更新框架）到 vendor/Sparkle（不放進 git）。bundle.sh 和 release.sh 會自動呼叫。
# 換版本時改下面兩行：版本號和 tar.xz 的 SHA-256（GitHub Release 頁面下載後用 shasum -a 256 算）。
set -e
cd "$(dirname "$0")/.."
VER=2.10.0
SHA=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
DIR=vendor/Sparkle
[ -f "$DIR/.version" ] && [ "$(cat "$DIR/.version")" = "$VER" ] && exit 0
echo "下載 Sparkle $VER…"
TMP=$(mktemp -d)
curl -sSL -o "$TMP/sparkle.tar.xz" "https://github.com/sparkle-project/Sparkle/releases/download/$VER/Sparkle-$VER.tar.xz"
echo "$SHA  $TMP/sparkle.tar.xz" | shasum -a 256 -c - >/dev/null || { echo "Sparkle 檔案的 SHA-256 對不上，停止"; exit 1; }
rm -rf "$DIR"; mkdir -p "$DIR"
tar -xf "$TMP/sparkle.tar.xz" -C "$DIR" Sparkle.framework bin LICENSE
echo "$VER" > "$DIR/.version"
rm -rf "$TMP"
