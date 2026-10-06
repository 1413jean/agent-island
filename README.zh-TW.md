# Agent Island

[English](README.md) ｜ **繁體中文**

**版本 1.0.3** · macOS 14 以上 · M 系列與 Intel · [MIT 授權](LICENSE) · [變更紀錄](CHANGELOG.md)

<p align="center"><img src="docs/demo.gif" width="460" alt="Agent Island：從瀏海長出來的狀態小島，依序顯示 Thinking、Reading file、Editing file、Running command、Done"></p>

你的 AI Agent（Claude Code、Codex）在做什麼，MacBook 瀏海上一眼就知道。

平常縮成瀏海大小、看不出來；Claude Code 開始工作時從瀏海長開，顯示它正在讀的檔案、跑的指令、這輪產生的 token 數，底下還有一隻點陣貓跟著狀態做動作；完成後縮回瀏海。

## 適合誰用

| 你的狀況 | Agent Island 可以幫你 |
| --- | --- |
| 下完 prompt 就切去做別的事 | 瀏海上一眼看出它還在想、在讀檔、在改檔，還是在跑指令 |
| 同時開好幾個任務 | 在瀏海上滑動切換，不用一個個視窗找 |
| 常常沒發現任務已經做完 | 完成時有動畫、音效和通知，點通知直接回到那個 Terminal 分頁 |
| 遇到額度用完、登入失效或斷線 | 直接看到原因和該怎麼做，不用回終端機翻 |

它只負責顯示狀態，不會自己執行指令、改你的程式，也不會自己呼叫 AI。

## 安裝

1. 到 [Releases](https://github.com/1413jean/agent-island/releases) 下載最新的 `Agent-Island-x.y.z.zip`，解壓後把 **Agent Island.app** 拖進「應用程式」。
2. 第一次打開：在 app 上按右鍵 →「打開」→ 再按一次「打開」（app 沒有經過 Apple 公證，第一次會跳出「無法驗證開發者」的提醒，之後就不會了）。
3. app 會自動打開設定的「連接」頁，按「**連接…**」。已經開著的 Claude Code 重新開一次就會開始顯示。

需要 macOS 14 以上，M 系列和 Intel 的 Mac 都可以。hook 用 macOS 的 `python3` 執行（裝過 git 的 Mac 都已經有；沒有的話，第一次用時系統會請你安裝「命令列開發工具」）。

每小時會自動檢查一次更新（用 [Sparkle](https://sparkle-project.org)）。有新版時，設定視窗最上面和選單裡會出現「**更新**」按鈕，按了可以看更新內容並安裝，裝好會自己重新打開。每個更新都有簽名，簽名對不上的不會安裝。設定 →「關於」可以關掉自動檢查。

## 小島上會看到什麼

| 狀態 | 什麼時候 | 貓咪在做什麼 |
| --- | --- | --- |
| Thinking | 送出問題後、工具之間 | 坐著想事情，頭旁邊冒「…」 |
| Reading / Searching | Read、Grep、Glob、WebFetch | 慢慢散步 |
| Editing / Writing | Edit、Write、Agent | 撥毛線球 |
| Running command | Bash | 全速奔跑，背景跟著捲動 |
| Done | 回覆完成 | 開心蹦兩下，坐下冒愛心 |
| Paused | 按 Esc 中斷，或送出後馬上取消（幾秒沒動靜會自己判斷） | 伸懶腰 |
| Usage limit reached | 額度用完，顯示重置時間 | 攤平在地上 |
| Login required / Connection lost… | 登入失效、斷線等 API 錯誤，顯示原因和該怎麼做 | 嚇到弓背 |
| Stopped／Ready | session 結束／沒有任務 | 縮成一團睡覺 |

狀態字左邊的圖示有兩種風格：**光核**（立體點陣光球）和**像素格**（5×5 點陣動畫），顏色統一：工作中藍、閒置白、完成綠、出錯紅。

- **多個任務**：同時開好幾個 Claude Code session 時，滑鼠停在小島上用觸控板雙指左右滑切換。
- **右鍵**：在小島上按右鍵，收起目前這個任務。
- **滑鼠經過時讓開**：滑鼠移到展開的小島上，它會先縮回瀏海，讓你點得到下面的東西。
- **多螢幕**：滑鼠碰一下另一個螢幕的頂端，小島就搬過去。
- **Codex**：同時用 Codex 的話，它的任務也會顯示在小島上（讀 `~/.codex/sessions` 的紀錄，不用另外設定）。
- **完成通知與音效**：完成時發系統通知（點了回到那個 Terminal 分頁）並播音效，可以換音效。

## 設定

選單列的貓臉圖示 →「設定…」（⌘,）：

| 分頁 | 內容 |
| --- | --- |
| 一般 | 介面語言（自動／中文／English）、登入時自動啟動、顯示方式（自動／常駐／滑鼠靠近）、多螢幕、滑鼠經過時讓開、送出後沒動靜自動暫停、恢復預設外觀 |
| 連接 | Claude Code 連接／中斷連接；也顯示 Codex 的任務（讀 Codex 自己的工作紀錄，不用設定） |
| 通知 | 任務結束時彈出提醒、系統通知、完成音效 |
| 外觀 | 要顯示哪些內容（細節、狀態字、token 數，全關就是最小）、圖示風格、貓咪場景、底部漸層光、字級 |
| 尺寸與外框 | 寬度、留白、行距、內凹、圓角、彈跳 |
| 關於 | 版本、檢查更新、授權、結束 app |

選單列圖示 →「結束」（⌘Q）可以關掉；要再打開就從「應用程式」或 Spotlight 開。app 在跑的時候再打開一次，會直接跳出設定。

## 運作方式

```
Claude Code hook ──> island_hook.py（打包在 app 裡）──> ~/.claude/tools/island/sessions/<session_id>.json
                                                                        │
                                    Agent Island（每 0.15 秒讀一次）<──┘
```

- 「連接」會在 `~/.claude/settings.json` 的 `UserPromptSubmit`、`PreToolUse`、`PostToolUse`、`Stop`、`SessionEnd`、`Notification`（`idle_prompt`）各加一條 hook，只動自己的那幾條；寫入前會備份成 `settings.json.agent-island-backup`。
- 中斷、額度用完、API 錯誤、token 數由 app 直接讀 Claude Code 的逐字稿判斷。
- 外觀設定存在 `~/.claude/tools/island/tuning.json`。

## 隱私

- **不會把任何東西傳出去。** 小島只讀你電腦上的檔案：Claude Code 的 hook 寫的狀態檔、Claude Code 的逐字稿、Codex 的工作紀錄，全部在本機處理。
- **不花 token、不呼叫任何 AI。** 顯示的內容都是從上面那些檔案讀出來的。
- **唯一會連網的是檢查更新**：每小時讀一次 GitHub Releases 上公開的更新清單（`appcast.xml`），不送出任何資料，設定 →「關於」可以關掉。
- **會改動的檔案只有兩個**：你按「連接」時的 `~/.claude/settings.json`（只加小島自己的 hook，先備份），以及小島自己的設定 `~/.claude/tools/island/`。

## 更新、移除與回報問題

**更新：** Agent Island 每小時會檢查一次更新，有新版時按設定視窗最上面或選單裡的「**更新**」就好。也可以在設定 →「關於」手動檢查，或到 [Releases](https://github.com/1413jean/agent-island/releases) 下載 zip。每一版改了什麼見[變更紀錄](CHANGELOG.md)。

**移除：**

1. 設定 →「**連接**」→「**中斷連接**」（從 `~/.claude/settings.json` 拿掉小島的 hook，你其他的設定不會動）。
2. 設定 →「一般」→ 關掉「**登入時自動啟動**」，再從選單列圖示 →「**結束**」。
3. 把 **Agent Island.app** 丟到垃圾桶。
4. 想清乾淨的話，再刪掉 `~/.claude/tools/island/`（小島自己的設定和狀態檔）。

**回報問題：** 到 [Issues](https://github.com/1413jean/agent-island/issues) 開一則，附上 Agent Island 版本（設定 →「關於」）、macOS 版本、M 系列或 Intel、用的是 Claude Code 還是 Codex、你做了什麼，以及預期和實際看到的差別。公開的 issue 請不要貼私人對話、程式碼或檔案路徑。

## 開發

```sh
./build.sh                       # 測試版：編譯、裝到 ~/Applications、重新打開
./release.sh 1.1.0 "這版的說明"   # 改版本號、打包 zip、簽名、產生 appcast.xml、打 tag、上傳到 GitHub Releases
```

`build.sh` 裝的是**測試版**（有錄影用的示範模式、不自動更新）；`release.sh` 發佈的是大家下載的**正式版**。發佈的更新檔用 Sparkle 的 EdDSA 金鑰簽名，私鑰在發佈者的鑰匙圈（帳號 `agent-island`）；`scripts/fetch-sparkle.sh` 會把固定版本的 Sparkle 下載到 `vendor/`。`scripts/bundle.sh` 負責把程式、hook、音效包成 `.app`，上面兩個腳本都用它。

## 授權

Agent Island 採用 [MIT 授權](LICENSE)：可以免費使用、修改、分享，也可以用在商業用途，只要保留版權和授權聲明。

用到的開源元件和它們的授權聲明見 `THIRD_PARTY_NOTICES.md`（app 內：設定 →「關於」→「查看授權…」）。
