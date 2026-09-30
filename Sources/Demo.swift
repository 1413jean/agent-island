import AppKit
import SwiftUI

// 示範模式（錄影用）：假裝有 Claude Code 任務在跑，把狀態寫進 sessions/demo*.json，
// 小島照平常讀 hook 檔案的流程顯示，所以動畫、收合、滑動切換都跟真的一樣。
// 示範期間只顯示示範的任務，真的 session 先藏起來，錄影畫面才乾淨。

var demoActive = false

struct DemoStep {
    let phase, label, detail: String
    var secs = 0.0
}

final class DemoRunner: ObservableObject {
    @Published var now = ""                 // 目前在跑哪一段（顯示在示範視窗）
    @Published var busy = true              // 忙碌：一直送事件，光核轉快、集氣
    @Published var delayStart = false       // 按下後 3 秒才開始，先按下錄影

    private var work: [DispatchWorkItem] = []
    private var pulse: Timer?
    private var current: [String: DemoStep] = [:]
    private var since = 0.0

    // 小島會出現的每一種狀態都要在這裡有一顆按鈕（新增狀態時記得補上）
    static var states: [(String, DemoStep)] { [
        ("Thinking", DemoStep(phase: "thinking", label: "Thinking", detail: "")),
        ("Reading file", DemoStep(phase: "reading", label: "Reading file", detail: "DotOrb.swift")),
        ("Searching code", DemoStep(phase: "reading", label: "Searching code", detail: "BottomGlow")),
        ("Searching web", DemoStep(phase: "reading", label: "Searching web", detail: "dynamic island motion")),
        ("Running command", DemoStep(phase: "running", label: "Running command", detail: "npm run build")),
        ("Editing file", DemoStep(phase: "working", label: "Editing file", detail: "main.swift")),
        ("Writing file", DemoStep(phase: "working", label: "Writing file", detail: "notes.md")),
        ("Delegating", DemoStep(phase: "working", label: "Delegating", detail: "Explore codebase")),
        ("Calling tool", DemoStep(phase: "working", label: "Calling tool", detail: "figma · get_screenshot")),
        ("Done", DemoStep(phase: "done", label: "Done", detail: L("小島加上示範模式", "Added demo mode to the island"))),
        ("Paused", DemoStep(phase: "paused", label: "Paused", detail: "")),
        ("Stopped", DemoStep(phase: "stopped", label: "Stopped", detail: L("Session 已關閉", "Session closed"))),
        ("Usage limit", DemoStep(phase: "limit", label: "Usage limit reached", detail: "Session limit · resets 5pm")),
        ("Login required", DemoStep(phase: "error", label: "Login required", detail: L("登入已失效 · 在終端機執行 /login", "Signed out · run /login in the terminal"))),
        ("Connection lost", DemoStep(phase: "error", label: "Connection lost", detail: L("連不上 API · 檢查網路後重送", "Can't reach the API · check your connection and resend"))),
        ("Server busy", DemoStep(phase: "error", label: "Server busy", detail: L("伺服器暫時忙碌 · 稍後重送", "Server busy · resend in a moment"))),
        ("Model unavailable", DemoStep(phase: "error", label: "Model unavailable", detail: L("選的模型無法使用 · 用 /model 換一個", "Selected model unavailable · pick another with /model"))),
    ] }

    // 一般任務：想一下 → 讀檔 → 搜尋 → 改檔 → 跑指令 → 再想一下 → 完成
    static let flow: [DemoStep] = [
        DemoStep(phase: "thinking", label: "Thinking", detail: "", secs: 3),
        DemoStep(phase: "reading", label: "Reading file", detail: "DotOrb.swift", secs: 2),
        DemoStep(phase: "reading", label: "Searching code", detail: "BottomGlow", secs: 1.6),
        DemoStep(phase: "working", label: "Editing file", detail: "DotOrb.swift", secs: 2.4),
        DemoStep(phase: "running", label: "Running command", detail: "./build.sh", secs: 2.6),
        DemoStep(phase: "thinking", label: "Thinking", detail: "", secs: 2),
        DemoStep(phase: "done", label: "Done", detail: L("完成動畫改成點點圈翻轉", "Reworked the done animation"), secs: 0),
    ]

    static let flowB: [DemoStep] = [
        DemoStep(phase: "thinking", label: "Thinking", detail: "", secs: 2.5),
        DemoStep(phase: "reading", label: "Searching web", detail: "Face ID animation", secs: 3),
        DemoStep(phase: "working", label: "Writing file", detail: "notes.md", secs: 3.5),
        DemoStep(phase: "running", label: "Running command", detail: "git push", secs: 3),
        DemoStep(phase: "done", label: "Done", detail: L("整理好參考資料", "Collected the reference notes"), secs: 0),
    ]

    func show(_ name: String, _ step: DemoStep) {
        run(name) { [weak self] in
            self?.put("demo", step, title: "Island demo")
        }
    }

    func playFlow() {
        run(L("一般任務", "Typical task")) { [weak self] in
            self?.schedule("demo", Self.flow, title: "Island demo")
        }
    }

    func playTwo() {
        run(L("兩個任務", "Two tasks")) { [weak self] in
            self?.schedule("demo", Self.flow, title: "Island redesign")
            self?.schedule("demo-b", Self.flowB, title: "Research notes", offset: 0.6)
        }
    }

    // 收掉示範：清掉檔案，真的 session 恢復顯示
    func clear() {
        cancel()
        removeFiles()
        demoActive = false
        now = ""
    }

    private func run(_ name: String, _ body: @escaping () -> Void) {
        cancel()
        removeFiles()
        demoActive = true
        since = Date().timeIntervalSince1970
        now = delayStart ? L("3 秒後開始：\(name)", "Starting in 3 seconds: \(name)") : name
        let go = DispatchWorkItem { [weak self] in
            self?.now = name
            body()
            self?.startPulse()
        }
        work.append(go)
        DispatchQueue.main.asyncAfter(deadline: .now() + (delayStart ? 3 : 0), execute: go)
    }

    private func schedule(_ id: String, _ steps: [DemoStep], title: String, offset: Double = 0) {
        var t = offset
        for s in steps {
            let item = DispatchWorkItem { [weak self] in self?.put(id, s, title: title) }
            work.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: item)
            t += s.secs
        }
    }

    // 忙碌時每 0.35 秒重寫一次（算成一個動作），光核就會轉快、集氣；結束類的狀態不重寫，才會照常收起來。
    private func startPulse() {
        pulse?.invalidate()
        pulse = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            guard let self, self.busy else { return }
            for (id, s) in self.current where !finishPhases.contains(s.phase) {
                self.write(id, s, title: self.titles[id] ?? "")
            }
        }
    }

    private var titles: [String: String] = [:]

    private func put(_ id: String, _ s: DemoStep, title: String) {
        current[id] = s
        titles[id] = title
        write(id, s, title: title)
    }

    private func write(_ id: String, _ s: DemoStep, title: String) {
        let obj: [String: Any] = [
            "phase": s.phase, "label": s.label, "detail": s.detail, "task": "",
            "since": since, "project": "demo", "title": title,
            "pid": Int(getpid()),                         // 用小島自己的 pid：一直活著，不會被當成 session 已關閉
            "ts": Date().timeIntervalSince1970,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        try? FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        let path = sessionsDir + "/\(id).json"
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func cancel() {
        work.forEach { $0.cancel() }
        work = []
        pulse?.invalidate()
        pulse = nil
        current = [:]
    }

    private func removeFiles() {
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(atPath: sessionsDir)) ?? [] where f.hasPrefix("demo") {
            try? fm.removeItem(atPath: sessionsDir + "/" + f)
        }
    }
}

struct DemoView: View {
    @ObservedObject var demo: DemoRunner
    @ObservedObject var store: TuningStore

    private let cols = [GridItem(.adaptive(minimum: 132), spacing: 8)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("示範模式", "Demo mode")).font(.title2.bold())
                    Text(L("按一下，小島就照那個狀態跑，跟真的任務一樣。示範期間只顯示示範的任務。", "Click a button and the island runs that state just like a real task. Only demo tasks show while the demo runs."))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section(L("完整流程", "Full run")) {
                    HStack(spacing: 8) {
                        big(L("▶︎  一般任務（約 14 秒）", "▶︎  Typical task (about 14 s)")) { demo.playFlow() }
                        big(L("▶︎  兩個任務（可滑動切換）", "▶︎  Two tasks (swipe to switch)")) { demo.playTwo() }
                    }
                }

                section(L("單一狀態", "Single state")) {
                    LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
                        ForEach(DemoRunner.states, id: \.0) { item in
                            big(item.0) { demo.show(item.0, item.1) }
                        }
                    }
                }

                section(L("選項", "Options")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(L("忙碌（光核轉快、集氣）", "Busy (faster orb, gathering particles)"), isOn: $demo.busy)
                        Toggle(L("按下後 3 秒才開始（先按下錄影）", "Start 3 seconds after clicking (time to start recording)"), isOn: $demo.delayStart)
                        Picker(L("圖示", "Icon"), selection: $store.t.iconStyle) {
                            Text(L("光核", "Orb")).tag("orb")
                            Text(L("像素格", "Pixel")).tag("pixel")
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 260)
                    }
                }

                HStack {
                    Text(demo.now.isEmpty ? L("沒有在示範", "No demo running") : L("示範中：\(demo.now)", "Running: \(demo.now)"))
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("結束示範", "End demo")) { demo.clear() }
                        .controlSize(.large)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 340, idealWidth: 460, minHeight: 420, idealHeight: 620)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func big(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity, minHeight: 32)
        }
        .controlSize(.large)
    }
}
