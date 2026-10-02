import AppKit
import SwiftUI
import UserNotifications

// 貼齊螢幕頂端的狀態小島。讀 state.json（由 Claude Code 的 hook 寫入）。
// 沒事的時候縮成和實體瀏海一樣大小（等於看不見），有任務才長開。

// MARK: - 狀態

struct IslandState: Equatable {
    var phase: String = "idle"
    var detail: String = ""
    var label: String = ""
    var task: String = ""
    var tokens: String = ""
    var transcript: String = ""
    var tsize: Int = 0
    var tstart: Int = 0
    var since: Double = 0
    var project: String = ""
    var title: String = ""
    var pid: Int32 = 0
    var outTokens = 0             // 這一輪產生的 token（Codex 的紀錄直接給；Claude Code 從逐字稿算）
    var ts: Double = 0

    static func == (lhs: IslandState, rhs: IslandState) -> Bool {
        lhs.phase == rhs.phase && lhs.detail == rhs.detail && lhs.label == rhs.label
            && lhs.task == rhs.task && lhs.tokens == rhs.tokens && lhs.project == rhs.project
            && lhs.title == rhs.title
    }
}

// hook 每個 session 各寫一份 <session_id>.json。
// 小島和 hook 共用的資料夾（在使用者自己的家目錄底下，換一台電腦也一樣）
let islandDataDir = NSHomeDirectory() + "/.claude/tools/island"
let sessionsDir = islandDataDir + "/sessions"

func loadState(_ path: String) -> IslandState? {
    guard let data = FileManager.default.contents(atPath: path),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return IslandState(
        phase: obj["phase"] as? String ?? "idle",
        detail: obj["detail"] as? String ?? "",
        label: obj["label"] as? String ?? "",
        task: obj["task"] as? String ?? "",
        tokens: obj["tokens"] as? String ?? "",
        transcript: obj["transcript"] as? String ?? "",
        tsize: obj["tsize"] as? Int ?? 0,
        tstart: obj["tstart"] as? Int ?? 0,
        since: obj["since"] as? Double ?? 0,
        project: obj["project"] as? String ?? "",
        title: obj["title"] as? String ?? "",
        pid: Int32(obj["pid"] as? Int ?? 0),
        outTokens: obj["outTokens"] as? Int ?? 0,
        ts: obj["ts"] as? Double ?? 0
    )
}

// 看逐字稿最新一筆對話，判斷這輪是不是被中斷、或額度用完。只認這輪提問之後發生的。
// 不能只看某個位置之後的新內容：被中斷的工具之後還會觸發 hook、把檢查起點推到中斷紀錄後面。
let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

enum TailEvent {
    case none
    case interrupted
    case limit(String)      // 帶著「Session limit · resets 1:50pm」這類說明
    case error(label: String, detail: String)   // 登入失效、連不上、其他 API 錯誤：任務停住了，不會再有 hook
}

// API 錯誤訊息 → 小島上的兩行字。label 講發生什麼，detail 講要做什麼。
func apiErrorDisplay(_ kind: String, _ text: String) -> (String, String) {
    let t = text.lowercased()
    if kind == "authentication_failed" || kind == "oauth_org_not_allowed" || t.contains("/login") {
        return ("Login required", L("登入已失效 · 在終端機執行 /login", "Signed out · run /login in the terminal"))
    }
    if t.contains("enotfound") || t.contains("connect") || t.contains("socket") || t.contains("econnreset")
        || t.contains("went to sleep") || t.contains("timed out") {
        return ("Connection lost", L("連不上 API · 檢查網路後重送", "Can't reach the API · check your connection and resend"))
    }
    if kind == "model_not_found" { return ("Model unavailable", L("選的模型無法使用 · 用 /model 換一個", "Selected model unavailable · pick another with /model")) }
    if t.contains("overloaded") || t.contains("temporarily limiting") {
        return ("Server busy", L("伺服器暫時忙碌 · 稍後重送", "Server busy · resend in a moment"))
    }
    let first = text.replacingOccurrences(of: "API Error: ", with: "")
    return ("API error", String(first.prefix(48)))
}

// 「You've hit your session limit · resets 1:50pm (Asia/Taipei)」→「Session limit · resets 1:50pm」
func limitDetail(_ text: String) -> String {
    var kind = "Usage limit"
    if let r = text.range(of: "hit your "), let e = text.range(of: " limit", range: r.upperBound..<text.endIndex) {
        let k = String(text[r.upperBound..<e.lowerBound])
        kind = k.prefix(1).uppercased() + k.dropFirst() + " limit"
    }
    guard let r = text.range(of: "resets ") else { return kind }
    var when = String(text[r.upperBound...])
    if let p = when.range(of: " (") { when = String(when[..<p.lowerBound]) }
    return "\(kind) · resets \(when)"
}

// 每 0.15 秒會問一次；逐字稿沒變大（也還是同一輪）就直接用上次的答案，不重讀、不重新解析。
private var tailCache: [String: (size: UInt64, since: Double, result: TailEvent)] = [:]

func tailEvent(_ s: IslandState) -> TailEvent {
    let size = (try? FileManager.default.attributesOfItem(atPath: s.transcript)[.size] as? UInt64) ?? 0
    if let c = tailCache[s.transcript], c.size == size, c.since == s.since { return c.result }
    let r = readTailEvent(s)
    tailCache[s.transcript] = (size, s.since, r)
    return r
}

private func readTailEvent(_ s: IslandState) -> TailEvent {
    guard !s.transcript.isEmpty,
          let fh = FileHandle(forReadingAtPath: s.transcript) else { return .none }
    defer { try? fh.close() }
    guard let size = try? fh.seekToEnd() else { return .none }
    try? fh.seek(toOffset: size > 64_000 ? size - 64_000 : 0)
    guard let data = try? fh.readToEnd() else { return .none }

    for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
        guard line.hasPrefix("{"),
              let d = line.data(using: .utf8),
              let rec = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let type = rec["type"] as? String, type == "user" || type == "assistant" else { continue }
        let when = isoFrac.date(from: rec["timestamp"] as? String ?? "")?.timeIntervalSince1970 ?? 0
        guard when >= s.since - 1 else { return .none }

        let content = (rec["message"] as? [String: Any])?["content"]
        var texts: [String] = []
        if let str = content as? String { texts = [str] }
        if let blocks = content as? [[String: Any]] {
            texts = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
        }
        let text = texts.joined(separator: " ")

        if type == "assistant" {
            // 伺服器暫時限流（not your usage limit）不算額度用完。
            if rec["isApiErrorMessage"] as? Bool == true, rec["error"] as? String == "rate_limit",
               text.contains("hit your") {
                return .limit(limitDetail(text))
            }
            // 其他 API 錯誤（登入失效、斷線…）：回覆就停在這裡，不處理的話小島會一直顯示 Thinking。
            if rec["isApiErrorMessage"] as? Bool == true {
                let (label, detail) = apiErrorDisplay(rec["error"] as? String ?? "", text)
                return .error(label: label, detail: detail)
            }
            return .none
        }
        return text.contains("Request interrupted by user") ? .interrupted : .none
    }
    return .none
}

// 這輪任務產生的 token（數值同 Claude Code 轉圈圈旁邊的 ↓，但這裡用 ↑ 表示消耗往上加）。
// 同一則回覆會拆成好幾筆紀錄、usage 重複，所以依 message id 去重再加總。
// 只讀上次讀到的位置之後新增的內容，長任務的逐字稿不用每次整份重掃。
final class TurnCounter {
    private var path = ""
    private var since: Double = 0
    private var offset: UInt64 = 0
    private var partial = Data()
    private var perMessage: [String: Int] = [:]

    var total: Int { perMessage.values.reduce(0, +) }

    func update(path: String, since: Double, start: Int) -> Int {
        guard !path.isEmpty, let fh = FileHandle(forReadingAtPath: path) else { return total }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd() else { return total }

        if path != self.path || since != self.since || size < offset {
            self.path = path
            self.since = since
            perMessage = [:]
            partial = Data()
            // 從這輪提問時的檔案位置開始讀；沒記到就退回讀最後 2MB。
            let fallback = size > 2_000_000 ? size - 2_000_000 : 0
            offset = start > 0 && UInt64(start) <= size ? UInt64(start) : fallback
        }
        guard size > offset else { return total }
        try? fh.seek(toOffset: offset)
        guard let chunk = try? fh.readToEnd() else { return total }
        offset = size

        var buf = partial + chunk
        if let last = buf.lastIndex(of: 0x0A) {
            partial = buf[(last + 1)...]
            buf = buf[..<last]
        } else {
            partial = buf
            return total
        }

        for line in buf.split(separator: 0x0A) {
            guard let rec = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  rec["type"] as? String == "assistant",
                  let msg = rec["message"] as? [String: Any],
                  let id = msg["id"] as? String,
                  let u = msg["usage"] as? [String: Any] else { continue }
            let when = isoFrac.date(from: rec["timestamp"] as? String ?? "")?.timeIntervalSince1970 ?? 0
            guard when >= since - 1 else { continue }
            perMessage[id] = max(perMessage[id] ?? 0, u["output_tokens"] as? Int ?? 0)
        }
        return total
    }
}

func fmtTokens(_ n: Double) -> String {
    if n < 1 { return "" }
    if n >= 100_000 { return String(format: "↑ %.0fk", n / 1000) }
    // 10 萬以下顯示完整數字，個位數也在跑，才看得出一直在增加。
    return "↑ " + tokenFormatter.string(from: NSNumber(value: Int(n)))!
}

let tokenFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    return f
}()

// 單一 session 的狀態：何時展開、何時收、token 怎麼滾。
final class SessionTracker {
    let id: String
    var state = IslandState()
    var expanded = false
    var tokensShown: Double = 0      // 顯示用，會慢慢追上實際值

    init(id: String) { self.id = id }

    private var lastTs: Double = 0
    private var doneAt: Date? = nil
    private var pausedAt: Date? = nil
    private var limitAt: Date? = nil
    private var ticks = 0
    private var tokenTarget: Double = 0
    private var turnSince: Double = -1
    private let counter = TurnCounter()
    private var lastSize = -1
    private var lastGrow = Date()
    private var idlePaused = false

    func tick(_ s: IslandState) {
        ticks += 1
        if s.ts != lastTs {
            lastTs = s.ts
            idlePaused = false
            events.append(Date())
            state = s
            expanded = s.phase != "idle"
            doneAt = (s.phase == "done") ? Date() : nil
            pausedAt = (s.phase == "paused") ? Date() : nil
            limitAt = (s.phase == "limit" || s.phase == "error") ? Date() : nil
            // 新的一輪：從 0 開始往上跑。
            if s.since != turnSince {
                turnSince = s.since
                tokenTarget = 0
                tokensShown = 0
                realTokens = 0
                genSeconds = 0
            }
        }

        // session 突然被關掉（關終端機、強制結束）：不會再有任何 hook，程序不見了就立刻停下。
        if expanded, pausedAt == nil, !finishPhases.contains(state.phase), s.pid > 0,
           kill(s.pid, 0) != 0, errno == ESRCH {
            pausedAt = Date()
            state.phase = "stopped"
            state.label = "Stopped"
            state.detail = L("Session 已關閉", "Session closed")
        }

        // 送出後馬上取消（Claude 還沒回任何東西）：逐字稿和 hook 都不會留下紀錄，小島無從得知。
        // 這輪送出後 hook 沒再寫過、逐字稿也好幾秒（設定裡調，預設 10 秒）沒變大，就當作已經停了，自己暫停收起。
        // 只是想得比較久的話，之後逐字稿一變大（或有新的 hook）就恢復顯示。
        if ticks % 3 == 0, !s.transcript.isEmpty {
            let size = (try? FileManager.default.attributesOfItem(atPath: s.transcript)[.size] as? Int) ?? 0
            if size != lastSize {
                lastSize = size
                lastGrow = Date()
                if idlePaused {
                    idlePaused = false
                    pausedAt = nil
                    state = s
                    expanded = true
                }
            }
        }
        if expanded, pausedAt == nil, state.phase == "thinking", !s.transcript.isEmpty,
           s.since > 0, s.ts - s.since < 1,
           idlePauseSeconds > 0, Date().timeIntervalSince(lastGrow) > idlePauseSeconds,
           Date().timeIntervalSince1970 - s.ts > idlePauseSeconds {
            pausedAt = Date()
            idlePaused = true
            state.phase = "paused"
            state.label = "Paused"
            state.detail = ""
        }

        // 中斷 → Paused；額度用完 → Usage limit。明白顯示一陣子再收起來。
        if expanded, pausedAt == nil, limitAt == nil {
            switch tailEvent(s) {
            case .interrupted:
                pausedAt = Date()
                state.phase = "paused"
                state.label = "Paused"
                state.detail = ""
            case .limit(let detail):
                limitAt = Date()
                state.phase = "limit"
                state.label = "Usage limit reached"
                state.detail = detail
            case .error(let label, let detail):
                limitAt = Date()
                state.phase = "error"
                state.label = label
                state.detail = detail
            case .none:
                break
            }
        }
        // hook 寫進來的只是「有錯誤」；從逐字稿讀出是哪一種，換成具體說明。
        if state.phase == "error", state.label == "Error", case .error(let label, let detail) = tailEvent(s) {
            state.label = label
            state.detail = detail
        }

        // 收起來：done / paused / limit 顯示幾秒後，或久久沒有任何更新。
        // 完成時會顯示「完成了什麼」，留久一點讓人看得完。
        if let d = doneAt, Date().timeIntervalSince(d) > 5.0 { expanded = false }
        if let p = pausedAt, Date().timeIntervalSince(p) > 2.5 { expanded = false }
        if s.phase == "stopped", Date().timeIntervalSince1970 - s.ts > 2.5 { expanded = false }
        if let l = limitAt, Date().timeIntervalSince(l) > 15 { expanded = false }
        if Date().timeIntervalSince1970 - s.ts > 120 { expanded = false }

        // token 數：每 0.3 秒讀一次逐字稿新增的部分。
        if ticks % 2 == 0, s.since > 0 {
            let r = s.transcript.isEmpty ? Double(s.outTokens)
                : Double(counter.update(path: s.transcript, since: s.since, start: s.tstart))
            if r != realTokens { realTokens = r; genSeconds = 0 }
        }
        // 逐字稿要等一則回覆寫完才有真的數字，中間用生成速度估算、讓數字一直往上跑。
        // 只在模型產生內容（Thinking）時估；跑工具時模型沒在產生 token，就停著。
        // 估算上限 4000，真的數字一進來就改用真的。
        let generating = state.phase == "thinking"
        let now = Date()
        if generating { genSeconds += now.timeIntervalSince(lastTick) }   // 只累計真的在產生內容的時間
        lastTick = now
        let est = realTokens + min(genSeconds * tokensPerSecond, 4000)
        // 任務進行中數字只往上不往下；結束時才校正回真的數字。
        tokenTarget = finishPhases.contains(state.phase) ? realTokens : max(est, tokenTarget)
        if abs(tokenTarget - tokensShown) > 1 {
            tokensShown += (tokenTarget - tokensShown) * 0.22
        } else {
            tokensShown = tokenTarget
        }
        updateEnergy()
    }

    // 手動收起（在小島上按右鍵）：送出後馬上取消、Claude 還沒回任何東西時，逐字稿不會留下中斷紀錄、
    // 也沒有 hook，小島無從得知，就讓使用者自己收。還在跑的顯示 Paused 一下再收；已經在顯示結果的直接收。
    func dismiss() {
        guard expanded else { return }
        if finishPhases.contains(state.phase) { expanded = false; return }
        pausedAt = Date()
        state.phase = "paused"
        state.label = "Paused"
        state.detail = ""
    }

    // 活躍度 0～1：最近 5 秒的動作密度（每個 hook 事件＝一個動作）加上 token 增加的速度。
    // 單純思考時 token 是估算的等速增加，權重壓低，讓它只到中等速度。
    // 平滑地追過去（約 2～3 秒），光球的轉速跟著它快慢。
    private(set) var energy: Double = 0
    private var events: [Date] = []
    private var lastEnergyAt = Date()
    private var lastTokens: Double = 0

    private func updateEnergy() {
        let now = Date()
        let dt = max(0.05, now.timeIntervalSince(lastEnergyAt))
        lastEnergyAt = now
        events.removeAll { now.timeIntervalSince($0) > 5 }
        let actionRate = Double(events.count) / 5               // 每秒幾個動作
        let tokenRate = max(0, tokensShown - lastTokens) / dt   // 每秒幾個 token
        lastTokens = tokensShown
        let target = finishPhases.contains(state.phase) || !expanded
            ? 0 : min(1, actionRate / 0.7 * 0.7 + tokenRate / 70 * 0.3)
        energy += (target - energy) * 0.06
    }

    private var realTokens: Double = 0
    private var genSeconds: Double = 0
    private var lastTick = Date()
    private let tokensPerSecond: Double = 55     // 大約的生成速度
}

let finishPhases: Set<String> = ["done", "paused", "limit", "error", "stopped"]

// 所有 session 的看板：決定顯示哪一個，並提供左右切換。
// 目前那個還在跑就一直顯示它（不會因為別的任務有動作就被搶走）；它結束了才換到最近有動作的。
final class StateModel: ObservableObject {
    @Published var state = IslandState()
    @Published var expanded = false            // 有任何任務在跑
    @Published var tokensShown: Double = 0
    @Published var pages = 0
    @Published var page = 0
    @Published var slide = 1                   // 最近一次換頁的方向，給轉場用
    @Published var currentID = ""

    private var trackers: [String: SessionTracker] = [:]
    private var lastPhase: [String: String] = [:]
    var popOnFinish = true

    // 目前顯示的任務剛結束（完成／暫停／額度用完／session 結束），還在顯示結果的那幾秒。
    var finishing: Bool { expanded && finishPhases.contains(state.phase) }

    private var active: [SessionTracker] {
        trackers.values.filter { $0.expanded }
            .sorted { ($0.state.since, $0.id) < ($1.state.since, $1.id) }
    }

    func tick() {
        let fm = FileManager.default
        let now = Date().timeIntervalSince1970
        var seen = Set<String>()
        for f in (try? fm.contentsOfDirectory(atPath: sessionsDir)) ?? [] where f.hasSuffix(".json") {
            if demoActive && !f.hasPrefix("demo") { continue }      // 示範中只顯示示範的任務
            let id = String(f.dropLast(5))
            let path = sessionsDir + "/" + f
            guard let s = loadState(path) else { continue }
            if now - s.ts > 6 * 3600 { try? fm.removeItem(atPath: path); continue }
            if now - s.ts > 120, trackers[id] == nil { continue }   // 早就結束的不用追
            seen.insert(id)
            let t = trackers[id] ?? SessionTracker(id: id)
            trackers[id] = t
            t.tick(s)
        }
        trackers = trackers.filter { seen.contains($0.key) }

        let act = active
        // 別頁的任務剛結束：切過去讓你看到結果，它收起來後會自動換回還在跑的那個。
        for t in act where popOnFinish && t.id != currentID
            && finishPhases.contains(t.state.phase) && lastPhase[t.id] != t.state.phase {
            select(t.id, in: act)
        }
        lastPhase = trackers.mapValues { $0.state.phase }

        if !act.contains(where: { $0.id == currentID }),
           let next = act.max(by: { $0.state.ts < $1.state.ts }) {
            select(next.id, in: act)
        }
        publish(act)
    }

    func dismissCurrent() {
        trackers[currentID]?.dismiss()
        publish(active)
    }

    // dir：1 往下一個、-1 往上一個。到頭就停，不繞圈。
    func flip(_ dir: Int) {
        let act = active
        guard act.count > 1, let i = act.firstIndex(where: { $0.id == currentID }) else { return }
        let j = i + dir
        guard act.indices.contains(j) else { return }
        select(act[j].id, in: act)
        publish(act)
    }

    private func select(_ id: String, in act: [SessionTracker]) {
        let old = act.firstIndex(where: { $0.id == currentID }) ?? -1
        let new = act.firstIndex(where: { $0.id == id }) ?? 0
        slide = new >= old ? 1 : -1
        currentID = id
    }

    private var lastTokenPush = Date.distantPast
    private var lastTokenID = ""

    private func publish(_ act: [SessionTracker]) {
        orbEnergy = trackers[currentID]?.energy ?? 0
        if let c = trackers[currentID] {
            if state != c.state { state = c.state }
            // token 數最多每 1 秒更新一次畫面：每次更新都會觸發數字滾動和整個小島重排，太頻繁很耗電。
            // 換頁或任務結束時立刻更新。
            if tokensShown != c.tokensShown {
                let now = Date()
                if c.id != lastTokenID || finishPhases.contains(c.state.phase)
                    || now.timeIntervalSince(lastTokenPush) >= 1 {
                    tokensShown = c.tokensShown
                    lastTokenPush = now
                    lastTokenID = c.id
                }
            }
        }
        let e = !act.isEmpty
        if expanded != e { expanded = e }
        if pages != act.count { pages = act.count }
        let p = act.firstIndex(where: { $0.id == currentID }) ?? 0
        if page != p { page = p }
    }
}

// MARK: - 外框：上緣貼齊螢幕、兩側內凹、下緣圓角

struct IslandShape: Shape {
    var wing: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(wing, radius) }
        set { wing = newValue.first; radius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let x0 = rect.minX + wing
        let x1 = rect.maxX - wing
        let top = rect.minY
        let bottom = rect.maxY
        let r = min(radius, (x1 - x0) / 2, rect.height)

        p.move(to: CGPoint(x: rect.minX, y: top))
        if wing > 0.5 {
            p.addCurve(to: CGPoint(x: x0, y: top + wing),
                       control1: CGPoint(x: rect.minX + wing * 0.5, y: top),
                       control2: CGPoint(x: x0, y: top + wing * 0.5))
        }
        p.addLine(to: CGPoint(x: x0, y: bottom - r))
        p.addArc(center: CGPoint(x: x0 + r, y: bottom - r),
                 radius: r, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        p.addLine(to: CGPoint(x: x1 - r, y: bottom))
        p.addArc(center: CGPoint(x: x1 - r, y: bottom - r),
                 radius: r, startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
        p.addLine(to: CGPoint(x: x1, y: top + wing))
        if wing > 0.5 {
            p.addCurve(to: CGPoint(x: rect.maxX, y: top),
                       control1: CGPoint(x: x1, y: top + wing * 0.5),
                       control2: CGPoint(x: rect.maxX - wing * 0.5, y: top))
        }
        p.closeSubpath()
        return p
    }
}

// MARK: - 設定（存在 tuning.json，設定面板即時改）

enum DisplayMode: String, Codable, CaseIterable {
    case auto, always, hover
    var title: String {
        switch self {
        case .auto: return L("自動", "Auto")
        case .always: return L("常駐", "Always")
        case .hover: return L("滑鼠靠近", "On hover")
        }
    }
    var hint: String {
        switch self {
        case .auto: return L("有任務時展開，完成後縮回瀏海。滑鼠碰到瀏海也會展開。", "Expands while a task runs and shrinks back into the notch when it's done. Hovering the notch also expands it.")
        case .always: return L("一直展開；沒有任務時顯示 Ready。", "Always expanded; shows Ready when there's no task.")
        case .hover: return L("平常縮在瀏海裡，滑鼠碰到瀏海才展開。", "Stays tucked in the notch and expands only when you hover it.")
        }
    }
}

struct Tuning: Codable, Equatable {
    var mode: DisplayMode = .auto
    var external = true            // 舊設定（跟著滑鼠換螢幕）；現在改看 screenSwitch，留著讀舊檔
    // 多螢幕時小島怎麼換螢幕："top" 滑鼠碰到那個螢幕的頂端才丟過去／"follow" 滑鼠在哪就跟到哪／"fixed" 固定主螢幕
    var screenSwitch = "top"
    var vGap: Double = 16          // 瀏海下緣到內容、內容到島底
    var sidePad: Double = 32       // 內容到內凹之間的左右留白
    var lineGap: Double = 8        // 兩行之間
    var wing: Double = 28          // 兩側內凹寬度
    var radius: Double = 28        // 下緣圓角
    var minWidth: Double = 320
    var maxWidth: Double = 480
    var labelSize: Double = 17
    var detailSize: Double = 14
    var iconCell: Double = 6       // 圖示每一格的邊長（光核的大小也跟著它）
    var iconStyle = "pixel"        // "pixel" 像素格 / "orb" 光核
    var orbAura = true             // 小島底部的漸層光（沿用舊的設定名稱，已存的開關才不會失效）
    var showTitle = true           // 多個任務時在最上面顯示 session 標題
    var titleSize: Double = 10.5
    var bounce: Double = 55        // 展開／收合的彈跳程度，0 不彈、100 最彈
    var popOnFinish = true         // 任務結束時，就算小島沒在顯示也彈出來提醒
    var systemNotify = true        // 完成時發 macOS 系統通知（hook/notify.py 讀這兩個）
    var completionSound = true     // 完成時播音效
    var idlePause: Double = 10     // 送出後幾秒完全沒動靜就自動暫停（0 = 不自動暫停）
    var catScene = true            // 小島底部的點陣貓咪場景
    var autoUpdate = true          // 每天去 GitHub 檢查新版本
    var language = "auto"          // 介面語言："auto" 跟系統／"zh" 中文／"en" English
    var codexEnabled = true        // 也顯示 Codex 的任務（讀 ~/.codex/sessions 的紀錄）
    var funVerbs = false           // Thinking 改成 Whirring…、Pondering… 這類趣味動詞（預設用好懂的 Thinking）
    var yieldOnHover = true        // 滑鼠經過展開的小島時先縮回瀏海讓開
    var showDetail = true          // 最上面那行細節（正在讀的檔案、跑的指令…）
    var showLabel = true           // 狀態字（Thinking、Running command…）
    var showTokens = true          // token 數
    var showIcon = true            // 狀態字左邊的圖示（光核／像素格）；有貓的時候可以關掉
    var sound = "zen-success"      // 音效名稱：repo sounds/ 的檔名或 macOS 內建音效名（hook/notify.py 用同一套規則找檔案）

    init() {}

    // 舊版 tuning.json 少了新欄位時，用預設值補上，不要整份讀失敗。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Tuning()
        mode = try c.decodeIfPresent(DisplayMode.self, forKey: .mode) ?? d.mode
        external = try c.decodeIfPresent(Bool.self, forKey: .external) ?? d.external
        screenSwitch = try c.decodeIfPresent(String.self, forKey: .screenSwitch) ?? (external ? "top" : "fixed")
        vGap = try c.decodeIfPresent(Double.self, forKey: .vGap) ?? d.vGap
        sidePad = try c.decodeIfPresent(Double.self, forKey: .sidePad) ?? d.sidePad
        lineGap = try c.decodeIfPresent(Double.self, forKey: .lineGap) ?? d.lineGap
        wing = try c.decodeIfPresent(Double.self, forKey: .wing) ?? d.wing
        radius = try c.decodeIfPresent(Double.self, forKey: .radius) ?? d.radius
        minWidth = try c.decodeIfPresent(Double.self, forKey: .minWidth) ?? d.minWidth
        maxWidth = try c.decodeIfPresent(Double.self, forKey: .maxWidth) ?? d.maxWidth
        labelSize = try c.decodeIfPresent(Double.self, forKey: .labelSize) ?? d.labelSize
        detailSize = try c.decodeIfPresent(Double.self, forKey: .detailSize) ?? d.detailSize
        iconCell = try c.decodeIfPresent(Double.self, forKey: .iconCell) ?? d.iconCell
        iconStyle = try c.decodeIfPresent(String.self, forKey: .iconStyle) ?? d.iconStyle
        orbAura = try c.decodeIfPresent(Bool.self, forKey: .orbAura) ?? d.orbAura
        showTitle = try c.decodeIfPresent(Bool.self, forKey: .showTitle) ?? d.showTitle
        titleSize = try c.decodeIfPresent(Double.self, forKey: .titleSize) ?? d.titleSize
        bounce = try c.decodeIfPresent(Double.self, forKey: .bounce) ?? d.bounce
        popOnFinish = try c.decodeIfPresent(Bool.self, forKey: .popOnFinish) ?? d.popOnFinish
        systemNotify = try c.decodeIfPresent(Bool.self, forKey: .systemNotify) ?? d.systemNotify
        completionSound = try c.decodeIfPresent(Bool.self, forKey: .completionSound) ?? d.completionSound
        sound = try c.decodeIfPresent(String.self, forKey: .sound) ?? d.sound
        idlePause = try c.decodeIfPresent(Double.self, forKey: .idlePause) ?? d.idlePause
        catScene = try c.decodeIfPresent(Bool.self, forKey: .catScene) ?? d.catScene
        autoUpdate = try c.decodeIfPresent(Bool.self, forKey: .autoUpdate) ?? d.autoUpdate
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
        codexEnabled = try c.decodeIfPresent(Bool.self, forKey: .codexEnabled) ?? d.codexEnabled
        funVerbs = try c.decodeIfPresent(Bool.self, forKey: .funVerbs) ?? d.funVerbs
        yieldOnHover = try c.decodeIfPresent(Bool.self, forKey: .yieldOnHover) ?? d.yieldOnHover
        showDetail = try c.decodeIfPresent(Bool.self, forKey: .showDetail) ?? d.showDetail
        showLabel = try c.decodeIfPresent(Bool.self, forKey: .showLabel) ?? d.showLabel
        showTokens = try c.decodeIfPresent(Bool.self, forKey: .showTokens) ?? d.showTokens
        showIcon = try c.decodeIfPresent(Bool.self, forKey: .showIcon) ?? d.showIcon
    }
}

// 設定裡的「送出後沒動靜自動暫停」秒數，SessionTracker 讀它（計時器每次更新時從設定同步過來）
var idlePauseSeconds: Double = 10
let openDemoNotification = Notification.Name("AgentIslandOpenDemo")

let tuningPath = islandDataDir + "/tuning.json"

final class TuningStore: ObservableObject {
    @Published var t: Tuning { didSet { save() } }
    @Published var preview = false      // 在真的螢幕上用範例內容展開

    init() {
        if let d = FileManager.default.contents(atPath: tuningPath),
           let v = try? JSONDecoder().decode(Tuning.self, from: d) {
            t = v
        } else {
            t = Tuning()
        }
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(t) { try? d.write(to: URL(fileURLWithPath: tuningPath)) }
    }
}

// MARK: - 顯示內容與尺寸（小島本體和設定面板的預覽共用）

// 依設定把不想顯示的部分拿掉（上面那行、狀態字、token 數），小島會跟著變小
extension Display {
    func shown(_ t: Tuning) -> Display {
        var d = self
        if !t.showDetail { d.topLine = "" }
        if !t.showLabel { d.label = "" }
        if !t.showTokens { d.tokens = "" }
        return d
    }
    func hasStatusRow(_ t: Tuning) -> Bool { t.showIcon || !label.isEmpty || !tokens.isEmpty }
}

struct Display: Equatable {
    var phase: String
    var label: String
    var topLine: String
    var tokens: String
    var title = ""      // 多個任務時最上面那行小標題
    var key = ""        // 哪個任務；換任務時內容整塊滑動替換
    var pages = 0
    var page = 0
    var slide = 1

    static let sample = Display(phase: "working", label: "Creating prototype",
                                topLine: "Read sidebar.tsx  741 lines", tokens: "↑ 4,321")
    static let ready = Display(phase: "idle", label: "Ready", topLine: "", tokens: "")
}

// 量字寬很慢，而滑鼠追蹤每 0.05 秒就要算一次小島大小：量過的字記起來，不重量。
private var widthCache: [String: CGFloat] = [:]

func textWidth(_ s: String, size: CGFloat, weight: NSFont.Weight, rounded: Bool = false) -> CGFloat {
    guard !s.isEmpty else { return 0 }
    let key = "\(size)|\(weight.rawValue)|\(rounded)|\(s)"
    if let w = widthCache[key] { return w }
    var f = NSFont.systemFont(ofSize: size, weight: weight)
    if rounded, let d = f.fontDescriptor.withDesign(.rounded) {
        f = NSFont(descriptor: d, size: size) ?? f
    }
    let w = ceil((s as NSString).size(withAttributes: [.font: f]).width)
    if widthCache.count > 400 { widthCache.removeAll() }
    widthCache[key] = w
    return w
}

func glyphSide(_ t: Tuning) -> CGFloat {
    let c = CGFloat(t.iconCell)
    return c * 3 + max(1, (c / 3).rounded()) * 2
}

func islandSize(_ d0: Display, _ t: Tuning, top: CGFloat, collapsed: CGSize, expanded: Bool) -> CGSize {
    guard expanded else { return collapsed }
    let d = d0.shown(t)
    let l1 = max(textWidth(d.topLine, size: t.detailSize, weight: .regular),
                 textWidth(d.title, size: t.titleSize, weight: .semibold))
    var l2 = (t.showIcon ? glyphSide(t) + 10 : 0) + textWidth(d.label, size: t.labelSize, weight: .medium)
    if !d.tokens.isEmpty { l2 += 8 + textWidth(d.tokens, size: 11.5, weight: .medium, rounded: true) }
    let inset = CGFloat(t.wing + t.sidePad)
    let content = max(l1, l2) + 8      // 量出來的字寬和實際排版有些微出入，留點餘裕免得被截斷
    let w = min(t.maxWidth, max(t.minWidth, collapsed.width, content + inset * 2))
    let l1h = (d.topLine.isEmpty ? 0 : ceil(t.detailSize * 1.25) + t.lineGap)
        + (d.title.isEmpty ? 0 : ceil(t.titleSize * 1.25) + titleGap)
    let dots = d.pages > 1 ? dotSize + t.lineGap : 0
    let scene = t.catScene ? catSceneHeight : 0           // 底部的貓咪場景
    // 圖示、狀態字、token 數都關掉時，整排不佔高度（上面那行和這排之間的行距也拿掉）
    let row = d.hasStatusRow(t) ? max(t.showIcon ? glyphSide(t) : 0, d.label.isEmpty ? 0 : ceil(t.labelSize * 1.25)) : -(l1h > 0 ? t.lineGap : 0)
    let h = top + t.vGap + l1h + row + dots + t.vGap + scene
    return CGSize(width: w, height: h)
}

// MARK: - 動態：狀態字逐字替換、完成慶祝

// 狀態字換掉時：舊字整段往上飄走、變模糊；新字一個字一個字從下方浮上來，由模糊變清楚。
struct RollingLabel: View {
    let text: String
    let size: CGFloat

    var body: some View {
        ZStack {
            StaggeredWord(text: text, size: size)
                .id(text)
                .transition(.asymmetric(
                    insertion: .identity,
                    removal: .offset(y: -size * 0.8).combined(with: .blurOut(6))
                        .animation(.easeIn(duration: 0.18))))
        }
        .animation(.easeOut(duration: 0.2), value: text)
    }
}

// 工作中的狀態字：字本身暗一點，一道亮光由左往右掃過（掃 0.9 秒、停 0.6 秒）。
// 只動遮罩、不重畫文字；換到完成／閒置等狀態時亮光停掉，字回到全白。
struct Shimmer: ViewModifier {
    let on: Bool
    private let sweep = 0.9, pause = 0.6
    @Environment(\.islandLive) private var live

    func body(content: Content) -> some View {
        content.mask(
            GeometryReader { geo in
                TimelineView(.animation(minimumInterval: frameInterval, paused: !on || !live)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: sweep + pause)
                    let p = min(1, t / sweep)
                    let w = geo.size.width, band = max(36, w * 0.4)
                    ZStack(alignment: .leading) {
                        Color.white.opacity(on ? 0.45 : 1)
                        LinearGradient(colors: [.white.opacity(0), .white, .white.opacity(0)],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: band)
                            .offset(x: -band + (w + band) * p)
                            .opacity(on ? 1 : 0)
                    }
                    .animation(.easeOut(duration: 0.3), value: on)
                }
            }
        )
    }
}

// 內容換掉時先模糊淡出，新內容再從模糊變清楚。舊的完全淡掉之前新的就開始浮現，交疊一點比較順。
struct BlurSwap<Content: View>: View {
    let key: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            content()
                .id(key)
                .transition(.asymmetric(
                    insertion: .blurOut(8).animation(.easeOut(duration: 0.32).delay(0.08)),
                    removal: .blurOut(8).animation(.easeIn(duration: 0.16))))
        }
        .animation(.easeOut(duration: 0.32), value: key)
    }
}

struct BlurFade: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        content.blur(radius: radius).opacity(radius == 0 ? 1 : 0)
    }
}

extension AnyTransition {
    static func blurOut(_ r: CGFloat) -> AnyTransition {
        .modifier(active: BlurFade(radius: r), identity: BlurFade(radius: 0))
    }
}

struct StaggeredWord: View {
    let text: String
    let size: CGFloat
    @State private var shown = false

    var body: some View {
        let chars = Array(text)
        HStack(spacing: 0) {
            ForEach(chars.indices, id: \.self) { i in
                Text(String(chars[i]))
                    .font(.system(size: size, weight: .medium))
                    .foregroundColor(.white)
                    .opacity(shown ? 1 : 0)
                    .blur(radius: shown ? 0 : 5)
                    .offset(y: shown ? 0 : size * 0.7)
                    .scaleEffect(shown ? 1 : 0.8, anchor: .bottom)
                    // 字越多、每個字的間隔越短，整段大約 0.35 秒內跑完。
                    .animation(.spring(response: 0.42, dampingFraction: 0.72)
                                .delay(Double(i) * min(0.03, 0.35 / Double(max(chars.count, 1)))),
                               value: shown)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .onAppear { shown = true }
    }
}

// 完成時：圖示彈一下，兩圈綠色光環往外擴散，一圈小光點向外噴散後淡掉。
struct Celebration: View {
    let active: Bool
    let size: CGFloat
    @State private var fire = 0
    private let green = Color(NSColor(srgbRed: 0.45, green: 0.83, blue: 0.55, alpha: 1))

    var body: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { ring in
                Circle()
                    .stroke(green, lineWidth: 1.6)
                    .frame(width: size, height: size)
                    .keyframeAnimator(initialValue: Burst(), trigger: fire) { v, b in
                        v.scaleEffect(b.scale).opacity(b.opacity)
                    } keyframes: { _ in
                        KeyframeTrack(\.scale) {
                            LinearKeyframe(0.6, duration: 0.05 + Double(ring) * 0.14)
                            CubicKeyframe(1.9 + Double(ring) * 0.45, duration: 0.7)
                        }
                        KeyframeTrack(\.opacity) {
                            LinearKeyframe(0, duration: 0.05 + Double(ring) * 0.14)
                            LinearKeyframe(0.9, duration: 0.06)
                            CubicKeyframe(0, duration: 0.64)
                        }
                    }
            }
            ForEach(0..<10, id: \.self) { i in
                let angle = Double(i) / 10 * 2 * .pi
                Circle()
                    .fill(green)
                    .frame(width: 3, height: 3)
                    .keyframeAnimator(initialValue: Burst(), trigger: fire) { v, b in
                        v.offset(x: cos(angle) * b.distance, y: sin(angle) * b.distance)
                            .scaleEffect(b.scale).opacity(b.opacity)
                    } keyframes: { _ in
                        KeyframeTrack(\.distance) {
                            LinearKeyframe(size * 0.4, duration: 0.08)
                            // 往外噴，但留在小島的黑底範圍內（圖示離島底只有十幾 pt）。
                            CubicKeyframe(size * (0.95 + Double(i % 3) * 0.15), duration: 0.6)
                        }
                        KeyframeTrack(\.opacity) {
                            LinearKeyframe(0, duration: 0.08)
                            LinearKeyframe(1, duration: 0.05)
                            CubicKeyframe(0, duration: 0.55)
                        }
                        KeyframeTrack(\.scale) {
                            LinearKeyframe(1.3, duration: 0.13)
                            CubicKeyframe(0.3, duration: 0.55)
                        }
                    }
            }
        }
        .allowsHitTesting(false)
        .onAppear { if active { fire += 1 } }
        .onChange(of: active) { _, now in if now { fire += 1 } }
    }
}

struct Burst {
    var scale: CGFloat = 1
    var opacity: Double = 0
    var distance: CGFloat = 0
}

let dotSize: CGFloat = 5
let titleGap: CGFloat = 3      // 標題和下面那行靠近一點，看得出是同一組

struct PageDots: View {
    let pages: Int
    let page: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<pages, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(i == page ? 0.85 : 0.25))
                    .frame(width: i == page ? dotSize * 2.4 : dotSize, height: dotSize)
            }
        }
    }
}

struct IslandBody: View {
    let d: Display
    let t: Tuning
    let top: CGFloat            // 內容要避開的頂部高度（瀏海高）
    let collapsed: CGSize
    let expanded: Bool
    @State private var collapses = 0

    var body: some View {
        let d = self.d.shown(t)
        let size = islandSize(d, t, top: top, collapsed: collapsed, expanded: expanded)
        let inset = CGFloat(t.wing + t.sidePad)
        let pop = 1 + 0.09 * t.bounce / 100
        ZStack(alignment: .top) {
            IslandShape(wing: expanded ? t.wing : 0, radius: expanded ? t.radius : 10)
                .fill(Color.black)
                .overlay(
                    // 只放在小島本體（扣掉兩側內凹的翼），下緣圓角由底部光自己裁切
                    BottomGlow(phase: d.phase, style: t.iconStyle, on: t.orbAura && d.phase != "idle",
                               radius: t.radius)
                        .padding(.horizontal, t.wing)
                        .opacity(expanded && t.orbAura && d.phase != "idle" ? 1 : 0)
                        .animation(.easeInOut(duration: 0.5), value: expanded)
                )
                .overlay(alignment: .bottom) {
                    if t.catScene {
                        CatSceneView(phase: d.phase, running: expanded, radius: t.radius, maxWidth: t.maxWidth)
                            .frame(height: catSceneHeight)
                            .padding(.horizontal, t.wing)
                            .opacity(expanded ? 1 : 0)
                            .animation(.easeInOut(duration: 0.4), value: expanded)
                    }
                }
                .frame(width: size.width, height: size.height)
                // 底部光和貓咪場景是原生圖層，尺寸會直接跳到終點；用跟黑底一樣（會跟著動畫變形）的形狀裁切，才不會露出黑底外
                .clipShape(IslandShape(wing: expanded ? t.wing : 0, radius: expanded ? t.radius : 10))
                // 收合的彈簧過衝會藏在瀏海裡看不到，所以縮回去之後再從瀏海「啵」地彈一下。
                .keyframeAnimator(initialValue: 1.0, trigger: collapses) { v, s in
                    v.scaleEffect(s, anchor: .top)
                } keyframes: { _ in
                    KeyframeTrack {
                        LinearKeyframe(1.0, duration: 0.32)
                        SpringKeyframe(pop, duration: 0.12, spring: .snappy)
                        SpringKeyframe(1.0, duration: 0.45, spring: .bouncy)
                    }
                }
                .onChange(of: expanded) { _, now in
                    if !now, t.bounce > 0 { collapses += 1 }
                }

            VStack(spacing: t.lineGap) {
                content
                    .id(d.key)
                    .transition(.asymmetric(
                        insertion: .offset(x: d.slide > 0 ? 60 : -60).combined(with: .opacity),
                        removal: .offset(x: d.slide > 0 ? -60 : 60).combined(with: .opacity)))
                if d.pages > 1 {
                    PageDots(pages: d.pages, page: d.page)
                }
            }
            .frame(width: max(0, size.width - inset * 2))
            .padding(.top, top + t.vGap)
            // 左右滑動換頁時字會往旁邊滑，裁在黑底裡面，不超出小島
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipShape(IslandShape(wing: expanded ? t.wing : 0, radius: expanded ? t.radius : 10))
            .opacity(expanded ? 1 : 0)
            .scaleEffect(expanded ? 1 : 0.9, anchor: .top)
            .blur(radius: expanded ? 0 : 8)
            // 收合時字先淡掉，展開時等外框長出來一點再浮現。
            .animation(expanded ? .easeOut(duration: 0.28).delay(0.08) : .easeIn(duration: 0.14),
                       value: expanded)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.islandLive, expanded)
    }

    var content: some View {
        let d = self.d.shown(t)
        return VStack(spacing: t.lineGap) {
                if !d.title.isEmpty {
                    BlurSwap(key: d.title) {
                        Text(d.title)
                            .font(.system(size: t.titleSize, weight: .semibold))
                            .foregroundColor(.white.opacity(0.78))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.bottom, titleGap - t.lineGap)
                }
                if !d.topLine.isEmpty {
                    BlurSwap(key: d.topLine) {
                        Text(d.topLine)
                            .font(.system(size: t.detailSize, weight: .regular))
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                if d.hasStatusRow(t) {
                HStack(spacing: 10) {
                    if t.showIcon {
                    BlurSwap(key: d.phase + t.iconStyle) {
                        if t.iconStyle == "orb" {
                            DotOrbView(phase: d.phase, size: glyphSide(t))
                        } else {
                            PixelView(phase: d.phase, size: glyphSide(t))
                        }
                    }
                        .keyframeAnimator(initialValue: 1.0, trigger: d.phase == "done") { v, s in
                            v.scaleEffect(s)
                        } keyframes: { _ in
                            KeyframeTrack {
                                SpringKeyframe(0.7, duration: 0.1, spring: .snappy)
                                SpringKeyframe(1.35, duration: 0.18, spring: .snappy)
                                SpringKeyframe(1.0, duration: 0.5, spring: .bouncy)
                            }
                        }
                        // 光核的完成是點自己排成打勾，不再另外噴慶祝光點
                        .overlay(t.iconStyle == "orb" ? nil : Celebration(active: d.phase == "done", size: glyphSide(t)))
                    }
                    if !d.label.isEmpty {
                    RollingLabel(text: d.label, size: t.labelSize)
                        .modifier(Shimmer(on: !["done", "idle", "paused", "stopped", "error", "limit"].contains(d.phase)))
                    }
                    if !d.tokens.isEmpty {
                        Text(d.tokens)
                            .font(.system(size: 11.5, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText(countsDown: false))   // 每一位數各自往上滾
                            .animation(.snappy(duration: 0.25), value: d.tokens)
                            .foregroundColor(.white.opacity(0.35))
                            .lineLimit(1)
                    }
                }
                }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 每個螢幕各一個小島

final class ScreenState: ObservableObject {
    @Published var hover = false
    @Published var yielded = false     // 滑鼠經過小島本體，小島先縮回瀏海讓開
}

// 目前由哪個螢幕的小島負責顯示。滑鼠移到哪個螢幕就切過去，之後一直留在那邊。
final class Presence: ObservableObject {
    @Published var active = 0      // 螢幕的 displayID
}

func displayID(_ s: NSScreen) -> Int {
    s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? Int ?? 0
}

struct PillView: View {
    @ObservedObject var model: StateModel
    @ObservedObject var tuning: TuningStore
    @ObservedObject var screen: ScreenState
    @ObservedObject var presence: Presence
    let id: Int
    let top: CGFloat
    let collapsed: CGSize

    var body: some View {
        let exp = isExpanded(model: model, tuning: tuning, hover: screen.hover,
                             active: presence.active == id, yielded: screen.yielded)
        let d = currentDisplay(model: model, tuning: tuning, expanded: exp)
        IslandBody(d: d, t: tuning.t, top: top, collapsed: collapsed, expanded: exp)
            // 阻尼越低越彈：展開會衝過頭再回來；收合會先縮過頭（藏在瀏海裡），再彈出一點點才定住。
            .animation(.spring(response: 0.5, dampingFraction: max(0.3, 1 - tuning.t.bounce / 100 * 0.75)),
                       value: exp)
            .animation(.spring(response: 0.34, dampingFraction: 0.85), value: d)
            .animation(.spring(response: 0.25, dampingFraction: 0.9), value: tuning.t)
    }
}

func isExpanded(model: StateModel, tuning: TuningStore, hover: Bool, active: Bool, yielded: Bool = false) -> Bool {
    guard active else { return false }
    if tuning.preview { return true }
    if yielded { return false }                    // 滑鼠經過時讓開
    if hover { return true }
    switch tuning.t.mode {
    case .always: return true
    case .hover: return tuning.t.popOnFinish && model.finishing
    case .auto: return model.expanded
    }
}

// 想事情時顯示的字：取自 Claude Code 轉圈時用的清單（原字照抄，從安裝的 Claude Code 裡找出來的），
// 只挑一般人一看就懂的常見字，中英文介面都用英文原字。Claude Code 不會告訴 hook 它當下選了哪個字，
// 所以小島是自己挑：同一輪固定一組順序，每 8 秒換下一個。
let thinkingVerbs = ["Thinking", "Pondering", "Whirring", "Brewing", "Cooking", "Baking", "Crafting", "Creating",
                     "Computing", "Calculating", "Considering", "Processing", "Generating", "Imagining", "Sketching", "Composing",
                     "Doodling", "Spinning", "Swirling", "Flowing", "Wandering", "Tinkering", "Working", "Puzzling",
                     "Grooving", "Vibing", "Moonwalking", "Orbiting", "Improvising", "Clauding"]

func shownLabel(_ s: IslandState, _ t: Tuning) -> String {
    let label = s.label.isEmpty ? "Working" : s.label
    guard t.funVerbs, s.phase == "thinking", label == "Thinking" else { return label }
    let step = Int(Date().timeIntervalSince1970 / 8)
    let seed = Int(s.since.truncatingRemainder(dividingBy: 100_000) * 7) + step * 13
    return thinkingVerbs[((seed % thinkingVerbs.count) + thinkingVerbs.count) % thinkingVerbs.count] + "…"
}

func currentDisplay(model: StateModel, tuning: TuningStore, expanded: Bool) -> Display {
    let top = model.state.detail.isEmpty ? model.state.task : model.state.detail
    // 同時有好幾個任務時，最上面加一行 session 標題，分得出是哪一個；還沒有標題就用專案名稱。
    let name = model.state.title.isEmpty ? model.state.project : model.state.title
    let title = model.pages > 1 && tuning.t.showTitle ? name : ""
    let live = Display(phase: model.state.phase,
                       label: shownLabel(model.state, tuning.t),
                       topLine: top,
                       tokens: fmtTokens(model.tokensShown),
                       title: title, key: model.currentID, pages: model.pages, page: model.page, slide: model.slide)
    if model.expanded { return live }
    if tuning.preview { return .sample }
    // 沒有任務卻展開（常駐或滑鼠靠近）時顯示 Ready；收合途中維持原內容讓它淡出。
    return expanded ? .ready : live
}

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class IslandController {
    let screen: NSScreen
    let primary: Bool
    let id: Int
    let panel: IslandPanel
    let state = ScreenState()
    let top: CGFloat
    let collapsed: CGSize
    private var leftAt: Date?
    static let panelHeight: CGFloat = 240

    init(screen: NSScreen, primary: Bool, model: StateModel, tuning: TuningStore, presence: Presence) {
        self.screen = screen
        self.primary = primary
        self.id = displayID(screen)
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            let notch = CGSize(width: screen.frame.width - l.width - r.width, height: l.height)
            top = notch.height
            collapsed = notch
        } else {
            // 沒有瀏海：收合時高度為 0，從螢幕上緣往下長出來。
            top = primary ? max(24, screen.safeAreaInsets.top) : 0
            collapsed = CGSize(width: primary ? 200 : 180, height: primary ? top : 0)
        }

        let f = NSRect(x: screen.frame.minX, y: screen.frame.maxY - Self.panelHeight,
                       width: screen.frame.width, height: Self.panelHeight)
        panel = IslandPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: PillView(
            model: model, tuning: tuning, screen: state, presence: presence,
            id: id, top: top, collapsed: collapsed))
        panel.setFrame(f, display: true)
        panel.orderFrontRegardless()
    }

    func close() { panel.orderOut(nil) }

    // 滑鼠在熱區裡就展開；離開後稍等一下才收，免得邊緣抖動時一直開開關關。
    func trackMouse(_ p: NSPoint, model: StateModel, tuning: TuningStore, presence: Presence) {
        let exp = isExpanded(model: model, tuning: tuning, hover: state.hover,
                             active: presence.active == id, yielded: state.yielded)
        let d = currentDisplay(model: model, tuning: tuning, expanded: exp)
        let size = islandSize(d, tuning.t, top: top, collapsed: collapsed, expanded: exp)
        updateYield(p, model: model, tuning: tuning, presence: presence)
        let zone: NSRect
        if exp {
            zone = NSRect(x: screen.frame.midX - size.width / 2 - 8, y: screen.frame.maxY - size.height - 8,
                          width: size.width + 16, height: size.height + 9)
        } else if collapsed.height > 0 {
            zone = NSRect(x: screen.frame.midX - collapsed.width / 2 - 12, y: screen.frame.maxY - collapsed.height,
                          width: collapsed.width + 24, height: collapsed.height + 1)
        } else {
            zone = NSRect(x: screen.frame.midX - 160, y: screen.frame.maxY - 4, width: 320, height: 5)
        }

        // 平常完全不攔滑鼠；只有指標停在展開的小島上時才接收，好收到雙指滑動和右鍵收起。
        // 讓開的時候小島是收起來的，所以滑鼠直接點得到下面的東西。
        let grab = zone.contains(p) && exp && model.expanded
        if panel.ignoresMouseEvents == grab { panel.ignoresMouseEvents = !grab }

        if zone.contains(p) {
            leftAt = nil
            if !state.hover { state.hover = true }
        } else if state.hover {
            if leftAt == nil { leftAt = Date() }
            if let l = leftAt, Date().timeIntervalSince(l) > 0.35 {
                state.hover = false
                leftAt = nil
            }
        }
    }

    // 滑鼠經過時讓開：指標進到展開小島的本體（會擋住畫面的地方）就縮回瀏海；
    // 一直縮著，直到指標離開原本小島的範圍才長回來，不會一閃一閃。
    // 指標碰到最上面的瀏海那一塊則維持展開，照樣可以雙指滑動換頁、按右鍵收起。
    private func updateYield(_ p: NSPoint, model: StateModel, tuning: TuningStore, presence: Presence) {
        guard tuning.t.yieldOnHover, presence.active == id else {
            if state.yielded { state.yielded = false }
            return
        }
        let full = islandSize(currentDisplay(model: model, tuning: tuning, expanded: true), tuning.t,
                              top: top, collapsed: collapsed, expanded: true)
        let body = NSRect(x: screen.frame.midX - full.width / 2 - 4, y: screen.frame.maxY - full.height - 4,
                          width: full.width + 8, height: full.height + 4)
        let notchH = max(collapsed.height, 6)
        let notch = NSRect(x: screen.frame.midX - max(collapsed.width, 200) / 2 - 12, y: screen.frame.maxY - notchH,
                           width: max(collapsed.width, 200) + 24, height: notchH + 1)
        if state.yielded {
            if !body.contains(p) || notch.contains(p) { state.yielded = false }
        } else if body.contains(p) && !notch.contains(p)
                    && isExpanded(model: model, tuning: tuning, hover: state.hover, active: true) {
            state.yielded = true
            state.hover = false
        }
    }
}

// MARK: - 設定面板

struct PreviewCard: View {
    let t: Tuning
    let notch = CGSize(width: 208, height: 37.5)

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.20, green: 0.52, blue: 0.72),
                                    Color(red: 0.07, green: 0.12, blue: 0.22)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            IslandBody(d: .sample, t: t, top: notch.height, collapsed: notch, expanded: true)
                .animation(.spring(response: 0.25, dampingFraction: 0.9), value: t)
        }
        .frame(height: 170)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08)))
    }
}

// 完成音效：repo 的 sounds/ 加上 macOS 內建音效。選了就先播一次，旁邊的按鈕可以再聽。
// 音效打包在 app 裡（Contents/Resources/sounds）
let repoSoundsDir = Bundle.main.resourceURL?.appendingPathComponent("sounds").path ?? ""
let systemSoundsDir = "/System/Library/Sounds"

func soundURL(_ name: String) -> URL? {
    for p in ["\(repoSoundsDir)/\(name).mp3", "\(systemSoundsDir)/\(name).aiff"]
    where FileManager.default.fileExists(atPath: p) {
        return URL(fileURLWithPath: p)
    }
    return nil
}

func listDirs(_ dir: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir + "/" + $0, isDirectory: &isDir) && isDir.boolValue
    }.sorted()
}

func listSounds(_ dir: String, ext: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
        .filter { $0.hasSuffix("." + ext) }
        .map { String($0.dropLast(ext.count + 1)) }
        .sorted()
}

final class SoundPreview {
    static var current: NSSound?
    static func play(_ name: String) {
        current?.stop()
        guard let url = soundURL(name) else { return }
        current = NSSound(contentsOf: url, byReference: true)
        current?.play()
    }
}

// 選單列圖示：7×6 的點陣貓臉（兩個尖耳朵、兩個眼睛），跟 app 裡的點陣貓同一個風格。
// 設成 template，系統會依淺色／深色選單列自動換成黑或白。
func menuBarIcon() -> NSImage {
    let face = ["X.....X",
                "XX...XX",
                "XXXXXXX",
                "X.XXX.X",
                "XXXXXXX",
                ".XXXXX."]
    let pitch: CGFloat = 2.5, dot: CGFloat = 2.1
    let w = CGFloat(face[0].count) * pitch, h = CGFloat(face.count) * pitch
    let img = NSImage(size: NSSize(width: w, height: h), flipped: true) { _ in
        NSColor.black.setFill()
        for (r, row) in face.enumerated() {
            for (c, ch) in row.enumerated() where ch == "X" {
                NSBezierPath(ovalIn: NSRect(x: CGFloat(c) * pitch + (pitch - dot) / 2,
                                            y: CGFloat(r) * pitch + (pitch - dot) / 2, width: dot, height: dot)).fill()
            }
        }
        return true
    }
    img.isTemplate = true
    img.accessibilityDescription = "Agent Island"
    return img
}

// MARK: - App

let appTuning = TuningStore()

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    var islands: [IslandController] = []
    var stateTimer: Timer!
    var mouseTimer: Timer!
    var statusItem: NSStatusItem!
    var tuningWindow: NSWindow?
    var demoWindow: NSWindow?
    let demo = DemoRunner()
    let model = StateModel()
    let tuning = appTuning
    let presence = Presence()

    func applicationDidFinishLaunching(_ notification: Notification) {
        demo.clear()                                // 上次沒收掉的示範檔
        NotificationCenter.default.addObserver(forName: openDemoNotification, object: nil, queue: .main) { [weak self] _ in
            self?.openDemo()
        }
        buildIslands()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.buildIslands()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = menuBarIcon()
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: L("設定…", "Settings…"), action: #selector(openTuning), keyEquivalent: ","))
        if isDevBuild {
            menu.addItem(NSMenuItem(title: L("示範模式（錄影用）…", "Demo mode (for recording)…"), action: #selector(openDemo), keyEquivalent: "d"))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("關於", "About"), action: #selector(openAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: L("結束", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu
        LoginItem.setUpOnFirstLaunch()

        // 自動更新（Sparkle，每小時檢查）；點更新通知直接打開更新視窗
        UNUserNotificationCenter.current().delegate = self
        DoneNotifier.start()
        Updater.shared.start(automatic: tuning.t.autoUpdate)
        // 測試用（只有測試版）：--check-updates-now 在背景檢查一次（找到就出現標題列按鈕）；
        // --auto-install-update 找到就直接下載、安裝、重開
        if isDevBuild, CommandLine.arguments.contains("--check-updates-now") || CommandLine.arguments.contains("--auto-install-update") {
            Updater.shared.testAutoInstall = CommandLine.arguments.contains("--auto-install-update")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Updater.shared.checkInBackground() }
        }
        // 錄 README 動圖用：啟動參數 --demo-flow，1.5 秒後自動播一次「一般任務」
        if isDevBuild, CommandLine.arguments.contains("--demo-flow") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.demo.playFlow() }
        }

        // Codex：讀它的工作紀錄，任務也顯示在小島上
        CodexWatcher.shared.enabled = { [weak self] in self?.tuning.t.codexEnabled ?? false }
        CodexWatcher.shared.start()

        // 第一次打開、還沒連接 Claude Code：直接帶到連接那一頁
        if ClaudeCodeLink.status() == .disconnected, !UserDefaults.standard.bool(forKey: "didOfferConnect") {
            UserDefaults.standard.set(true, forKey: "didOfferConnect")
            openSettings(.claudeCode)
        }

        stateTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.model.popOnFinish = self.tuning.t.popOnFinish
            idlePauseSeconds = self.tuning.t.idlePause
            self.model.tick()
        }
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            let p = NSEvent.mouseLocation
            for c in self.islands {
                c.trackMouse(p, model: self.model, tuning: self.tuning, presence: self.presence)
            }
            self.followMouse(p)
        }

        // 在小島上按右鍵：收起目前這個任務
        NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] e in
            guard e.window is IslandPanel else { return e }
            self?.model.dismissCurrent()
            return nil
        }

        // 只攔小島自己的捲動；設定視窗等其他視窗照常捲動。
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard e.window is IslandPanel else { return e }
            self?.handleSwipe(e)
            return nil
        }
    }

    // 雙指左右滑：一次滑動只換一頁。放手後觸控板還會送一段慣性捲動，那段不算。
    private var swipeAcc: CGFloat = 0
    private var swipeFired = false
    private var lastFlip = Date.distantPast

    func handleSwipe(_ e: NSEvent) {
        guard e.momentumPhase.isEmpty else { return }
        if e.phase.contains(.began) { swipeAcc = 0; swipeFired = false }
        if e.phase.contains(.ended) || e.phase.contains(.cancelled) {
            swipeAcc = 0; swipeFired = false; return
        }
        guard abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) else { return }
        // 換算成手指實際移動的方向（「自然捲動」開或關都一樣）。
        let finger = e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX
        swipeAcc += finger
        let threshold: CGFloat = e.hasPreciseScrollingDeltas ? 40 : 1
        guard !swipeFired, abs(swipeAcc) >= threshold,
              Date().timeIntervalSince(lastFlip) > 0.3 else { return }
        swipeFired = !e.phase.isEmpty          // 滑鼠滾輪沒有 phase，靠 0.3 秒冷卻避免連跳
        if e.phase.isEmpty { swipeAcc = 0 }
        lastFlip = Date()
        model.flip(swipeAcc < 0 || finger < 0 ? 1 : -1)   // 手指往左 → 下一個
    }

    func buildIslands() {
        islands.forEach { $0.close() }
        let main = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first
        islands = NSScreen.screens.map {
            IslandController(screen: $0, primary: $0 == main, model: model, tuning: tuning, presence: presence)
        }
        if !islands.contains(where: { $0.id == presence.active }) {
            presence.active = islands.first(where: { $0.primary })?.id ?? 0
        }
    }

    // 多螢幕時決定小島在哪個螢幕：
    // "top"：滑鼠碰到某個螢幕的頂端，就把小島丟到那個螢幕，之後滑鼠在哪都不動，直到碰到另一個螢幕的頂端才丟回去。
    // "follow"：滑鼠進到哪個螢幕就跟過去。"fixed"：一直在主螢幕。
    func followMouse(_ p: NSPoint) {
        let main = islands.first(where: { $0.primary })?.id ?? 0
        var target = presence.active
        switch tuning.t.screenSwitch {
        case "fixed":
            target = main
        case "follow":
            if let c = islands.first(where: { $0.screen.frame.insetBy(dx: 0, dy: -2).contains(p) }) { target = c.id }
        default:
            if let c = islands.first(where: {
                let f = $0.screen.frame
                return p.y >= f.maxY - 3 && p.y <= f.maxY + 1 && p.x >= f.minX && p.x < f.maxX
            }) { target = c.id }
        }
        if presence.active != target { presence.active = target }
    }

    // App 已經在跑、又從「應用程式」或 Spotlight 打開一次：打開設定（選單列 app 的慣例）
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openTuning()
        return true
    }

    @objc func openAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSAttributedString(string: L("你的 AI Agent 在做什麼，瀏海上一眼就知道。\n第三方授權見 設定 → 關於。", "See what your AI agent is doing at a glance, right in your MacBook's notch.\nThird-party licenses: Settings → About."),
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    // 選單打開前：有新版本就在最上面放「更新到 x.y.z…」
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items.filter { $0.tag == 99 }.forEach { menu.removeItem($0) }
        let titles = [L("設定…", "Settings…")] + (isDevBuild ? [L("示範模式（錄影用）…", "Demo mode (for recording)…")] : []) + ["",
                      L("關於", "About"), L("結束", "Quit")]
        for (item, title) in zip(menu.items, titles) where !item.isSeparatorItem { item.title = title }
        if let v = Updater.shared.latestVersion {
            let item = NSMenuItem(title: L("有新版本 \(v)，更新…", "Update to \(v)…"), action: #selector(openUpdate), keyEquivalent: "")
            item.tag = 99
            menu.insertItem(item, at: 0)
            let sep = NSMenuItem.separator()
            sep.tag = 99
            menu.insertItem(sep, at: 1)
        }
    }

    @objc func openUpdate() { Updater.shared.checkNow() }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let tty = response.notification.request.content.userInfo["tty"] as? String {
            DoneNotifier.focusTerminalTab(tty)          // 完成通知：回到那個 Terminal 分頁
        } else if response.notification.request.content.threadIdentifier != "done" {
            Updater.shared.checkNow()                   // 更新通知：直接打開更新視窗
        }
        completionHandler()
    }

    // 小島自己在最前面時（例如開著設定）也照樣跳出通知
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func openSettings(_ page: SettingsPage) {
        SettingsNav.shared.page = page
        openTuning()
    }

    @objc func openTuning() {
        if tuningWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = L("Agent Island 設定", "Agent Island Settings")
            // 跟 Claude 桌面版的設定一樣：沒有標題列、深色、內容直接頂到上緣
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = NSColor(white: 0.118, alpha: 1)
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(store: tuning))
            w.delegate = self
            w.center()
            tuningWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        tuningWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func openDemo() {
        if demoWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 620),
                             styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
            w.title = L("Agent Island 示範模式", "Agent Island Demo")
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: DemoView(demo: demo, store: tuning))
            w.delegate = self
            w.center()
            demoWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        demoWindow?.makeKeyAndOrderFront(nil)
    }

    // 關掉的視窗要真的釋放：設定視窗裡有會動的預覽，只是藏起來的話會一直在背景跑動畫、很耗電。
    func windowWillClose(_ notification: Notification) {
        let w = notification.object as? NSWindow
        if w === demoWindow {
            demo.clear()                                // 關掉示範視窗 = 結束示範
        } else {
            tuning.preview = false
        }
        DispatchQueue.main.async { [weak self] in
            w?.contentView = nil
            if w === self?.demoWindow { self?.demoWindow = nil }
            if w === self?.tuningWindow { self?.tuningWindow = nil }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
