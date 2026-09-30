import AppKit
import Foundation
import UserNotifications

// 自動更新：去 GitHub Releases 看最新版本，比目前新就提醒；按「更新」會下載、換掉 app、重新打開。
// 發佈新版用 repo 裡的 release.sh（會打包 zip 上傳到 GitHub Releases）。
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "1413jean/agent-island"
    // 測試用：`defaults write com.jean.claudeisland updateAPIBase http://127.0.0.1:8765` 可以把更新來源指到本機
    static var apiBase: String { (isDevBuild ? UserDefaults.standard.string(forKey: "updateAPIBase") : nil) ?? "https://api.github.com" }
    var installWhenFound = false                    // 測試用：啟動參數 --install-update-now，找到新版就直接更新

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)          // 新版本號
        case downloading
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private(set) var downloadURL: URL?
    private var timer: Timer?
    private var notifiedVersion = UserDefaults.standard.string(forKey: "notifiedUpdateVersion")

    var latestVersion: String? { if case .available(let v) = state { return v } else { return nil } }

    // 開 app 後 10 秒檢查一次，之後每天一次（設定裡可以關）
    func startAutoCheck(enabled: @escaping () -> Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in if enabled() { self?.check(userInitiated: false) } }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            if enabled() { self?.check(userInitiated: false) }
        }
    }

    func check(userInitiated: Bool) {
        if case .downloading = state { return }
        state = .checking
        var req = URLRequest(url: URL(string: "\(Self.apiBase)/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async { self?.handle(data, resp as? HTTPURLResponse, err, userInitiated) }
        }.resume()
    }

    private func handle(_ data: Data?, _ resp: HTTPURLResponse?, _ err: Error?, _ userInitiated: Bool) {
        if let err { state = .failed(L("連不上 GitHub（\(err.localizedDescription)）", "Can't reach GitHub (\(err.localizedDescription))")); return }
        guard resp?.statusCode == 200, let data,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = o["tag_name"] as? String else {
            state = .failed(resp?.statusCode == 404 ? L("還沒有發佈的版本（或 repo 不是公開的）", "No releases yet (or the repo isn't public)") : L("讀不到版本資訊", "Couldn't read the version info"))
            return
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = o["assets"] as? [[String: Any]] ?? []
        downloadURL = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
            .flatMap { $0["browser_download_url"] as? String }.flatMap(URL.init(string:))
        guard Self.isNewer(version, than: appVersion), downloadURL != nil else { state = .upToDate; return }
        state = .available(version)
        if installWhenFound { installWhenFound = false; install(); return }
        if notifiedVersion != version {                    // 同一個新版本只提醒一次
            notifiedVersion = version
            UserDefaults.standard.set(version, forKey: "notifiedUpdateVersion")
            notify(version)
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    private func notify(_ version: String) {
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert]) { ok, _ in
            guard ok else { return }
            let n = UNMutableNotificationContent()
            n.title = L("Agent Island 有新版本", "Agent Island update available")
            n.body = L("\(version) 可以更新了，點這裡或從選單列的小島圖示更新。", "Version \(version) is ready. Click here, or update from the island's menu bar icon.")
            c.add(UNNotificationRequest(identifier: "update-\(version)", content: n, trigger: nil))
        }
    }

    // 下載 zip → 解壓 → 確認是同一個 app → 把舊的丟到垃圾桶、換上新的 → 重新打開
    func install() {
        guard let url = downloadURL, let version = latestVersion else { return }
        state = .downloading
        URLSession.shared.downloadTask(with: url) { [weak self] file, _, err in
            let result: String? = {
                guard let file, err == nil else { return L("下載失敗", "Download failed") }
                return Self.replaceApp(with: file, expecting: version)
            }()
            DispatchQueue.main.async {
                if let result { self?.state = .failed(result) }
            }
        }.resume()
    }

    private static func replaceApp(with zip: URL, expecting version: String) -> String? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("AgentIslandUpdate-\(UUID().uuidString)")
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch { return L("沒辦法建立暫存資料夾", "Couldn't create a temporary folder") }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, dir.path]
        do { try unzip.run(); unzip.waitUntilExit() } catch { return L("解壓縮失敗", "Couldn't unzip the update") }
        guard unzip.terminationStatus == 0,
              let app = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "app" }),
              let info = Bundle(url: app)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else { return L("下載的檔案不是 Agent Island", "The download isn't Agent Island") }
        let current = Bundle.main.bundleURL
        do {
            try fm.trashItem(at: current, resultingItemURL: nil)
            try fm.moveItem(at: app, to: current)
        } catch {
            return L("沒辦法換掉舊版（\(error.localizedDescription)）", "Couldn't replace the old version (\(error.localizedDescription))")
        }
        // 等目前這個 app 結束後再打開新版
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; open \"\(current.path)\""]
        try? relaunch.run()
        DispatchQueue.main.async { NSApp.terminate(nil) }
        return nil
    }
}
