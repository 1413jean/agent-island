#!/bin/zsh
# 編譯小島，裝到 ~/Applications/Agent Island.app，然後重新打開（開發用）。
# 開機自動啟動用 macOS 的「登入項目」（app 設定 → 一般），不用 LaunchAgent。
set -e
cd "$(dirname "$0")"

APP=~/Applications/"Agent Island.app"
DEV=1 ./scripts/bundle.sh build/"Agent Island.app"   # 測試版：有示範模式，不自動更新

# 開發時的 hook 捷徑指回 repo（舊的連接方式；新的連接指向 app 內建的 hook，見 設定 → Claude Code）
mkdir -p ~/.claude/tools
ln -sf "$PWD/hook/island_hook.py" ~/.claude/tools/island_hook.py

# 舊版是 LaunchAgent 常駐（關掉會被自動拉起來），換成一般 app 後把它移除
OLD=~/Library/LaunchAgents/com.jean.claudeisland.plist
if [ -f "$OLD" ]; then
  launchctl unload "$OLD" 2>/dev/null || true
  rm -f "$OLD"
fi

# 關掉執行中的舊版（只認這個 app 的執行檔名稱），換上新的、重新打開
pkill -x AgentIsland 2>/dev/null || true
pkill -x ClaudeIsland 2>/dev/null || true          # 改名前的舊名字
sleep 0.5
mkdir -p ~/Applications
rm -rf "$APP"
ditto build/"Agent Island.app" "$APP"
touch "$APP"                       # 讓 Finder／Dock 重新讀圖示
open "$APP"
echo "Agent Island 已更新並重新打開"
