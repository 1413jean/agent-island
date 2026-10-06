# Changelog / 變更紀錄

## 1.0.3 — 2026-10-06

- The MIT license now ships inside the app: Settings → About shows what you can do with Agent Island, and **View licenses…** opens the full text, followed by the licenses of the open-source components it uses.
  app 裡也附上 MIT 授權：設定 →「關於」寫出可以拿 Agent Island 做什麼，按「**查看授權…**」可以看全文，後面接著用到的開源元件授權。

## 1.0.2 — 2026-10-06

- **License:** Agent Island is now [MIT licensed](LICENSE): you can use it for free, modify it, share it and use it commercially, as long as you keep the copyright and license notice.
  **授權：** Agent Island 採用 [MIT 授權](LICENSE)：可以免費使用、修改、分享，也可以用在商業用途，只要保留版權和授權聲明。
- **Hover:** in "On hover" mode, the island now waits for a short pause (0.15 s) before expanding, so brushing past the notch no longer opens it. A quick open-and-close no longer bounces twice.
  **滑鼠靠近：** 「滑鼠靠近」模式要停一下（0.15 秒）才展開，只是擦過不會打開；剛展開就收時不會再連彈兩次。
- README: added who it's for, plus how to update, uninstall and report issues.
  README：補上適合誰用，以及更新、移除與回報問題的方法。

## 1.0.1 — 2026-10-03

- **Updates now use [Sparkle](https://sparkle-project.org):** checks every hour; when a new version is out, an Update button appears at the top of Settings and in the menu. Every update is signed, and one with a mismatched signature won't install.
  **自動更新改用 Sparkle：** 每小時檢查一次，有新版時設定視窗最上面和選單裡會出現更新按鈕；每個更新都有簽名，簽名對不上的不會安裝。
- Done notifications are now sent by Agent Island itself, so they work on macOS 14+ and Intel Macs.
  完成通知改由 Agent Island 自己發，macOS 14 以上、Intel 的 Mac 都收得到。
- The tagline now covers any AI agent, not just Claude Code.
  標語改成不限 Claude Code。

## 1.0.0 — 2026-09-30

First public release. / 第一個公開版本。

- Shows what Claude Code and Codex are doing in the MacBook notch: thinking, reading, editing, running commands, done, paused, usage limits and errors, with a pixel cat acting out each state.
  在 MacBook 瀏海顯示 Claude Code 和 Codex 正在做什麼：想事情、讀檔、改檔、跑指令、完成、暫停、額度用完和各種錯誤，底下有一隻點陣貓跟著狀態動。
- One-click Connect for Claude Code (backs up `settings.json` first); Codex works with no setup.
  Claude Code 一鍵連接（會先備份 `settings.json`）；Codex 不用設定。
- Multiple sessions, multiple displays, moves aside on hover, Chinese / English UI.
  支援多個任務、多螢幕、滑鼠經過時讓開、中英文介面。
- Apple silicon and Intel, macOS 14+.
  支援 M 系列和 Intel，macOS 14 以上。
