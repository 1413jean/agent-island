import AppKit
import UserNotifications

// 完成通知：hook/notify.py 在 notify/ 放一個小檔案（標題、內文、Terminal 分頁的 tty），這裡讀到就用系統通知發出去。
// 通知由小島自己發，顯示的是 Agent Island 的名字和圖示；macOS 14 以上、M 系列和 Intel 都能用。
// 點通知：有 tty 就切回那個 Terminal 分頁；沒有（Codex、更新通知）就照原本的處理。

let notifyDir = islandDataDir + "/notify"

enum DoneNotifier {
    private static var timer: Timer?

    static func start() {
        try? FileManager.default.createDirectory(atPath: notifyDir, withIntermediateDirectories: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in drain() }
    }

    private static func drain() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: notifyDir), !files.isEmpty else { return }
        for f in files.sorted() where f.hasSuffix(".json") {
            let path = notifyDir + "/" + f
            let data = fm.contents(atPath: path)
            try? fm.removeItem(atPath: path)
            guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            // 太舊的（小島沒開的時候留下的）就不發了
            if let ts = obj["ts"] as? Double, Date().timeIntervalSince1970 - ts > 60 { continue }
            post(title: obj["title"] as? String ?? "Claude Code",
                 body: obj["body"] as? String ?? L("完成了", "Done"),
                 tty: obj["tty"] as? String)
        }
    }

    private static func post(title: String, body: String, tty: String?) {
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert]) { ok, _ in
            guard ok else { return }
            let n = UNMutableNotificationContent()
            n.title = title
            n.body = body
            n.threadIdentifier = "done"
            if let tty { n.userInfo = ["tty": tty] }
            c.add(UNNotificationRequest(identifier: UUID().uuidString, content: n, trigger: nil))
        }
    }

    // 點了完成通知：切到 Terminal 裡 tty 相符的分頁
    static func focusTerminalTab(_ tty: String) {
        guard tty.range(of: "^ttys?[0-9]+$", options: .regularExpression) != nil else { return }
        let script = """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "/dev/\(tty)" then
                        set selected tab of w to t
                        set index of w to 1
                    end if
                end repeat
            end repeat
        end tell
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }
}
