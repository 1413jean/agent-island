#!/usr/bin/env python3
"""
把 Claude Code 目前在做什麼寫成一個小 JSON 檔，給浮動小島 app 讀。
掛在 PreToolUse / UserPromptSubmit / Stop 三個 hook 上，從 stdin 收 hook 的 JSON。

任何一步失敗都安靜跳過，不要讓通知/小島壞掉卡住主流程。
"""

import json
import os
import re
import subprocess
import sys
import time

# 每個 session 各一份，小島才能列出同時在跑的多個任務。main() 依 session_id 設定。
SESSIONS_DIR = os.path.expanduser("~/.claude/tools/island/sessions")
STATE_PATH = os.path.join(SESSIONS_DIR, "default.json")
TAIL_BYTES = 300_000


def prev_state():
    try:
        with open(STATE_PATH) as fh:
            return json.load(fh)
    except Exception:
        return {}


def context_tokens(transcript):
    """逐字稿裡最後一則回覆的 context 用量。讀不到就回 0。

    只讀檔尾固定長度：逐字稿可能有上百 MB，整份解析會讓每次工具呼叫都卡一下。
    """
    if not transcript:
        return 0
    try:
        size = os.path.getsize(transcript)
        with open(transcript, "rb") as fh:
            fh.seek(max(0, size - TAIL_BYTES))
            tail = fh.read().decode("utf-8", "ignore")
    except Exception:
        return 0

    for line in reversed(tail.split("\n")):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            rec = json.loads(line)
        except Exception:
            continue
        if rec.get("type") != "assistant":
            continue
        u = (rec.get("message") or {}).get("usage") or {}
        if u:
            return (u.get("input_tokens", 0)
                    + u.get("cache_creation_input_tokens", 0)
                    + u.get("cache_read_input_tokens", 0))
    return 0


def last_activity(transcript, summary=False):
    """最後一則回覆的第一行實質內容——也就是「我現在在做什麼」。

    summary=True 用在任務結束：回覆裡有「result:」那行就用它（那是整件事的一句話結論），
    沒有才用第一行。
    """
    if not transcript:
        return ""
    try:
        size = os.path.getsize(transcript)
        with open(transcript, "rb") as fh:
            fh.seek(max(0, size - TAIL_BYTES))
            tail = fh.read().decode("utf-8", "ignore")
    except Exception:
        return ""

    for line in reversed(tail.split("\n")):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            rec = json.loads(line)
        except Exception:
            continue
        if rec.get("type") != "assistant":
            continue
        blocks = (rec.get("message") or {}).get("content") or []
        text = " ".join(b.get("text", "") for b in blocks if b.get("type") == "text")
        if not text.strip():
            continue
        limit = 56 if summary else 44
        lines = text.split("\n")
        if summary:
            picked = [l for l in lines if re.match(r"^\s*result:", l, re.I)]
            if picked:
                lines = [re.sub(r"^\s*result:\s*", "", picked[-1], flags=re.I)]
        for raw in lines:
            s = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", raw)
            s = re.sub(r"^[\s>#*\-]+", "", s)
            s = re.sub(r"[*`]", "", s)
            s = re.sub(r"\s+", " ", s).strip()
            if len(s) < 4 or set(s) <= set("-|: "):
                continue
            return s[:limit] + ("…" if len(s) > limit else "")
    return ""


def fmt_tokens(n):
    if n <= 0:
        return ""
    if n >= 1000:
        return f"{n / 1000:.0f}k" if n >= 10000 else f"{n / 1000:.1f}k"
    return str(n)


def hook_input():
    try:
        raw = sys.stdin.read()
        return json.loads(raw) if raw.strip() else {}
    except Exception:
        return {}


def basename(path):
    return os.path.basename((path or "").rstrip("/")) or path or ""


def describe(tool_name, tool_input):
    """回傳 (phase, detail, label)。phase 決定圖示動畫，detail 是灰字，label 是粗體字。"""
    ti = tool_input or {}

    if tool_name == "Read":
        return "reading", basename(ti.get("file_path")), "Reading file"
    if tool_name in ("Edit", "NotebookEdit"):
        return "working", basename(ti.get("file_path")), "Editing file"
    if tool_name == "Write":
        return "working", basename(ti.get("file_path")), "Writing file"
    if tool_name == "Bash":
        desc = ti.get("description") or ti.get("command") or "command"
        return "running", desc[:60], "Running command"
    if tool_name in ("Grep", "Glob"):
        return "reading", str(ti.get("pattern") or ti.get("path") or ""), "Searching code"
    if tool_name == "WebFetch":
        return "reading", ti.get("url") or "", "Reading web page"
    if tool_name == "WebSearch":
        return "reading", ti.get("query") or "", "Searching web"
    if tool_name in ("Agent", "Task"):
        return "working", ti.get("description") or "", "Delegating"
    if tool_name in ("TaskCreate", "TaskUpdate"):
        return "working", "", "Updating tasks"
    if tool_name and tool_name.startswith("mcp__"):
        return "working", tool_name.split("__")[-1], "Calling tool"
    if tool_name:
        return "working", tool_name, "Working"
    return "working", "", "Working"


def write_state(state):
    state["ts"] = time.time()
    tmp = STATE_PATH + ".tmp"
    try:
        os.makedirs(os.path.dirname(STATE_PATH), exist_ok=True)
        with open(tmp, "w") as fh:
            json.dump(state, fh)
        os.replace(tmp, STATE_PATH)
    except Exception:
        pass


MARKER = "Request interrupted by user"


def _ts(s):
    from datetime import datetime
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except Exception:
        return 0


def limit_detail(text):
    """「You've hit your session limit · resets 1:50pm (Asia/Taipei)」→「Session limit · resets 1:50pm」"""
    m = re.search(r"hit your (\w+) limit", text)
    kind = (m.group(1).capitalize() + " limit") if m else "Usage limit"
    r = re.search(r"resets (.+?)(?: \(|$)", text)
    return f"{kind} · resets {r.group(1)}" if r else kind


def usage_limit(transcript, since):
    """最新一筆對話是不是「額度用完」的 API 錯誤。回傳說明文字，不是就回空字串。"""
    if not transcript:
        return ""
    try:
        size = os.path.getsize(transcript)
        with open(transcript, "rb") as fh:
            fh.seek(max(0, size - 64_000))
            tail = fh.read().decode("utf-8", "ignore")
    except Exception:
        return ""
    for line in reversed(tail.split("\n")):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            rec = json.loads(line)
        except Exception:
            continue
        if rec.get("type") not in ("user", "assistant"):
            continue
        if rec.get("type") != "assistant" or _ts(rec.get("timestamp", "")) < since - 1:
            return ""
        text = " ".join(b.get("text", "") for b in ((rec.get("message") or {}).get("content") or [])
                        if isinstance(b, dict))
        # 伺服器暫時限流（not your usage limit）不算額度用完。
        if rec.get("isApiErrorMessage") and rec.get("error") == "rate_limit" and "hit your" in text:
            return limit_detail(text)
        if rec.get("isApiErrorMessage"):
            return "API_ERROR"      # 其他 API 錯誤（登入失效、斷線…）交給 app 分類顯示，這裡只防止被 Done 蓋掉
        return ""
    return ""


def interrupted(transcript, since):
    """最新一筆對話是不是「使用者中斷」，而且發生在這輪提問之後。

    只認文字區塊裡的中斷標記；工具輸出（tool_result）裡剛好出現這串字不算。
    """
    if not transcript:
        return False
    try:
        size = os.path.getsize(transcript)
        with open(transcript, "rb") as fh:
            fh.seek(max(0, size - 64_000))
            tail = fh.read().decode("utf-8", "ignore")
    except Exception:
        return False
    for line in reversed(tail.split("\n")):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            rec = json.loads(line)
        except Exception:
            continue
        if rec.get("type") not in ("user", "assistant"):
            continue
        if rec.get("type") == "assistant":
            return False
        content = (rec.get("message") or {}).get("content")
        if isinstance(content, str):
            texts = [content]
        else:
            texts = [b.get("text", "") for b in (content or [])
                     if isinstance(b, dict) and b.get("type") == "text"]
        hit = any(MARKER in t for t in texts)
        return hit and _ts(rec.get("timestamp", "")) >= since - 1
    return False


def claude_pid():
    """執行這個 hook 的 Claude Code 程序編號。

    hook 是 Claude Code → shell → python 這樣叫起來的，往上找第一個名字裡有 claude 或 node 的祖先。
    小島用它判斷 session 是不是突然被關掉（關終端機、強制結束），那種情況不會有任何 hook。
    """
    pid = os.getppid()
    for _ in range(6):
        try:
            out = subprocess.run(["ps", "-o", "ppid=,comm=", "-p", str(pid)],
                                 capture_output=True, text=True, timeout=2).stdout.strip()
        except Exception:
            return 0
        if not out:
            return 0
        ppid, _, comm = out.partition(" ")
        name = os.path.basename(comm.strip()).lower()
        if "claude" in name or name == "node":
            return pid
        pid = int(ppid.strip() or 0)
        if pid <= 1:
            return 0
    return 0


def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except Exception:
        return True          # 沒權限之類的：程序還在


def current_pid(old_pid):
    """沿用記下的 pid（不用每次跑 ps）；但 Claude Code 重開、接續同一個 session 時舊的 pid 已經不在，要重找。"""
    if old_pid and pid_alive(old_pid):
        return old_pid
    return claude_pid()


def session_title(transcript, known, known_custom):
    """session 的標題：/rename 取的名字優先，其次是 Claude Code 自動取的。

    先看檔尾；找不到又還沒記過時，才整份掃一次（之後就存在狀態檔裡，不會每次都掃）。
    """
    if not transcript:
        return known, known_custom

    def scan(text):
        custom = auto = ""
        for line in text.split("\n"):
            if '"custom-title"' not in line and '"ai-title"' not in line:
                continue
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if rec.get("type") == "custom-title":
                custom = rec.get("customTitle") or custom
            elif rec.get("type") == "ai-title":
                auto = rec.get("aiTitle") or auto
        return custom, auto

    try:
        size = os.path.getsize(transcript)
        with open(transcript, "rb") as fh:
            fh.seek(max(0, size - TAIL_BYTES))
            custom, auto = scan(fh.read().decode("utf-8", "ignore"))
            if not (custom or auto or known):
                fh.seek(0)
                custom, auto = scan(fh.read().decode("utf-8", "ignore"))
    except Exception:
        return known, known_custom
    if custom:
        return custom, True
    if known_custom:        # 檔尾只看到自動標題時，不要蓋掉之前記下的手動標題
        return known, True
    return auto or known, False


def main():
    global STATE_PATH
    data = hook_input()
    sid = re.sub(r"[^A-Za-z0-9_-]", "", data.get("session_id") or "") or "default"
    STATE_PATH = os.path.join(SESSIONS_DIR, sid + ".json")
    event = data.get("hook_event_name") or ""
    transcript = data.get("transcript_path") or ""
    tokens = fmt_tokens(context_tokens(transcript))
    # 記下當下的逐字稿大小，app 只看這之後新增的內容來判斷有沒有被中斷。
    try:
        tsize = os.path.getsize(transcript) if transcript else 0
    except Exception:
        tsize = 0
    project = os.path.basename((data.get("cwd") or "").rstrip("/"))
    old = prev_state()
    title, custom = session_title(transcript, old.get("title", ""), old.get("titleCustom", False))
    base = {"tokens": tokens, "transcript": transcript, "tsize": tsize,
            "project": project, "title": title, "titleCustom": custom,
            "pid": current_pid(old.get("pid"))}

    if event == "UserPromptSubmit":
        write_state({**base, "phase": "thinking", "detail": "",
                     "label": "Thinking", "task": "", "since": time.time(), "tstart": tsize})
        return

    # 這輪提問的時間，用來排除上一輪留下的中斷紀錄。
    prev = prev_state()
    since = prev.get("since", 0)
    base["since"] = since
    base["tstart"] = prev.get("tstart", 0)

    limit = usage_limit(transcript, since) if event in ("Stop", "PostToolUse") else ""
    if limit == "API_ERROR":
        # 保留目前狀態，只更新時間，讓 app 從逐字稿讀出錯誤類型。
        write_state({**prev_state(), **base, "phase": "error", "label": "Error", "detail": ""})
        return
    if limit:
        write_state({**base, "phase": "limit", "detail": limit,
                     "label": "Usage limit reached", "task": prev_state().get("task", "")})
        return

    # 被中斷的工具之後還是會觸發 hook；這時不要蓋掉成 Thinking / Done。
    if event in ("PreToolUse", "PostToolUse", "Stop") and interrupted(transcript, since):
        write_state({**base, "phase": "paused", "detail": "", "label": "Paused",
                     "task": prev_state().get("task", "")})
        return

    # 上面那行顯示我正在做什麼，沒有新的敘述就沿用上一次的。
    task = last_activity(transcript) or prev_state().get("task", "")

    if event == "PreToolUse":
        tool_name = data.get("tool_name") or ""
        phase, detail, label = describe(tool_name, data.get("tool_input"))
        write_state({**base, "phase": phase, "detail": detail,
                     "label": label, "task": task})
        return

    if event == "PostToolUse":
        # 工具跑完到下一個動作之間，模型在想事情。
        write_state({**base, "phase": "thinking", "detail": "",
                     "label": "Thinking", "task": task})
        return

    if event == "Stop":
        # 完成時上面那行寫「完成了什麼」，不是只有一個 Done；系統通知用同一句。
        summary = last_activity(transcript, summary=True)
        write_state({**base, "phase": "done", "detail": summary,
                     "label": "Done", "task": ""})
        try:
            sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
            import notify
            notify.finished(summary)
        except Exception:
            pass
        return

    # Claude Code 等輸入等了約 60 秒（idle_prompt）：送出後馬上取消的那種，逐字稿和 hook 都不會有任何紀錄，
    # 小島會一直停在 Thinking。還顯示工作中的話就直接收起來；已經是完成／暫停等結果就不動。
    if event == "Notification":
        idle = data.get("notification_type") == "idle_prompt" or "waiting for your input" in (data.get("message") or "")
        if idle and prev.get("phase") in (
                "thinking", "reading", "running", "working"):
            write_state({**prev, **base, "phase": "idle", "detail": "", "label": "", "task": ""})
        return

    if event == "SessionEnd":
        write_state({**base, "phase": "stopped", "detail": "",
                     "label": "Stopped", "task": ""})
        return


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
