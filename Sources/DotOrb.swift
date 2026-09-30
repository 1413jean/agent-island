import AppKit
import SwiftUI

// 圖示風格二：點陣光球。
// 永遠是同一顆立體的點陣球，狀態只改變球的「行為」和顏色，換狀態時球一直都在。
// 畫法沿用 thinking-orbs（MIT © 2026 Jakub Antalik，https://libraries.dev/orbs，授權見 THIRD_PARTY_NOTICES.md）：
// 不用光暈、模糊或漸層，每格都是一堆 3D 點，旋轉後平面投影、由遠到近排序再畫；
// 這裡再加上左上方打光與邊緣收淡，讓點陣讀起來像一顆實心的球。

private func fibDir(_ i: Int, _ n: Int) -> SIMD3<Double> {
    let golden = Double.pi * (3 - 5.0.squareRoot())
    let y = 1 - 2 * (Double(i) + 0.5) / Double(n)
    let rad = (1 - y * y).squareRoot()
    let a = Double(i) * golden
    return SIMD3(rad * cos(a), y, rad * sin(a))
}

private func angleDelta(_ a: Double, _ b: Double) -> Double { atan2(sin(a - b), cos(a - b)) }
private func hash(_ a: Double, _ b: Double) -> Double { let h = sin(a * 12.9898 + b * 78.233) * 43758.5453; return h - floor(h) }
private func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    let k = min(1, max(0, (x - e0) / (e1 - e0))); return k * k * (3 - 2 * k)
}

// 先繞 y 軸轉 yaw、再繞 x 軸傾斜 tilt（不做透視）。
private func rotate(_ p: SIMD3<Double>, yaw: Double, tilt: Double) -> SIMD3<Double> {
    let x1 = p.x * cos(yaw) + p.z * sin(yaw)
    let z1 = -p.x * sin(yaw) + p.z * cos(yaw)
    return SIMD3(x1, p.y * cos(tilt) - z1 * sin(tilt), p.y * sin(tilt) + z1 * cos(tilt))
}

private let light = { () -> SIMD3<Double> in
    let l = SIMD3(-0.55, 0.62, 0.6); return l / (l * l).sum().squareRoot()
}()

struct SphereDot {                                       // b 亮度、hot 往白色混的比例、col 指定顏色（不跟狀態色）
    var x, y, z, r, b, a, hot: Double
    var col: SIMD3<Double>? = nil
}

// 各狀態的行為參數
private struct Behavior {
    var spin = 0.35          // 自轉速度（弧度／秒），0 = 停住
    var breathe = 0.0        // 表面由上往下的呼吸波
    var scan = false         // 一條掃描線掃過
    var gather = 0.0         // 元氣彈：四周的光點被吸進球裡（0～1，實際多寡再乘上忙碌程度）
    var ripple = false       // 從一個點往外擴散的波紋
    var jitter = false       // 快速抖動
    var dim = 1.0            // 整體亮度
}

private func behavior(_ phase: String) -> Behavior {
    var b = Behavior()
    switch phase {
    case "thinking": b.spin = 0.4; b.breathe = 1; b.gather = 0.4
    case "reading": b.spin = 0.55; b.scan = true; b.gather = 0.55
    case "running": b.spin = 0.6; b.gather = 1
    case "working": b.spin = 0.45; b.ripple = true; b.gather = 0.75
    case "done": b.spin = 0.25
    case "paused", "stopped": b.spin = 0; b.dim = 0.7
    case "limit", "error": b.spin = 0.3; b.jitter = true
    default: b.spin = 0.2; b.breathe = 0.4                  // Ready
    }
    return b
}

// 一格畫面。box 是畫布邊長（pt），t 是時間（秒），local 是進入這個狀態後經過的秒數。
func sphereFrame(box: Double, t: Double, local: Double, phase: String) -> [SphereDot] {
    let bh = behavior(phase)
    let c = box / 2
    // 越忙吸進來的光點越多；有元氣彈時球小一點，留位置給外圍被吸進來的點
    let gather = bh.gather * (0.35 + 0.65 * orbEnergy)
    var R = box / 2 * (bh.gather > 0 ? 0.6 : 0.74)
    var yaw = bh.spin == 0 ? 0.9 : t * bh.spin
    var tilt = 0.38
    if phase == "done" {                                     // 完成：先猛轉一圈、往前翻一下（假 3D），再變成勾
        let p = min(1, local / doneSpin)
        let e = p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2   // 緩起→加速→緩停
        yaw += 2 * .pi * e
        tilt += 0.55 * sin(.pi * p)
    }

    // 進場：從小一點、淡淡的聚攏成球（完成時是從原本的球直接變形，不用重新聚攏）
    let intro = phase == "done" ? 1 : smooth(0, 0.45, local)
    R *= 0.78 + 0.22 * intro

    let n = Int(min(460, max(170, box * box * 0.17)))       // 點的數量跟著尺寸
    let penLon = t * 0.7, penLat = 0.5 * sin(t * 0.4)        // 波紋的中心點，在球面上慢慢移動
    let pen = SIMD3(cos(penLat) * cos(penLon), sin(penLat), cos(penLat) * sin(penLon))
    let scanAngle = t * 2.3

    var dots: [SphereDot] = []
    dots.reserveCapacity(n + 120)
    for i in 0..<n {
        let p = fibDir(i, n)
        var disp = 0.0, boost = 0.0

        if bh.breathe > 0 {                                  // 由上往下流過的呼吸波
            let w = sin(p.y * 3.2 - t * 2.2)
            disp += 0.035 * bh.breathe * w
            boost += 0.35 * bh.breathe * max(0, w)
        }
        if bh.ripple {                                       // 從移動的筆尖往外擴散的波紋
            let ang = acos(max(-1, min(1, (p * pen).sum())))
            let ring = max(0, sin(ang * 7 - t * 7)) * max(0, 1 - ang / 2.2)
            disp += 0.07 * ring
            boost += 0.8 * ring
        }
        if bh.jitter {
            disp += 0.05 * sin(t * 23 + Double(i) * 1.7) * (0.6 + 0.4 * sin(t * 3))
        }

        let q = rotate(p * (1 + disp), yaw: yaw, tilt: tilt)
        let depth = (q.z / (1 + disp) + 1) / 2              // 0 最遠、1 最近

        if bh.scan {                                         // 經線掃描：被掃到的點變大變亮，其他的暗下去
            let lon = atan2(p.z, p.x) - yaw
            let d = angleDelta(lon, scanAngle)
            let s = exp(-(d * d) / 0.07) * max(0, q.z)
            boost += 1.3 * s - 0.25
        }

        let lambert = max(0, (q * light).sum())             // 左上方打光
        let shade = 0.22 + 0.78 * lambert
        let rim = 1 - 0.45 * smooth(0.72, 1.0, (q.x * q.x + q.y * q.y).squareRoot())   // 邊緣收淡，輪廓更圓
        let bright = (0.1 + 0.9 * depth) * shade * rim * bh.dim * (1 + boost) * (1 + 0.25 * gather)

        dots.append(SphereDot(
            x: c + q.x * R, y: c - q.y * R, z: q.z,
            r: box * (0.007 + 0.019 * depth) * (1 + 0.45 * max(0, boost)),
            b: min(1.2, bright), a: (0.12 + 0.88 * depth) * intro,
            hot: min(0.7, max(0, boost) * 0.45 + lambert * depth * 0.18)))
    }

    if gather > 0 {                                          // 元氣彈：四面八方的光點被吸進球裡
        let m = Int(10 + 34 * gather)
        for j in 0..<m {
            let h1 = hash(Double(j), 1.3), h2 = hash(Double(j), 2.7), h3 = hash(Double(j), 6.1)
            let dir = SIMD3(cos(h1 * 2 * .pi) * (1 - (2 * h2 - 1) * (2 * h2 - 1)).squareRoot(),
                            2 * h2 - 1,
                            sin(h1 * 2 * .pi) * (1 - (2 * h2 - 1) * (2 * h2 - 1)).squareRoot())
            let period = 1.1 + 0.9 * h3                          // 每顆飛進來的時間不同
            let u = (t / period + h1 * 7).truncatingRemainder(dividingBy: 1)   // 0 剛出現 → 1 吸進球
            for k in 0..<3 {                                     // 光點＋往外拖的短尾巴
                let uk = max(0, u - Double(k) * 0.035)
                let dist = 1.0 + 0.72 * pow(1 - uk, 1.6)        // 從球外 1.72 倍半徑一路加速吸進來
                let q = rotate(dir * dist, yaw: yaw * 0.3, tilt: tilt)
                let hidden = q.z < 0 && (q.x * q.x + q.y * q.y) < dist * dist * 0.9
                let fadeIn = smooth(0, 0.1, uk), absorb = 1 - smooth(0.88, 1, uk)   // 早點浮現，從外圍就看得到
                let tail = 1 - Double(k) / 3
                let depth = (q.z / dist + 1) / 2
                dots.append(SphereDot(x: c + q.x * R, y: c - q.y * R, z: q.z + 0.002,
                                      r: box * (0.012 + 0.02 * uk) * (0.45 + 0.55 * tail) * (0.6 + 0.4 * depth),
                                      b: 0.7 + 0.5 * uk,
                                      a: fadeIn * absorb * tail * (hidden ? 0.12 : 0.55 + 0.45 * depth) * intro,
                                      hot: k == 0 ? 0.25 + 0.4 * uk : 0.1))
            }
        }
    }

    if phase == "done" { dots = fadeSphere(dots, local: local) }
    return dots.filter { $0.a >= 0.02 }.sorted { $0.z < $1.z }
}

// 完成（照 iPhone Face ID 成功的節奏）：
// 0～0.4 秒  球轉一下、糊開、轉綠並淡掉，化成一團綠光
// 0.12 秒起  三條綠色線圈從糊糊的光裡出現，各繞不同的軸、往不同方向翻 1.5～2 圈；
//            一開始最快、越轉越慢（轉越快越糊越發光，慢下來就清楚），0.82 秒一起轉正疊成一圈
// 停一下     只有圈
// 0.94 秒起  勾勾從一個點開始，先畫短邊、再畫長邊
// （以上是 doneStretch 放慢前的秒數）
let doneStretch = 1.15
let doneSpin = 0.5
let ringStart = 0.12, ringSettle = 0.82
let checkStart = 0.94, checkDur = 0.36

// 球糊開的程度（0～1）
func doneBlur(_ local: Double) -> Double { smooth(0.05, 0.3, local) }

// 球上的點：轉成光核的藍、淡掉，交棒給點圈
private func fadeSphere(_ dots: [SphereDot], local: Double) -> [SphereDot] {
    let blue = smooth(0, 0.3, local), fade = 1 - smooth(0.15, 0.4, local)
    return dots.map { d in
        var d = d
        d.col = SIMD3(0.94 + (0.44 - 0.94) * blue, 0.95 + (0.71 - 0.95) * blue, 0.97 + (0.87 - 0.97) * blue)
        d.a *= fade
        return d
    }
}

// 三條線圈各自的翻轉：繞哪個軸、轉幾圈、往哪個方向、從什麼角度開始
struct Gyro { let axis: SIMD3<Double>; let turns: Double; let dir: Double; let offset: Double }
let doneGyro = [
    Gyro(axis: SIMD3(0, 1, 0), turns: 1.5, dir: 1, offset: 1.2),                 // 左右翻
    Gyro(axis: SIMD3(1, 0, 0), turns: 1.75, dir: -1, offset: 0.6),               // 上下翻
    Gyro(axis: SIMD3(0.7071, -0.7071, 0), turns: 2.0, dir: 1, offset: 2.0),      // 斜著翻
]

// 繞任意軸旋轉（Rodrigues 公式）
private func rotateAxis(_ v: SIMD3<Double>, axis k: SIMD3<Double>, angle: Double) -> SIMD3<Double> {
    let cr = SIMD3(k.y * v.z - k.z * v.y, k.z * v.x - k.x * v.z, k.x * v.y - k.y * v.x)
    return v * cos(angle) + cr * sin(angle) + k * (k * v).sum() * (1 - cos(angle))
}

let doneRing = 0.8                                           // 綠圈半徑（占畫布半邊的比例）
let doneGreen = Color(.sRGB, red: 0.45, green: 0.83, blue: 0.55, opacity: 1)

// 三個圈，settle 0 = 剛出現（轉最多）、1 = 全部轉正疊在一起。
// 我們的版本：翻轉時圈是光核的藍色點點串成的，快轉正時點點連成一條線、同時由藍轉綠。
struct DoneRings: View {
    let box: Double
    let settle: Double
    let time: Double                                         // 翻轉經過的比例（0～1，線性）

    var body: some View {
        Canvas { g, _ in
            let c = box / 2, rr = box / 2 * doneRing
            for gy in doneGyro {
                let th = gy.dir * (2 * .pi * gy.turns + gy.offset) * (1 - settle)
                var path = Path()
                for j in 0...72 {
                    let a = Double(j) / 72 * 2 * .pi
                    let v = rotateAxis(SIMD3(cos(a), sin(a), 0), axis: gy.axis, angle: th)
                    let pt = CGPoint(x: c + v.x * rr, y: c + v.y * rr)
                    if j == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                // 每圈 18 顆點；join 0 → 1 時，點拉長、空隙收掉，連成實線
                let join = smooth(0.62, 0.95, time)
                let gap = 2 * .pi * rr / 18
                let style = join >= 1 ? StrokeStyle(lineWidth: box * 0.055)
                    : StrokeStyle(lineWidth: box * 0.055, lineCap: .round,
                                  dash: [max(0.001, gap * join), gap * (1 - join)])
                let k = smooth(0.65, 1, time)
                let col = Color(.sRGB, red: 0.44 + (0.45 - 0.44) * k, green: 0.71 + (0.83 - 0.71) * k,
                                blue: 0.87 + (0.55 - 0.87) * k, opacity: 1)
                g.stroke(path, with: .color(col), style: style)
            }
        }
        .frame(width: box, height: box)
    }
}

// 線圈＋一筆畫出來的勾
struct DoneMark: View {
    let box: Double
    let local: Double

    var body: some View {
        let show = smooth(ringStart, ringStart + 0.18, local)
        let p = min(1, max(0, (local - ringStart) / (ringSettle - ringStart)))
        let settle = 1 - pow(1 - p, 3)                       // 一開始最快、越轉越慢
        let fuzz = 1 - p                                     // 越接近轉正越清楚
        let q = min(1, max(0, (local - checkStart) / checkDur))
        let draw = q * q * (3 - 2 * q)
        ZStack {
            DoneRings(box: box, settle: settle, time: p)              // 外面一層光暈
                .blur(radius: box * (0.04 + 0.12 * fuzz))
                .opacity(show * (0.3 + 0.5 * fuzz))
            DoneRings(box: box, settle: settle, time: p)              // 本體：由糊變清楚
                .blur(radius: box * 0.05 * fuzz)
                .opacity(show * (1 - 0.5 * fuzz))
            CheckShape()
                .trim(from: 0, to: draw)
                .stroke(doneGreen, style: StrokeStyle(lineWidth: box * 0.06, lineCap: .round, lineJoin: .round))
                .opacity(q > 0 ? 1 : 0)
        }
        .frame(width: box, height: box)
    }
}

struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY), s = rect.width * 0.27
        let pts = [(-0.62, 0.02), (-0.16, -0.46), (0.7, 0.52)]   // 往上為正
        var path = Path()
        for (i, p) in pts.enumerated() {
            let pt = CGPoint(x: c.x + p.0 * s, y: c.y - p.1 * s)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        return path
    }
}

// 目前顯示中的任務有多忙（0～1），由 StateModel 每次更新時寫入。
var orbEnergy: Double = 0

// 光球用的時間：不是牆上時鐘，而是依速度累積的時間，速度改變時畫面連續、不會跳。
// 好幾個螢幕各有一顆球會在同一格裡各呼叫一次，幾毫秒內重複呼叫就回傳同一個值。
final class OrbClock {
    static let shared = OrbClock()
    private var last = 0.0
    private var tau = 0.0

    func tick(_ now: Double, rate: Double) -> Double {
        if last == 0 { last = now; tau = now.truncatingRemainder(dividingBy: 1000) }
        let dt = now - last
        if dt > 0.004 {
            tau += min(dt, 0.1) * rate
            last = now
        }
        return tau
    }
}

// 光核只用三個顏色：工作中藍、完成／閒置／暫停白（暫停另外調暗）、出錯紅。
func dotOrbTint(_ phase: String, _ t: Double) -> NSColor {
    switch phase {
    case "done", "idle", "paused", "stopped": return NSColor(srgbRed: 0.94, green: 0.95, blue: 0.97, alpha: 1)
    case "limit", "error": return NSColor(srgbRed: 0.96, green: 0.36, blue: 0.36, alpha: 1)
    default: return NSColor(srgbRed: 0.44, green: 0.71, blue: 0.87, alpha: 1)
    }
}

// 小島有沒有展開、而且在這個螢幕上顯示：收起來或在別的螢幕時所有動畫停掉，不再每格重畫（省電）。
struct IslandLiveKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var islandLive: Bool {
        get { self[IslandLiveKey.self] }
        set { self[IslandLiveKey.self] = newValue }
    }
}
// 動畫格數：光核和掃光平常每秒 24 格、完成動畫 60 格。
let frameInterval = 1.0 / 24

struct DotOrbView: View {
    let phase: String
    let size: CGFloat
    @State private var born = Date()
    @Environment(\.islandLive) private var live

    var body: some View {
        let box = Double(size) * 1.5                        // 畫布比圖示位置大一點，球才有份量
        TimelineView(.animation(minimumInterval: phase == "done" ? 1.0 / 60 : frameInterval, paused: !live)) { ctx in
            let now = ctx.date.timeIntervalSinceReferenceDate
            // 完成動畫整段放慢一點（doneStretch），各段節奏不變
            let local = ctx.date.timeIntervalSince(born) / (phase == "done" ? doneStretch : 1)
            let tint = dotOrbTint(phase, now).usingColorSpace(.sRGB) ?? .white
            let slow = ["paused", "stopped"].contains(phase) ? 0.35 : 1.0
            // 越忙轉得越快：活躍度 0 時約 0.7 倍速、滿載時約 4 倍速；集氣的光點用同一個時間，一起變快變慢
            let tau = OrbClock.shared.tick(now, rate: slow * (0.7 + 3.3 * orbEnergy))
            let dots = sphereFrame(box: box, t: tau, local: local, phase: phase)
            // 景深：轉到後面的點畫在模糊的一層，前面的點保持清楚，看起來像霧化到後面去。
            ZStack {
                DotLayer(dots: dots.filter { $0.z < -0.05 }, tint: tint)
                    .blur(radius: box * 0.028)
                DotLayer(dots: dots.filter { $0.z >= -0.05 && $0.z < 0.2 }, tint: tint)
                    .blur(radius: box * 0.01)
                DotLayer(dots: dots.filter { $0.z >= 0.2 }, tint: tint)
            }
            .drawingGroup()                                  // 三層點和模糊交給 GPU 一次合成
            .blur(radius: phase == "done" ? box * 0.032 * doneBlur(local) : 0)
            .overlay { if phase == "done" { DoneMark(box: box, local: local) } }
            .frame(width: box, height: box)
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .onAppear { born = Date() }
    }
}

// 小島底部的漸層光：從小島下緣往上淡淡泛出的光，顏色跟著目前圖示走
// （光核用它的藍／白／紅，像素格用它輪替的顏色），只加一點色相偏移做層次。
// 效能：每團光是自帶柔邊的放射漸層，呼吸交給 Core Animation 在背景播（見 GlowNSView），程式不用每格重畫。
struct BottomGlow: View {
    let phase: String
    let style: String
    var on = true                                            // 設定關掉或閒置時整個停掉，不在看不見的時候重畫
    var radius = 28.0                                        // 小島下緣圓角

    // 顏色跟圖示一樣（兩種圖示用同一套顏色）
    private func tint(_ t: Double) -> NSColor { pixelTint(phase) }

    // 同一個顏色的幾個變化：色相左右偏一點、再加一個偏白的亮色
    private func shades(_ base: NSColor) -> [NSColor] {
        func shift(_ dh: CGFloat, _ ds: CGFloat, _ db: CGFloat) -> NSColor {
            var h: CGFloat = 0, sat: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
            base.getHue(&h, saturation: &sat, brightness: &br, alpha: &a)
            return NSColor(hue: (h + dh + 1).truncatingRemainder(dividingBy: 1),
                           saturation: max(0, min(1, sat + ds)), brightness: max(0, min(1, br + db)), alpha: 1)
        }
        return [shift(-0.05, 0.05, -0.1), shift(0, 0, 0), shift(0, -0.35, 0.15), shift(0, 0, 0), shift(0.05, 0.05, -0.1)]
    }

    @Environment(\.islandLive) private var live

    var body: some View {
        let calm = ["paused", "stopped"].contains(phase)
        let e = (orbEnergy * 10).rounded() / 10                 // 分成 10 段，忙碌程度小抖動時不用一直改節奏
        GlowLayerView(palette: [shades(tint(0))],
                      level: calm ? 0.1 : 0.16 + 0.2 * e,
                      // 呼吸：閒時約 4 秒一次、忙時約 2.5 秒一次
                      period: calm ? 6 : 4 - 1.5 * e,
                      running: live && on, radius: radius)
            .allowsHitTesting(false)
    }
}

// 底部光交給 Core Animation：呼吸（亮暗＋微微升起）是重複播放的系統動畫，由 macOS 在背景算，
// 程式本身不用每格重畫；只有顏色或節奏改變時才更新一次。
struct GlowLayerView: NSViewRepresentable {
    let palette: [[NSColor]]
    let level: Double
    let period: Double
    let running: Bool
    let radius: Double

    func makeNSView(context: Context) -> GlowNSView { GlowNSView() }
    func updateNSView(_ v: GlowNSView, context: Context) {
        v.radius = radius
        v.update(palette: palette, level: level, period: period, running: running)
    }
}

final class GlowNSView: NSView {
    private let root = CALayer()
    private let breath = CALayer()                           // 呼吸：整層亮暗，節奏用 speed 調
    private var blobs: [CAGradientLayer] = []
    private let line = CAGradientLayer()                     // 貼著下緣的細亮線
    private var palette: [[NSColor]] = []
    private var speed: Float = 1
    private var running = true
    private let basePeriod = 4.0                             // 動畫本身以 4 秒一次呼吸建立，快慢靠 speed
    private let clip = CAShapeLayer()                        // 裁成小島下緣的圓角
    var radius = 28.0 { didSet { if radius != oldValue { relayout() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = root
        wantsLayer = true
        root.opacity = 0
        root.mask = clip
        root.addSublayer(breath)
        for _ in 0..<5 {
            let g = CAGradientLayer()
            g.type = .radial
            g.startPoint = CGPoint(x: 0.5, y: 0.5)
            g.endPoint = CGPoint(x: 1, y: 1)
            g.locations = [0, 0.5, 1]
            breath.addSublayer(g)
            blobs.append(g)
        }
        line.startPoint = CGPoint(x: 0, y: 0.5)
        line.endPoint = CGPoint(x: 1, y: 0.5)
        breath.addSublayer(line)
        startBreathing()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        relayout()
    }

    override func setFrameSize(_ s: NSSize) {
        super.setFrameSize(s)
        relayout()
    }

    // 圖層座標原點在左下角
    private func relayout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let w = bounds.width, h = bounds.height
        breath.frame = bounds
        for (i, g) in blobs.enumerated() {
            let center = i == 2
            g.bounds = CGRect(x: 0, y: 0, width: w * (center ? 0.62 : 0.46), height: h * (center ? 0.8 : 0.62))
            g.position = CGPoint(x: w * (Double(i) + 0.5) / 5, y: -h * 0.02)
        }
        line.frame = CGRect(x: 0, y: 0, width: w, height: 1.5)
        let r = min(radius, w / 2, h)
        clip.frame = bounds
        clip.path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h + r), cornerWidth: r, cornerHeight: r,
                           transform: nil)
        CATransaction.commit()
    }

    // 吸氣亮、吐氣暗；各團光跟著微微升起再沉下，離中間越遠的慢一點點
    private func startBreathing() {
        let half = basePeriod / 2
        let glow = CABasicAnimation(keyPath: "opacity")
        glow.fromValue = 0.55
        glow.toValue = 1.0
        glow.duration = half
        glow.autoreverses = true
        glow.repeatCount = .infinity
        glow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breath.add(glow, forKey: "breath")
        for (i, g) in blobs.enumerated() {
            let rise = CABasicAnimation(keyPath: "transform.scale.y")
            rise.fromValue = 0.8
            rise.toValue = 1.15
            rise.duration = half
            rise.autoreverses = true
            rise.repeatCount = .infinity
            rise.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            rise.timeOffset = basePeriod * (1 - Double(abs(i - 2)) * 0.06)
            g.add(rise, forKey: "rise")
        }
    }

    func update(palette: [[NSColor]], level: Double, period: Double, running: Bool) {
        if palette != self.palette {
            let first = self.palette.isEmpty
            self.palette = palette
            applyColors(animated: !first)
        }
        // 亮度（跟著忙碌程度）慢慢過去
        let target = Float(running ? level : 0)
        if abs(root.opacity - target) > 0.001 {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = root.presentation()?.opacity ?? root.opacity
            a.toValue = target
            a.duration = 0.8
            root.opacity = target
            root.add(a, forKey: "level")
        }
        // 節奏：改 speed，並從目前的位置接著走，不會跳
        let s = running ? Float(basePeriod / period) : 0
        if abs(s - speed) > 0.01 || running != self.running {
            let now = CACurrentMediaTime()
            breath.timeOffset = breath.convertTime(now, from: nil)
            breath.beginTime = now
            breath.speed = s
            speed = s
            self.running = running
        }
    }

    private func applyColors(animated: Bool) {
        func stops(_ c: NSColor, _ center: Bool) -> [CGColor] {
            [c.withAlphaComponent(center ? 1 : 0.8).cgColor, c.withAlphaComponent(center ? 0.45 : 0.3).cgColor,
             c.withAlphaComponent(0).cgColor]
        }
        func lineStops(_ s: [NSColor]) -> [CGColor] {
            [s[0].withAlphaComponent(0).cgColor, s[1].cgColor, s[2].cgColor, s[3].cgColor, s[4].withAlphaComponent(0).cgColor]
        }
        // 約 0.4 秒過渡到新顏色
        let s = palette[0]
        for (i, g) in blobs.enumerated() {
            let new = stops(s[i], i == 2)
            if animated {
                let a = CABasicAnimation(keyPath: "colors")
                a.fromValue = g.presentation()?.colors ?? g.colors
                a.toValue = new
                a.duration = 0.4
                g.add(a, forKey: "tint")
            }
            g.colors = new
        }
        line.colors = lineStops(s)
    }
}

struct DotLayer: View {
    let dots: [SphereDot]
    let tint: NSColor

    var body: some View {
        Canvas { g, _ in
            for d in dots {
                let b = min(1, d.b)
                let (tr, tg, tb) = d.col.map { ($0.x, $0.y, $0.z) } ?? (tint.redComponent, tint.greenComponent, tint.blueComponent)
                let c = Color(.sRGB,
                              red: min(1, tr * b + d.hot),
                              green: min(1, tg * b + d.hot),
                              blue: min(1, tb * b + d.hot),
                              opacity: d.a)
                g.fill(Path(ellipseIn: CGRect(x: d.x - d.r, y: d.y - d.r, width: d.r * 2, height: d.r * 2)),
                       with: .color(c))
            }
        }
    }
}
