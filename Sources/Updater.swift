import AppKit
import Foundation
import Sparkle
import UserNotifications

// 自動更新（Sparkle）：每小時在背景看一次 GitHub Releases 上的 appcast.xml，有新版不跳視窗打擾，
// 只在設定視窗標題列、選單列選單放一顆「更新到 x.y.z」，再發一則通知；按下去才打開 Sparkle 的更新視窗（看更新內容、安裝）。
// 每個更新檔都用 EdDSA 金鑰簽名（私鑰只在發佈者的鑰匙圈裡），簽名對不上的更新 Sparkle 不會裝。
// 發佈新版用 repo 裡的 release.sh（打包 zip、簽名、產生 appcast.xml、上傳到 GitHub Releases）。
final class Updater: NSObject, ObservableObject {
    static let shared = Updater()

    enum State: Equatable {
        case idle
        case upToDate
        case available(String)          // 新版本號
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?
    private var updater: SPUUpdater!
    private var userDriver: SPUStandardUserDriver!
    private var notifiedVersion = UserDefaults.standard.string(forKey: "notifiedUpdateVersion")
    var testAutoInstall = false     // 測試用（只有測試版）：啟動參數 --auto-install-update，找到新版就直接下載、安裝、重開

    var latestVersion: String? { if case .available(let v) = state { return v } else { return nil } }

    // 開 app 時呼叫：enabled＝設定裡的「自動檢查更新」
    func start(automatic enabled: Bool) {
        userDriver = SPUStandardUserDriver(hostBundle: .main, delegate: self)
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: userDriver, delegate: self)
        do { try updater.start() } catch { state = .failed(error.localizedDescription) }
        setAutomatic(enabled)
        lastChecked = updater.lastUpdateCheckDate
    }

    // 測試版不自動檢查：不然正式版一出來就會把測試版換掉（手動檢查還是可以）
    func setAutomatic(_ on: Bool) {
        updater?.automaticallyChecksForUpdates = on && !isDevBuild
        updater?.updateCheckInterval = 3600     // 每小時一次（Sparkle 最短就是一小時）
    }

    // 背景檢查一次（不跳視窗；找到新版就出現標題列按鈕）
    func checkInBackground() {
        if testAutoInstall {                    // 自動下載要在自動檢查打開時才會作用
            updater?.automaticallyChecksForUpdates = true
            updater?.automaticallyDownloadsUpdates = true
        }
        updater?.checkForUpdatesInBackground()
    }

    // 按「檢查更新」或標題列的「更新」：交給 Sparkle 的視窗（有新版就顯示更新內容和安裝按鈕）
    func checkNow() {
        NSApp.activate(ignoringOtherApps: true)
        updater?.checkForUpdates()
    }

    private func notify(_ version: String) {
        guard notifiedVersion != version else { return }          // 同一個新版本只提醒一次
        notifiedVersion = version
        UserDefaults.standard.set(version, forKey: "notifiedUpdateVersion")
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert]) { ok, _ in
            guard ok else { return }
            let n = UNMutableNotificationContent()
            n.title = L("Agent Island 有新版本", "Agent Island update available")
            n.body = L("\(version) 可以更新了，點這裡或從設定視窗的標題列更新。", "Version \(version) is ready. Click here, or update from the top of the Settings window.")
            n.threadIdentifier = "update"
            c.add(UNNotificationRequest(identifier: "update-\(version)", content: n, trigger: nil))
        }
    }
}

extension Updater: SPUUpdaterDelegate {
    // 測試版可以把更新來源指到本機：`defaults write com.jean.claudeisland updateFeedURL http://127.0.0.1:8765/appcast.xml`
    func feedURLString(for updater: SPUUpdater) -> String? {
        isDevBuild ? UserDefaults.standard.string(forKey: "updateFeedURL") : nil
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        guard testAutoInstall else { return false }
        immediateInstallHandler()
        return true
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        DispatchQueue.main.async {
            self.state = .available(item.displayVersionString)
            self.lastChecked = updater.lastUpdateCheckDate
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        DispatchQueue.main.async {
            self.state = .upToDate
            self.lastChecked = updater.lastUpdateCheckDate
        }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let e = error as NSError
        guard e.domain == SUSparkleErrorDomain, e.code != Int(SUError.noUpdateError.rawValue) else { return }
        DispatchQueue.main.async { self.state = .failed(error.localizedDescription) }
    }
}

extension Updater: SPUStandardUserDriverDelegate {
    // 背景找到新版時不跳 Sparkle 的視窗（選單列 app 突然跳視窗很打擾），改成標題列按鈕＋通知
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let v = update.displayVersionString
        DispatchQueue.main.async {
            self.state = .available(v)
            if !handleShowingUpdate && !state.userInitiated { self.notify(v) }
        }
    }

    func standardUserDriverWillFinishUpdateSession() {
        DispatchQueue.main.async { self.lastChecked = self.updater.lastUpdateCheckDate }
    }
}
