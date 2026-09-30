import AppKit
import Foundation

// 連接 Claude Code：在 ~/.claude/settings.json 加上小島的 hook（hook 程式打包在 app 裡）。
// 只加、只移除自己的那幾條（辨認方式：指令裡有 island_hook.py），不動使用者其他的設定；寫入前先備份。
enum ClaudeCodeLink {
    static var settingsPath = NSHomeDirectory() + "/.claude/settings.json"
    static var backupPath = NSHomeDirectory() + "/.claude/settings.json.agent-island-backup"
    static let marker = "island_hook.py"
    // 狀態變化會觸發的 hook；Notification 只接 idle_prompt（Claude Code 等輸入時收起小島）
    static let events = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"]

    static var hookScript: String {
        Bundle.main.resourceURL?.appendingPathComponent("hook/island_hook.py").path ?? ""
    }
    static var command: String { "python3 \"\(hookScript)\" 2>/dev/null || true" }

    enum Status: Equatable {
        case noClaudeCode          // 沒有 ~/.claude（還沒裝過 Claude Code）
        case disconnected
        case connected
        case outdated              // 連過，但指向別的位置或少了幾個 hook（app 搬過家、舊版安裝）
    }

    static func status() -> Status {
        guard FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.claude") else { return .noClaudeCode }
        let hooks = (read()["hooks"] as? [String: Any]) ?? [:]
        var found = 0, current = 0
        for e in events + ["Notification"] {
            for cmd in commands(in: hooks[e]) where cmd.contains(marker) {
                found += 1
                if cmd.contains(hookScript) { current += 1 }
                break
            }
        }
        if found == 0 { return .disconnected }
        return current == events.count + 1 ? .connected : .outdated
    }

    // 連接（或重新連接）：先拿掉舊的，再每個事件加一條
    static func connect() throws {
        var s = read()
        try backup()
        var hooks = removeOurs(from: (s["hooks"] as? [String: Any]) ?? [:])
        let entry: [String: Any] = ["type": "command", "command": command, "async": true]
        for e in events {
            var list = hooks[e] as? [[String: Any]] ?? []
            list.append(["hooks": [entry]])
            hooks[e] = list
        }
        var n = hooks["Notification"] as? [[String: Any]] ?? []
        n.append(["matcher": "idle_prompt", "hooks": [entry]])
        hooks["Notification"] = n
        s["hooks"] = hooks
        try write(s)
    }

    static func disconnect() throws {
        var s = read()
        try backup()
        let hooks = removeOurs(from: (s["hooks"] as? [String: Any]) ?? [:])
        if hooks.isEmpty { s.removeValue(forKey: "hooks") } else { s["hooks"] = hooks }
        try write(s)
    }

    // MARK: -

    private static func read() -> [String: Any] {
        guard let d = FileManager.default.contents(atPath: settingsPath),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    private static func write(_ s: [String: Any]) throws {
        let d = try JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(atPath: NSHomeDirectory() + "/.claude", withIntermediateDirectories: true)
        try d.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
    }

    private static func backup() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsPath) else { return }
        try? fm.removeItem(atPath: backupPath)
        try fm.copyItem(atPath: settingsPath, toPath: backupPath)
    }

    private static func commands(in event: Any?) -> [String] {
        ((event as? [[String: Any]]) ?? []).flatMap { group in
            ((group["hooks"] as? [[String: Any]]) ?? []).compactMap { $0["command"] as? String }
        }
    }

    // 從每個事件裡拿掉小島的 hook；整組都空了就拿掉整組、整個事件都空了就拿掉事件
    private static func removeOurs(from hooks: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { out[event] = value; continue }
            let kept: [[String: Any]] = groups.compactMap { g in
                guard let hs = g["hooks"] as? [[String: Any]] else { return g }
                let left = hs.filter { !(($0["command"] as? String) ?? "").contains(marker) }
                if left.isEmpty { return nil }
                var g = g
                g["hooks"] = left
                return g
            }
            if !kept.isEmpty { out[event] = kept }
        }
        return out
    }
}
