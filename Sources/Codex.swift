import AppKit
import Foundation

// 讀 Codex 的工作紀錄（~/.codex/sessions/年/月/日/rollout-*.jsonl），把它正在做的事轉成小島的狀態檔。
// 不用裝 hook、不花 token：Codex 每做一步都會寫一行進紀錄檔，這裡每秒看一次新增的部分。
// 轉出來的檔案跟 Claude Code 的 hook 寫的格式一樣（sessions/codex-<id>.json），後面的顯示全部共用。
// 注意：紀錄格式不是公開規格，Codex 改版時可能要跟著調整；讀不懂的行一律跳過，不會讓小島壞掉。
final class CodexWatcher {
    static let shared = CodexWatcher()
    static var root = NSHomeDirectory() + "/.codex/sessions"
    static var available: Bool { FileManager.default.fileExists(atPath: root) }
    static var onDone: (String) -> Void = notifyDone   // 完成時要做的事（測試時換掉，才不會真的發通知）

    private struct Thread {
        var offset: UInt64 = 0
        var partial = Data()
        var state: [String: Any] = [:]
        var title = ""
        var project = ""
        var turnStartTokens = 0
        var lastTotalTokens = 0
        var started = false
    }

    private var threads: [String: Thread] = [:]       // 以紀錄檔路徑為 key
    private var timer: Timer?
    var enabled: () -> Bool = { true }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.scan() }
    }

    private var active: [String] = []                 // 最近有寫入的紀錄檔
    private var lastDiscovery = Date.distantPast

    // 每 5 秒找一次「最近 10 分鐘有寫入」的紀錄檔（不管是哪一天開的對話：接著舊對話聊，Codex 會寫回當初那天的檔案），
    // 找到的檔案每秒讀一次新增的部分。
    private func scan() {
        guard enabled(), Self.available else { return }
        let now = Date()
        if now.timeIntervalSince(lastDiscovery) > 5 {
            lastDiscovery = now
            active = Self.recentLogs(within: 600, now: now)
        }
        active.forEach(read)
    }

    static func recentLogs(within seconds: TimeInterval, now: Date) -> [String] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.contentModificationDateKey],
                                    options: [.skipsHiddenFiles]) else { return [] }
        var out: [String] = []
        for case let url as URL in e {
            let name = url.lastPathComponent
            // 檔名有底線的是 Codex 的子任務（sub-agent），跟主任務算同一件事，不另外顯示
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"), !name.contains("_"),
                  let mod = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(mod) < seconds else { continue }
            out.append(url.path)
        }
        return out
    }

    private func read(_ path: String) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd() else { return }
        let firstRead = threads[path] == nil
        var t = threads[path] ?? Thread()
        if firstRead {
            // 第一次看到這個檔：只讀最後一段就好（找得到目前這一輪的開頭）；id 先用檔名，之後 session_meta 會蓋掉
            t.offset = size > 400_000 ? size - 400_000 : 0
            t.state["id"] = "codex-" + ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        guard size > t.offset else { threads[path] = t; return }
        try? fh.seek(toOffset: t.offset)
        let data = t.partial + (fh.readDataToEndOfFile())
        t.offset = size
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        t.partial = data.last == UInt8(ascii: "\n") ? Data() : Data(lines.removeLast())
        let before = t.state as NSDictionary
        var finished: String?
        var lastAt = 0.0
        for line in lines where !line.isEmpty {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let summary = apply(o, to: &t) { finished = summary }
            if let ts = o["timestamp"] as? String, let d = isoFrac.date(from: ts) { lastAt = d.timeIntervalSince1970 }
        }
        threads[path] = t
        guard t.started, (t.state as NSDictionary) != before, let id = t.state["id"] as? String else { return }
        // 剛打開 app 時讀到的是過去的紀錄：只有最後一筆是最近 30 秒內的才顯示，而且不發完成通知
        if firstRead && Date().timeIntervalSince1970 - lastAt > 30 { return }
        write(id, t)
        if let finished, !firstRead, appTuning.t.systemNotify || appTuning.t.completionSound { Self.onDone(finished) }
    }

    // 一行紀錄 → 更新狀態；這一輪完成時回傳完成摘要
    private func apply(_ o: [String: Any], to t: inout Thread) -> String? {
        let type = o["type"] as? String ?? ""
        let p = o["payload"] as? [String: Any] ?? [:]
        let kind = p["type"] as? String ?? ""
        func set(_ phase: String, _ label: String, _ detail: String) {
            t.state["phase"] = phase
            t.state["label"] = label
            t.state["detail"] = detail
        }
        switch (type, kind) {
        case ("session_meta", _), ("turn_context", _):
            if let cwd = p["cwd"] as? String { t.project = (cwd as NSString).lastPathComponent }
        case ("event_msg", "task_started"):
            t.started = true
            t.turnStartTokens = t.lastTotalTokens
            t.state["since"] = Date().timeIntervalSince1970
            t.state["outTokens"] = 0
            set("thinking", "Thinking", "")
        case ("event_msg", "item_completed"):
            // 第一句使用者訊息當標題
            if t.title.isEmpty, let item = p["item"] as? [String: Any], item["type"] as? String == "UserMessage",
               let text = Self.text(of: item) {
                t.title = String(text.prefix(40))
            }
        case ("response_item", "reasoning"):
            if t.started, t.state["phase"] as? String != "thinking" { set("thinking", "Thinking", "") }
        case ("response_item", "custom_tool_call"), ("response_item", "function_call"):
            guard t.started else { break }
            let (phase, label, detail) = Self.describe(name: p["name"] as? String ?? "",
                                                       input: (p["input"] as? String) ?? (p["arguments"] as? String) ?? "")
            set(phase, label, detail)
        case ("response_item", "custom_tool_call_output"), ("response_item", "function_call_output"):
            if t.started { set("thinking", "Thinking", "") }
        case ("event_msg", "token_count"):
            if let info = p["info"] as? [String: Any], let total = info["total_token_usage"] as? [String: Any],
               let out = total["output_tokens"] as? Int {
                t.lastTotalTokens = out
                if t.started { t.state["outTokens"] = max(0, out - t.turnStartTokens) }
            }
        case ("event_msg", "task_complete"):
            guard t.started else { break }
            let msg = (p["last_agent_message"] as? String ?? "").split(separator: "\n").first.map(String.init) ?? ""
            let summary = String(msg.prefix(80))
            set("done", "Done", summary)
            return summary.isEmpty ? L("完成了", "Done") : summary
        case ("event_msg", "turn_aborted"):
            if t.started { set("paused", "Paused", "") }
        default:
            break
        }
        return nil
    }

    // 工具呼叫 → (動畫狀態, 狀態字, 上面那行)
    static func describe(name: String, input: String) -> (String, String, String) {
        // Codex 常用一段程式碼去呼叫別的工具（tools.xxx(...)）：看裡面實際呼叫的是哪個
        if name == "exec", let inner = firstMatch(#"tools\.([A-Za-z0-9_]+)\("#, in: input), inner != "exec_command" {
            if inner.contains("web") || inner.contains("search") {
                let q = firstMatch(#"q"?\s*:\s*"((?:[^"\\]|\\.)*)""#, in: input) ?? ""
                return ("reading", "Searching web", String(q.prefix(60)))
            }
            if inner.contains("apply_patch") { return ("working", "Editing file", "") }
            let pretty = inner.replacingOccurrences(of: "mcp__", with: "").replacingOccurrences(of: "__", with: " · ")
            return ("working", "Calling tool", pretty)
        }
        if name == "exec", !input.contains("exec_command") { return ("working", "Working", "") }
        if name == "exec" || name == "exec_command" || name == "shell" {
            let cmd = firstMatch(#"cmd"?\s*:\s*"((?:[^"\\]|\\.)*)""#, in: input) ?? input
            let c = cmd.replacingOccurrences(of: "\\\"", with: "\"").trimmingCharacters(in: .whitespaces)
            let head = c.split(separator: " ").first.map(String.init) ?? ""
            if c.contains("apply_patch") { return ("working", "Editing file", "") }
            if ["rg", "grep", "find"].contains(head) { return ("reading", "Searching code", String(c.prefix(60))) }
            if ["sed", "cat", "head", "tail", "nl", "ls", "wc"].contains(head) {
                let file = c.split(separator: " ").last.map { ($0 as NSString).lastPathComponent } ?? ""
                return ("reading", "Reading file", file.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
            }
            return ("running", "Running command", String(c.prefix(60)))
        }
        if name == "apply_patch" { return ("working", "Editing file", "") }
        if name == "js", let title = firstMatch(#""title"\s*:\s*"((?:[^"\\]|\\.)*)""#, in: input) {
            return ("working", "Working", title)
        }
        if name == "wait" { return ("running", "Running command", "") }
        return ("working", "Working", name)
    }

    private static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    private static func text(of item: [String: Any]) -> String? {
        if let s = item["text"] as? String { return s }
        if let content = item["content"] as? [[String: Any]] {
            return content.compactMap { $0["text"] as? String }.first
        }
        return nil
    }

    private func write(_ id: String, _ t: Thread) {
        var s = t.state
        s.removeValue(forKey: "id")
        s["project"] = t.project
        s["title"] = "Codex · " + (t.title.isEmpty ? t.project : t.title)
        s["task"] = ""
        s["ts"] = Date().timeIntervalSince1970
        guard let d = try? JSONSerialization.data(withJSONObject: s) else { return }
        try? FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try? d.write(to: URL(fileURLWithPath: sessionsDir + "/\(id).json"), options: .atomic)
    }

    // 完成時的系統通知和音效：跟 Claude Code 共用打包在 app 裡的 notify.py
    static func notifyDone(_ summary: String) {
        guard let hookDir = Bundle.main.resourceURL?.appendingPathComponent("hook").path else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-c", "import sys; sys.path.insert(0, sys.argv[1]); import notify; notify.finished(sys.argv[2], title='Codex')",
                       hookDir, summary]
        try? p.run()
    }
}
