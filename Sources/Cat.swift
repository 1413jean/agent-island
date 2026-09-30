import AppKit
import SwiftUI

// 小島底部的貓咪場景（點陣風格）：一隻白色的點陣貓，依 Claude 的狀態做不同動作，
// 背後是捲動的山丘、草地和星空。靈感來自一段點陣馬奔跑的影片。
//
// 貓不是一格一格手畫的：用身體、頭、耳朵、腳、尾巴幾個簡單形狀擺姿勢，
// 再「點陣化」（格子中心落在形狀裡就點亮），所以看起來像影片裡的點陣剪影，動作也容易調。
// 座標以「點」為單位，x 往右、y 往上，貓朝右。

let catW = 20, catH = 13                 // 貓的畫布（點數）

struct CatPose {
    var body = (x: 9.0, y: 5.0, rx: 5.0, ry: 2.2)
    var head = (x: 14.2, y: 7.0, r: 2.2)
    var eye: (x: Double, y: Double)? = (15.0, 7.3)   // 眼睛是一格不亮的洞；nil = 閉眼
    var earsBack = false                              // 頭轉向左邊時耳朵位置反過來
    var legs: [(Double, Double, Double, Double)] = []  // 每隻腳一條線：起點、終點
    var tail: [(Double, Double)] = []                  // 尾巴折線
    var tailWidth = 1.15
    var extras: [(Double, Double, Double)] = []        // 其他圓（毛線球）
    var extraBody: (x: Double, y: Double, rx: Double, ry: Double)? = nil
}

private func segDist(_ px: Double, _ py: Double, _ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> Double {
    let dx = bx - ax, dy = by - ay
    let l2 = dx * dx + dy * dy
    let t = l2 == 0 ? 0 : max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / l2))
    let qx = ax + t * dx - px, qy = ay + t * dy - py
    return (qx * qx + qy * qy).squareRoot()
}

// 點陣化：回傳亮起的格子（列 0 在最下面）
func rasterCat(_ p: CatPose) -> [[Bool]] {
    var g = [[Bool]](repeating: [Bool](repeating: false, count: catW), count: catH)
    var h = p.head
    h.r *= 1.1                                               // 頭大一點比較可愛
    let dir: Double = p.earsBack ? -1 : 1
    // 耳朵：頭頂兩個短短的尖角，微微往外張
    let ears = [(h.x - 0.45 * h.r * dir, h.y + 0.5 * h.r, h.x - 0.72 * h.r * dir, h.y + h.r + 0.6),
                (h.x + 0.3 * h.r * dir, h.y + 0.6 * h.r, h.x + 0.55 * h.r * dir, h.y + h.r + 0.6)]
    for gy in 0..<catH {
        for gx in 0..<catW {
            let x = Double(gx) + 0.5, y = Double(gy) + 0.5
            var on = false
            let b = p.body
            if pow((x - b.x) / b.rx, 2) + pow((y - b.y) / b.ry, 2) <= 1 { on = true }
            if let e = p.extraBody, pow((x - e.x) / e.rx, 2) + pow((y - e.y) / e.ry, 2) <= 1 { on = true }
            if pow(x - h.x, 2) + pow(y - h.y, 2) <= h.r * h.r { on = true }
            for e in ears where segDist(x, y, e.0, e.1, e.2, e.3) < 0.62 { on = true }
            for l in p.legs where segDist(x, y, l.0, l.1, l.2, l.3) < 0.62 { on = true }
            if p.tail.count > 1 {
                for i in 0..<(p.tail.count - 1) where segDist(x, y, p.tail[i].0, p.tail[i].1,
                                                            p.tail[i + 1].0, p.tail[i + 1].1) < p.tailWidth / 2 { on = true }
            }
            for c in p.extras where pow(x - c.0, 2) + pow(y - c.1, 2) <= c.2 * c.2 { on = true }
            g[gy][gx] = on
        }
    }
    if let e = p.eye {
        let ex = Int(e.x), ey = Int(e.y)
        if ey >= 0 && ey < catH && ex >= 0 && ex < catW { g[ey][ex] = false }
    }
    return g
}

// MARK: - 各種動作（u 是一個循環裡的位置 0～1）

private func leg(_ x: Double, _ y: Double, _ deg: Double, _ len: Double) -> (Double, Double, Double, Double) {
    let a = deg * .pi / 180
    return (x, y, x + len * cos(a), y + len * sin(a))
}

// 奔跑：身體上下起伏，前後腳交替大幅擺動，尾巴往後飄
func poseRun(_ u: Double) -> CatPose {
    let a = u * 2 * .pi
    var p = CatPose()
    let bob = 0.45 * sin(2 * a)
    p.body = (9, 5.3 + bob, 5.1, 2.1)
    p.head = (14.3, 7.1 + 0.35 * sin(2 * a + 0.6), 2.2)
    p.eye = (15.1, 7.4 + 0.35 * sin(2 * a + 0.6))
    let f = 48 * sin(a), k = 48 * sin(a - 0.7)
    p.legs = [leg(12.2, 4.6 + bob, -90 + f, 3.4), leg(11.2, 4.5 + bob, -90 + k, 3.4),
              leg(6.4, 4.7 + bob, -90 - f, 3.4), leg(7.2, 4.6 + bob, -90 - k, 3.4)]
    p.tail = [(4.4, 6.0 + bob), (2.6, 7.0 + 0.6 * sin(a)), (0.9, 7.8 + 0.9 * sin(a + 1))]
    return p
}

// 散步：身體平穩，四隻腳對角交替，頭稍微低下來聞一聞
func poseWalk(_ u: Double) -> CatPose {
    let a = u * 2 * .pi
    var p = CatPose()
    p.body = (9, 5.0, 5.0, 2.1)
    p.head = (14.1, 6.3 + 0.25 * sin(2 * a), 2.2)
    p.eye = (14.9, 6.6 + 0.25 * sin(2 * a))
    let s = 24 * sin(a), t = 24 * sin(a + .pi)
    p.legs = [leg(12.0, 4.2, -90 + s, 3.6), leg(11.1, 4.2, -90 + t, 3.6),
              leg(6.4, 4.3, -90 + t, 3.6), leg(7.3, 4.3, -90 + s, 3.6)]
    p.tail = [(4.3, 5.6), (3.0, 7.3), (3.3, 9.0 + 0.4 * sin(a)), (4.2, 9.8 + 0.4 * sin(a))]
    return p
}

// 坐著：尾巴尖左右甩，偶爾眨眼
func poseSit(_ u: Double, blink: Bool = true) -> CatPose {
    let a = u * 2 * .pi
    var p = CatPose()
    p.body = (8.4, 3.6, 3.3, 3.4)
    p.head = (10.4, 7.8, 2.25)
    p.eye = blink && u > 0.62 && u < 0.68 ? nil : (11.3, 8.1)
    p.legs = [leg(10.4, 2.6, -86, 2.4), leg(9.5, 2.6, -88, 2.4)]
    p.tail = [(5.6, 0.9), (3.8, 0.8), (2.5, 1.6 + 0.9 * sin(a)), (2.0, 2.9 + 1.2 * sin(a + 0.9))]
    return p
}

// 睡覺：縮成一團，閉眼，身體跟著呼吸微微起伏
func poseSleep(_ u: Double) -> CatPose {
    let a = u * 2 * .pi
    var p = CatPose()
    p.body = (8.6, 1.9, 5.2, 1.8 + 0.18 * sin(a))
    p.head = (13.3, 2.3 + 0.12 * sin(a), 2.0)
    p.eye = nil
    p.tail = [(3.6, 1.4), (4.4, 0.4), (8.5, 0.3), (11.5, 0.5)]
    return p
}

// 撥毛線球：坐著，一隻前腳一直去撥前面的毛線球
func posePaw(_ u: Double) -> CatPose {
    let a = u * 2 * .pi
    var p = poseSit(0.3, blink: false)
    p.head = (10.8, 7.3, 2.25)
    p.eye = (11.7, 7.3)
    let lift = max(0, sin(a))
    p.legs = [leg(9.5, 2.6, -88, 2.4), (10.4, 3.2, 12.6, 1.6 + 2.2 * lift)]
    p.extras = [(15.3 + 0.5 * max(0, sin(a - 0.8)), 1.4, 1.35)]
    return p
}

// 嚇到（出錯）：弓背、四腳打直、尾巴豎起變粗
func poseStartled(_ u: Double) -> CatPose {
    var p = CatPose()
    let j = u < 0.5 ? -0.25 : 0.25
    p.body = (8.6 + j, 5.9, 4.2, 2.3)
    p.extraBody = (8.6 + j, 6.8, 2.6, 1.9)
    p.head = (13.4 + j, 6.2, 2.1)
    p.eye = (14.2 + j, 6.4)
    p.legs = [(5.6 + j, 4.6, 5.3 + j, 0.2), (6.6 + j, 4.6, 6.6 + j, 0.2),
              (10.7 + j, 4.6, 10.8 + j, 0.2), (11.6 + j, 4.6, 12.0 + j, 0.2)]
    p.tail = [(4.6 + j, 6.8), (3.8 + j, 9.3), (4.3 + j, 11.4)]
    p.tailWidth = 1.9
    return p
}

// 攤平（額度用完）：整隻趴在地上，前後腳伸直
func poseFlat(_ u: Double) -> CatPose {
    var p = CatPose()
    p.body = (9, 1.3, 5.4, 1.15)
    p.head = (14.9, 1.9, 1.95)
    p.eye = nil
    p.legs = [(13.0, 0.7, 17.4, 0.5), (5.2, 0.8, 1.6, 0.5)]
    p.tail = [(3.8, 1.3), (0.4, 1.1)]
    return p
}

// 回頭看（暫停）：坐著，頭轉向後面
func poseLookBack(_ u: Double) -> CatPose {
    var p = poseSit(0.2, blink: false)
    p.head = (7.4, 7.8, 2.25)
    p.eye = (6.5, 8.1)
    p.earsBack = true
    return p
}

// 蹲低（跳之前、落地後）
func poseCrouch() -> CatPose {
    var p = poseSit(0.2, blink: false)
    p.body = (8.4, 2.8, 3.8, 2.6)
    p.head = (10.8, 6.0, 2.25)
    p.eye = (11.7, 6.3)
    p.legs = [leg(10.6, 2.0, -80, 1.8), leg(9.7, 2.0, -85, 1.8)]
    return p
}

// 跳在空中：身體伸長、前腳往前伸、後腳往後蹬
func poseLeap() -> CatPose {
    var p = CatPose()
    p.body = (9, 6.4, 5.3, 1.9)
    p.head = (14.6, 8.2, 2.2)
    p.eye = (15.4, 8.5)
    p.legs = [leg(12.4, 5.8, -30, 3.4), leg(11.5, 5.7, -40, 3.4), leg(6.3, 5.9, -150, 3.4), leg(7.1, 5.8, -140, 3.4)]
    p.tail = [(4.2, 6.9), (2.3, 7.4), (0.8, 8.6)]
    return p
}

// MARK: - 場景

let catPitch: CGFloat = 2.3              // 點和點的間距（pt）
let sceneRows = 14                       // 場景高度（點數）
var catSceneHeight: CGFloat { catPitch * CGFloat(sceneRows) }

// MARK: - 點陣格上的額外動作（伸懶腰、愛心、紙箱）

typealias CatGrid = [[Bool]]

private func gridPut(_ g: inout CatGrid, _ cells: [(Int, Int)], _ v: Bool) {
    for (x, y) in cells where y >= 0 && y < catH && x >= 0 && x < catW { g[y][x] = v }
}

// 伸懶腰：前腳往前趴低、屁股翹高、尾巴豎起（k 讓尾巴尖晃一下）
func gridStretch(_ k: Double) -> CatGrid {
    var p = CatPose()
    p.body = (12, 2.4, 3.6, 1.5)
    p.extraBody = (7.2, 4.6, 3.2, 2.0)
    p.head = (15.6, 2.8, 2.0)
    p.eye = nil
    p.legs = [(12, 1.4, 17.8, 0.5), (11.5, 1.2, 17.2, 0.4), (6.2, 3.6, 5.8, 0.2), (7.4, 3.6, 7.5, 0.2)]
    p.tail = [(4.6, 5.8), (3.4, 8.2 + 0.6 * k), (4.4, 10.3)]
    return rasterCat(p)
}

// 冒愛心：坐著瞇眼，頭上飄出一顆愛心（k 0→1 愛心往上飄，快到頂時消失）
func gridHeart(_ k: Double) -> CatGrid {
    var p = poseSit(0.2, blink: false)
    p.eye = nil
    var g = rasterCat(p)
    gridPut(&g, heartCells(k), true)
    return g
}

// 愛心佔的格子（畫成紅色）
func heartCells(_ k: Double) -> [(Int, Int)] {
    guard k < 0.85 else { return [] }
    let y0 = 8 + Int(k * 3)
    return [(14, y0 + 2), (16, y0 + 2), (13, y0 + 1), (14, y0 + 1), (15, y0 + 1), (16, y0 + 1), (17, y0 + 1),
            (14, y0), (15, y0), (16, y0), (15, y0 - 1)]
}
let heartRed = NSColor(srgbRed: 0.98, green: 0.36, blue: 0.42, alpha: 1)

// 開心蹦起來：還是坐姿，但身體拉長、腳往下伸直、尾巴翹起來
func gridHop() -> CatGrid {
    var p = poseSit(0.2, blink: false)
    p.body = (8.4, 4.0, 3.0, 3.5)
    p.head = (10.4, 8.4, 2.25)
    p.eye = nil                                              // 開心得瞇起眼
    p.legs = [(10.4, 2.8, 10.7, -0.2), (9.5, 2.8, 9.3, -0.2), (6.8, 1.6, 6.4, -0.2)]
    p.tail = [(5.4, 2.6), (3.8, 4.6), (3.4, 7.2)]
    return rasterCat(p)
}

// 一個狀態的動畫：先播一次開場（可以邊播邊往右跑），再一直循環
struct CatClip {
    var intro: [(CatGrid, Double)] = []                      // 每格和它停多久（秒）
    var run: CGFloat = 0                                      // 開場中往右移動多少 pt
    var loop: [CatGrid]
    var cycle: Double
    var speed: Double = 0                                     // 背景捲動快慢（0 不動、1 奔跑）
    var jump = false                                          // 開場裡蹦兩下
    var bubble = false                                        // 頭旁邊冒「…」對話泡泡
    var red: [Set<Int>] = []                                  // 每一格循環影格裡要畫成紅色的點（y × catW + x）
}

private func catClip(_ phase: String) -> CatClip {
    func loop(_ n: Int, _ f: (Double) -> CatPose) -> [CatGrid] { (0..<n).map { rasterCat(f(Double($0) / Double(n))) } }
    switch phase {
    case "running": return CatClip(loop: loop(8, poseRun), cycle: 0.5, speed: 1)
    case "reading": return CatClip(loop: loop(8, poseWalk), cycle: 1.1, speed: 0.3)
    case "working": return CatClip(loop: loop(10, posePaw), cycle: 0.9)
    case "thinking":
        // 坐著想事情：甩尾巴、偶爾眨眼，頭旁邊冒「…」
        return CatClip(loop: loop(24, { poseSit($0) }), cycle: 2.6, bubble: true)
    case "paused":
        // 伸個懶腰
        let s = [(rasterCat(poseSit(0.2, blink: false)), 0.3), (gridStretch(0), 0.5), (gridStretch(1), 0.5), (gridStretch(0), 0.5)]
        return CatClip(intro: s, loop: [rasterCat(poseSit(0.2, blink: false))], cycle: 1)
    case "error": return CatClip(loop: loop(2, poseStartled), cycle: 0.16)
    case "limit": return CatClip(loop: [rasterCat(poseFlat(0))], cycle: 1)
    case "done":
        // 開心地原地蹦兩下（先蹲、彈起、落地蹲一下緩衝；第二下小一點），再坐下瞇眼冒愛心
        let sit = rasterCat(poseSit(0.2, blink: false)), crouch = rasterCat(poseCrouch()), hop = gridHop()
        let j = [(sit, 0.12), (crouch, 0.18), (hop, 0.30), (crouch, 0.12), (hop, 0.26), (crouch, 0.12)]
        var c = CatClip(intro: j, loop: (0..<5).map { gridHeart(Double($0) / 5) }, cycle: 1.5, jump: true)
        c.red = (0..<5).map { Set(heartCells(Double($0) / 5).map { $0.1 * catW + $0.0 }) }
        return c
    default: return CatClip(loop: loop(12, poseSleep), cycle: 3.2)                  // Ready／停止：睡覺
    }
}

private func catColor(_ phase: String) -> NSColor {
    switch phase {
    case "error", "limit": return NSColor(srgbRed: 0.96, green: 0.36, blue: 0.36, alpha: 1)
    default: return NSColor(white: 0.96, alpha: 1)
    }
}

// 點陣畫成一張圖：lit(x, y) 回傳那一格的顏色（nil 不畫），y 往上
private func dotImage(cols: Int, rows: Int, scale: CGFloat, _ lit: (Int, Int) -> NSColor?) -> CGImage? {
    let w = Int((CGFloat(cols) * catPitch * scale).rounded(.up)), h = Int((CGFloat(rows) * catPitch * scale).rounded(.up))
    guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.scaleBy(x: scale, y: scale)
    let d = catPitch * 0.74
    for y in 0..<rows {
        for x in 0..<cols {
            guard let c = lit(x, y) else { continue }
            ctx.setFillColor(c.cgColor)
            ctx.fillEllipse(in: CGRect(x: CGFloat(x) * catPitch + (catPitch - d) / 2,
                                       y: CGFloat(y) * catPitch + (catPitch - d) / 2, width: d, height: d))
        }
    }
    return ctx.makeImage()
}

private func shash(_ a: Int, _ b: Int) -> Double {
    let h = sin(Double(a) * 127.1 + Double(b) * 311.7) * 43758.5453
    return h - floor(h)
}

struct CatSceneView: NSViewRepresentable {
    let phase: String
    let running: Bool
    let radius: Double
    let maxWidth: Double
    func makeNSView(context: Context) -> CatSceneNSView { CatSceneNSView() }
    func updateNSView(_ v: CatSceneNSView, context: Context) {
        v.radius = radius
        v.tileWidth = maxWidth
        v.update(phase: phase, running: running)
    }
}

// 全部用 Core Animation：背景是兩層可以無縫接起來的長圖在捲（遠山慢、近景快），
// 貓是一組預先畫好的影格輪播，星星閃爍和睡覺的 z 也是系統動畫。程式平常不用每格重畫。
final class CatSceneNSView: NSView {
    private let root = CALayer()
    private let world = CALayer()                  // 捲動的東西都放這裡，用 speed 控制快慢
    private let far = CALayer(), near = CALayer(), sky = CALayer()
    private let cat = CALayer()
    private let bubble = CALayer()                  // Thinking 時頭旁邊的「…」對話泡泡
    private var zs: [CALayer] = []
    private var phase = ""
    private var running = true
    private var builtWidth: CGFloat = 0
    private var builtHeight: CGFloat = 0
    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }
    private let runSpeed: CGFloat = 70             // 奔跑時近景每秒捲幾 pt
    private let clip = CAShapeLayer()              // 裁成小島下緣的圓角
    var radius = 28.0 { didSet { if radius != oldValue { updateClip() } } }
    // 背景照小島最大寬度畫一次；小島寬度跟著字變的時候只是裁多裁少，不用重畫、捲動也不會跳
    var tileWidth = 480.0 { didSet { if tileWidth != oldValue { buildScenery() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = root
        wantsLayer = true
        root.masksToBounds = false                   // 貓跳起來可以超出場景上緣（下緣圓角由 mask 裁）
        root.mask = clip
        for l in [sky, far, near, cat, bubble] { l.contentsGravity = .bottomLeft; l.anchorPoint = .zero }
        root.addSublayer(sky)
        world.anchorPoint = .zero
        root.addSublayer(world)
        world.addSublayer(far)
        world.addSublayer(near)
        root.addSublayer(cat)
        root.addSublayer(bubble)
        for _ in 0..<3 {
            let z = CALayer()
            z.anchorPoint = .zero
            z.opacity = 0
            root.addSublayer(z)
            zs.append(z)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        builtWidth = 0                               // 換到不同解析度的螢幕：重畫
        buildScenery()
    }

    override func setFrameSize(_ s: NSSize) {
        super.setFrameSize(s)
        updateClip()
        if builtWidth == 0 || abs(s.height - builtHeight) > 1 { buildScenery() }
    }

    private func updateClip() {
        let w = bounds.width, h = bounds.height, r = min(radius, w / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.frame = bounds
        clip.path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h + r), cornerWidth: r, cornerHeight: r, transform: nil)
        CATransaction.commit()
    }

    func update(phase: String, running: Bool) {
        if running != self.running {
            self.running = running
            root.speed = running ? 1 : 0          // 收起來時整個場景停住，不耗電
            if running { root.timeOffset = 0; root.beginTime = 0 }
        }
        guard phase != self.phase else { return }
        self.phase = phase
        setAction()
    }

    // 背景：寬度等於兩倍畫面、內容以一個畫面寬為週期重複，捲一個畫面寬就接回原點，看起來無限延伸
    private func buildScenery() {
        let w = CGFloat(tileWidth)
        guard bounds.width > 10, bounds.height > 10 else { return }
        builtWidth = w
        builtHeight = bounds.height
        let cols = Int(w / catPitch) + 1
        let grass = NSColor(white: 0.55, alpha: 0.55), hill = NSColor(white: 0.5, alpha: 0.35)
        let hillFill = NSColor(white: 0.5, alpha: 0.12), tree = NSColor(srgbRed: 0.5, green: 0.72, blue: 0.52, alpha: 0.75)
        let lamp = NSColor(srgbRed: 1, green: 0.72, blue: 0.35, alpha: 0.95)
        // 遠山：週期性的起伏，稜線亮一點、山裡面淡淡的點
        func ridge(_ x: Int) -> Int {
            let t = Double(x % cols) / Double(cols) * 2 * .pi
            return 3 + Int((1.8 * sin(t * 2 + 1) + 1.3 * sin(t * 5 + 0.4) + 1.6).rounded())
        }
        far.contents = dotImage(cols: cols * 2, rows: sceneRows, scale: scale) { x, y in
            let r = ridge(x)
            if y == r { return hill }
            if y < r && y > 0 && (x + y) % 2 == 0 { return hillFill }
            return nil
        }
        // 近景：地面一排點、零星的草、幾棵小松樹，偶爾一間亮著燈的小屋
        let trees = (0..<max(2, cols / 26)).map { i in (i * 26 + Int(shash(i, 3) * 12)) % cols }
        let houseX = (cols / 2 + 7) % cols
        near.contents = dotImage(cols: cols * 2, rows: sceneRows, scale: scale) { x0, y in
            let x = x0 % cols
            if y == 0 { return grass }
            if y == 1 && shash(x, 1) > 0.72 { return grass }
            for tx in trees {
                let dx = abs(x - tx)
                if y == 1 && dx == 0 { return tree }                       // 樹幹
                if y >= 2 && y <= 5 && dx <= (5 - y) / 1 && dx <= 2 { return tree }   // 三角形樹冠
            }
            let hx = x - houseX
            if hx >= 0 && hx <= 3 && y >= 1 && y <= 3 {
                if hx == 1 && y == 2 { return lamp }
                return NSColor(white: 0.5, alpha: 0.4)
            }
            if hx >= -1 && hx <= 4 && y == 4 { return NSColor(white: 0.5, alpha: 0.4) }
            return nil
        }
        // 天空：零星的星星（不捲動）
        sky.contents = dotImage(cols: cols, rows: sceneRows, scale: scale) { x, y in
            y >= 9 && shash(x, y) > 0.965 ? NSColor(white: 0.8, alpha: 0.5 + 0.4 * shash(y, x)) : nil
        }
        let h = bounds.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [sky, far, near, cat, bubble] + zs { l.contentsScale = scale }   // 圖是用螢幕解析度畫的
        sky.frame = CGRect(x: 0, y: 0, width: w, height: h)
        world.frame = bounds
        let tw = CGFloat(cols) * catPitch
        far.frame = CGRect(x: 0, y: 0, width: tw * 2, height: h)
        near.frame = CGRect(x: 0, y: 0, width: tw * 2, height: h)
        cat.frame = CGRect(x: 32, y: catPitch * 0.5, width: CGFloat(catW) * catPitch, height: CGFloat(catH) * catPitch)
        bubble.frame = CGRect(x: cat.frame.minX + 13 * catPitch, y: cat.frame.minY + 7 * catPitch,
                              width: 10 * catPitch, height: 6 * catPitch)
        CATransaction.commit()
        // 無限捲動（以奔跑速度建立，實際快慢用 world.speed 調）
        for (l, k) in [(near, 1.0), (far, 0.35)] {
            let a = CABasicAnimation(keyPath: "position.x")
            a.fromValue = 0
            a.toValue = -tw
            a.duration = Double(tw / runSpeed) / k
            a.repeatCount = .infinity
            l.add(a, forKey: "scroll")
        }
        let old = phase
        phase = ""
        update(phase: old, running: running)
    }

    private func setAction() {
        let clip = catClip(phase)
        let color = catColor(phase)
        func image(_ g: CatGrid, _ red: Set<Int> = []) -> CGImage? {
            dotImage(cols: catW, rows: catH, scale: scale) { x, y in
                g[y][x] ? (red.contains(y * catW + x) ? heartRed : color) : nil
            }
        }
        let loopImgs = clip.loop.indices.compactMap { image(clip.loop[$0], $0 < clip.red.count ? clip.red[$0] : []) }
        let introImgs = clip.intro.compactMap { image($0.0) }
        let introDur = clip.intro.reduce(0) { $0 + $1.1 }

        cat.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cat.contents = loopImgs.first
        cat.transform = CATransform3DMakeTranslation(clip.run, 0, 0)
        CATransaction.commit()
        let now = cat.convertTime(CACurrentMediaTime(), from: nil)

        // 循環（開場播完才開始）
        if loopImgs.count > 1 {
            let k = CAKeyframeAnimation(keyPath: "contents")
            k.values = loopImgs
            k.calculationMode = .discrete
            k.duration = clip.cycle
            k.repeatCount = .infinity
            k.beginTime = now + introDur
            cat.add(k, forKey: "loop")
        }
        // 開場：播一次，後加的優先，所以播放期間蓋過循環
        if !introImgs.isEmpty {
            var t = 0.0, times: [NSNumber] = []
            for f in clip.intro { times.append(NSNumber(value: t / introDur)); t += f.1 }
            let k = CAKeyframeAnimation(keyPath: "contents")
            k.values = introImgs
            k.keyTimes = times
            k.calculationMode = .discrete
            k.duration = introDur
            k.beginTime = now
            cat.add(k, forKey: "intro")
            if clip.run != 0 {
                let m = CABasicAnimation(keyPath: "transform.translation.x")
                m.fromValue = 0
                m.toValue = clip.run
                m.duration = introDur * 0.8
                m.beginTime = now
                m.fillMode = .backwards
                cat.add(m, forKey: "run")
            }
            if clip.jump {
                // 往上彈時越來越慢、到頂後越落越快（跟真的跳一樣），落地停一下再彈第二下
                let j = CAKeyframeAnimation(keyPath: "transform.translation.y")
                j.values = [0, 0, catPitch * 5.5, 0, 0, catPitch * 3.2, 0, 0]
                j.keyTimes = [0, 0.27, 0.41, 0.55, 0.66, 0.77, 0.89, 1]
                let out = CAMediaTimingFunction(name: .easeOut), inn = CAMediaTimingFunction(name: .easeIn),
                    lin = CAMediaTimingFunction(name: .linear)
                j.timingFunctions = [lin, out, inn, lin, out, inn, lin]
                j.duration = introDur
                j.beginTime = now
                cat.add(j, forKey: "jump")
            }
        }
        setBubble(clip.bubble)
        setWorldSpeed(Float(clip.speed))
        setZs(phase == "idle" || phase == "stopped" || phase == "")
    }

    // 「…」對話泡泡：泡泡框從頭旁邊冒出來，裡面的點一顆一顆亮起，再重來
    private func setBubble(_ on: Bool) {
        bubble.removeAllAnimations()
        bubble.contents = nil
        guard on else { return }
        let c = NSColor(white: 0.9, alpha: 0.9), dim = NSColor(white: 0.9, alpha: 0.45)
        func frame(_ n: Int) -> CGImage? {
            dotImage(cols: 10, rows: 6, scale: scale) { x, y in
                if y == 0 { return x == 0 ? dim : nil }                       // 連到頭的小尾巴
                if y == 5 || y == 1 { return x >= 2 && x <= 8 ? c : nil }     // 上下框
                if x == 1 || x == 9 { return y >= 2 && y <= 4 ? c : nil }     // 左右框
                if y == 3 && [3, 5, 7].contains(x) { return [3, 5, 7].firstIndex(of: x)! < n ? c : nil }
                return nil
            }
        }
        let frames = [0, 1, 2, 3, 3].compactMap(frame)
        bubble.contents = frames.first
        let k = CAKeyframeAnimation(keyPath: "contents")
        k.values = frames
        k.calculationMode = .discrete
        k.duration = 2.0
        k.repeatCount = .infinity
        bubble.add(k, forKey: "dots")
    }

    // 背景捲動的快慢：從目前的位置接著走，不會跳
    private func setWorldSpeed(_ s: Float) {
        let now = CACurrentMediaTime()
        world.timeOffset = world.convertTime(now, from: nil)
        world.beginTime = now
        world.speed = s
    }

    // 睡覺時頭上飄出的 z
    private func setZs(_ on: Bool) {
        // 4×4 的 Z：上下兩條橫線、中間斜的（由上往下看）
        let zGlyph = ["1111", "0010", "0100", "1111"].map { $0.map { $0 == "1" } }
        let img = dotImage(cols: 4, rows: 4, scale: scale) { x, y in
            zGlyph[3 - y][x] ? NSColor(white: 1, alpha: 1) : nil
        }
        // 從睡著的頭旁邊冒出來，往右上飄、越飄越大再淡掉；三個輪流冒，像 z Z Z
        let base = CGPoint(x: cat.frame.minX + 14.5 * catPitch, y: cat.frame.minY + 4.5 * catPitch)
        for (i, z) in zs.enumerated() {
            z.removeAllAnimations()
            z.opacity = 0
            guard on else { continue }
            z.contents = img
            z.frame = CGRect(x: base.x, y: base.y, width: catPitch * 4, height: catPitch * 4)
            let up = CABasicAnimation(keyPath: "position")
            up.fromValue = NSValue(point: base)
            up.toValue = NSValue(point: CGPoint(x: base.x + catPitch * 6, y: base.y + catPitch * 7))
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.55
            grow.toValue = 1.25
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.15, 0.7, 1]
            let g = CAAnimationGroup()
            g.animations = [up, grow, fade]
            g.duration = 2.7
            g.repeatCount = .infinity
            g.timeOffset = Double(i) * 0.9
            z.add(g, forKey: "z")
        }
    }
}
