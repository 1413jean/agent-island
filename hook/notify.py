"""
任務完成時的系統通知與音效，由 island_hook.py 在 Stop 時呼叫。

通知的內文和小島顯示的「完成了什麼」是同一句，摘要只在 island_hook 算一次。
兩個功能各有開關，存在 tuning.json（小島設定面板裡切換）。

系統通知由 Agent Island 發：這裡在 notify/ 放一個小檔案（標題、內文、tty），app 讀到就發出去。
點通知跳回原本的 Terminal 分頁：抓這個 process 繼承來的 controlling tty（例如 ttys003），
app 點擊時用 AppleScript 在 Terminal 裡找 tty 相符的分頁切過去。背景任務沒有 controlling tty（ps 印 "??"），就不附加。

任何一步失敗都安靜跳過，不要因為通知壞掉而讓主流程卡住。
"""

import json
import os
import subprocess
import time

# hook/ 的上一層：在 repo 裡是 repo 根目錄，打包進 app 後是 Contents/Resources（裡面一樣有 sounds/）
REPO = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
TUNING = os.path.expanduser("~/.claude/tools/island/tuning.json")
NOTIFY_DIR = os.path.expanduser("~/.claude/tools/island/notify")
BODY_CHARS = 110
DEFAULT_SOUND = "zen-success"


def sound_path(name):
    """音效名稱 → 檔案。先找 repo 的 sounds/，再找 macOS 內建音效；都沒有就用預設。"""
    for p in (os.path.join(REPO, "sounds", name + ".mp3"),
              os.path.join("/System/Library/Sounds", name + ".aiff")):
        if os.path.exists(p):
            return p
    return os.path.join(REPO, "sounds", DEFAULT_SOUND + ".mp3")


def _english():
    """介面語言：跟 app 的設定一樣（auto 看系統語言）。"""
    try:
        with open(TUNING) as fh:
            lang = json.load(fh).get("language", "auto")
    except Exception:
        lang = "auto"
    if lang in ("zh", "en"):
        return lang == "en"
    try:
        out = subprocess.run(["defaults", "read", "-g", "AppleLanguages"], capture_output=True, text=True, timeout=3).stdout
        first = out.replace("(", "").replace('"', "").split(",")[0].strip()
        return not first.startswith("zh")
    except Exception:
        return True


def settings():
    """(系統通知開不開, 音效開不開, 音效檔)。設定檔讀不到時都用預設。"""
    try:
        with open(TUNING) as fh:
            t = json.load(fh)
    except Exception:
        t = {}
    return (t.get("systemNotify", True), t.get("completionSound", True),
            sound_path(t.get("sound", DEFAULT_SOUND)))


def controlling_tty():
    """這個 process 繼承的 controlling tty，例如 "ttys003"。沒有就回 None。"""
    try:
        out = subprocess.run(
            ["ps", "-o", "tty=", "-p", str(os.getpid())],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip()
    except Exception:
        return None
    return out if out and out != "??" else None


def finished(summary, title="Claude Code"):
    """任務完成：依設定發系統通知（交給 app）、播音效。"""
    notify_on, sound_on, sound = settings()

    if sound_on:
        try:
            subprocess.Popen(["afplay", sound], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass

    if not notify_on:
        return
    body = summary or ("Done" if _english() else "完成了")
    if len(body) > BODY_CHARS:
        body = body[: BODY_CHARS - 1].rstrip() + "…"
    req = {"title": title, "body": body, "tty": controlling_tty(), "ts": time.time()}
    try:
        os.makedirs(NOTIFY_DIR, exist_ok=True)
        tmp = os.path.join(NOTIFY_DIR, ".%d.tmp" % os.getpid())
        with open(tmp, "w") as fh:
            json.dump(req, fh, ensure_ascii=False)
        os.replace(tmp, os.path.join(NOTIFY_DIR, "%d-%d.json" % (time.time() * 1000, os.getpid())))
    except Exception:
        pass
