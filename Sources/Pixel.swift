import AppKit
import SwiftUI

// 圖示風格一：像素格（5×5）。
// 顏色跟光核統一：工作中藍、閒置／暫停／停止白、出錯紅，完成的勾是綠色。
// 每個狀態一個小動作：Thinking 貪食蛇繞圈、讀檔掃描、跑指令等化器、改檔打字、完成排成勾……
// 沒亮的格子留一點點底光，看起來像一塊小小的點陣螢幕。

let pixelN = 5
let doneGreenNS = NSColor(srgbRed: 0.45, green: 0.83, blue: 0.55, alpha: 1)

private func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
private func phash(_ a: Int, _ b: Int) -> Double {
    let h = sin(Double(a) * 12.9898 + Double(b) * 78.233) * 43758.5453
    return h - floor(h)
}

// 外框一圈的格子（順時針，從左上角開始）
private let ring: [(Int, Int)] = {
    var r: [(Int, Int)] = []
    for c in 0..<pixelN { r.append((0, c)) }
    for row in 1..<pixelN { r.append((row, pixelN - 1)) }
    for c in stride(from: pixelN - 2, through: 0, by: -1) { r.append((pixelN - 1, c)) }
    for row in stride(from: pixelN - 2, through: 1, by: -1) { r.append((row, 0)) }
    return r
}()

// 勾的格子，照畫的順序：短邊往右下、長邊往右上
private let checkCells: [(Int, Int)] = [(2, 0), (3, 1), (2, 2), (1, 3), (0, 4)]

// 一格畫面：回傳 25 格的亮度（0～1，列優先）。t 跟著忙碌程度快慢，local 是進入這個狀態後的秒數。
func pixelFrame(_ phase: String, t: Double, local: Double) -> [Double] {
    var b = [Double](repeating: 0, count: pixelN * pixelN)
    func set(_ r: Int, _ c: Int, _ v: Double) { b[r * pixelN + c] = max(b[r * pixelN + c], v) }

    switch phase {
    case "thinking":
        // 貪食蛇沿外框繞圈，尾巴漸淡；中間一顆跟著呼吸
        let head = (t * 9).truncatingRemainder(dividingBy: Double(ring.count))
        for (i, cell) in ring.enumerated() {
            let d = (head - Double(i) + Double(ring.count)).truncatingRemainder(dividingBy: Double(ring.count))
            if d < 6 { set(cell.0, cell.1, 1 - d / 6) }
        }
        set(2, 2, 0.25 + 0.25 * sin(t * 3))

    case "reading":
        // 掃描線由左往右，掃過的格子亮一下（亮度有點隨機，像在讀資料）
        let pos = (t * 5).truncatingRemainder(dividingBy: Double(pixelN + 3)) - 1
        for r in 0..<pixelN {
            for c in 0..<pixelN {
                let d = pos - Double(c)
                if d >= 0 && d < 2.5 { set(r, c, (1 - d / 2.5) * (0.55 + 0.45 * phash(r, c + Int(t * 5 / Double(pixelN + 3)) * 7))) }
            }
        }

    case "running":
        // 等化器：每一欄像音量條一樣上下跳，頂端那格最亮
        for c in 0..<pixelN {
            let w = 3.1 + Double(c) * 1.37, ph = Double(c) * 2.1
            let h = 1 + Int((0.5 + 0.5 * sin(t * w + ph)) * Double(pixelN - 1) + 0.5)
            for k in 0..<h { set(pixelN - 1 - k, c, k == h - 1 ? 1 : 0.55) }
        }

    case "working":
        // 打字：格子依序一顆顆亮起（游標那格最亮），填滿後停一下再一起清掉
        let steps = Double(pixelN * pixelN)
        let k = (t * 11).truncatingRemainder(dividingBy: steps + 8)
        for i in 0..<(pixelN * pixelN) {
            let r = i / pixelN, c = i % pixelN
            if k < steps {
                if Double(i) < floor(k) { set(r, c, 0.55) }
                if i == Int(k) { set(r, c, 1) }
            } else {
                set(r, c, 0.55 * clamp01(1 - (k - steps - 4) / 3))
            }
        }

    case "done":
        // 全部格子閃一下，再一格一格排成勾，每格出現時彈亮一下
        let flash = clamp01(1 - local / 0.2)
        for r in 0..<pixelN { for c in 0..<pixelN { set(r, c, 0.5 * flash) } }
        for (i, cell) in checkCells.enumerated() {
            let s = local - 0.18 - Double(i) * 0.07
            if s > 0 { set(cell.0, cell.1, s < 0.12 ? 1 : 0.9 + 0.1 * sin(local * 3 - Double(i))) }
        }

    case "paused":
        // 暫停符號，慢慢呼吸
        let v = 0.6 + 0.3 * sin(t * 2)
        for r in 0..<pixelN { set(r, 1, v); set(r, 3, v) }

    case "stopped":
        // 停止：中間一個方塊
        for r in 1...3 { for c in 1...3 { set(r, c, 0.7) } }

    case "error":
        // 驚嘆號在閃
        let on = (t * 1.4).truncatingRemainder(dividingBy: 1) < 0.7 ? 1.0 : 0.25
        for r in 0...2 { set(r, 2, on) }
        set(4, 2, on)

    case "limit":
        // 額度用完：X 慢慢閃
        let v = 0.55 + 0.45 * sin(t * 3)
        for i in 0..<pixelN { set(i, i, v); set(i, pixelN - 1 - i, v) }

    default:
        // 閒置（Ready）：中間一顆慢慢呼吸
        set(2, 2, 0.35 + 0.3 * sin(t * 1.6))
    }
    return b
}

func pixelTint(_ phase: String) -> NSColor {
    phase == "done" ? doneGreenNS : (dotOrbTint(phase, 0).usingColorSpace(.sRGB) ?? .white)
}

struct PixelView: View {
    let phase: String
    let size: CGFloat
    @State private var born = Date()
    @Environment(\.islandLive) private var live

    var body: some View {
        let n = CGFloat(pixelN)
        let cell = size / (n + (n - 1) * 0.3)                // 格子之間留 0.3 格的縫
        let gap = cell * 0.3
        let tint = pixelTint(phase)
        let base = Color(tint)
        TimelineView(.animation(minimumInterval: frameInterval, paused: !live)) { ctx in
            let now = ctx.date.timeIntervalSinceReferenceDate
            let slow = ["paused", "stopped"].contains(phase) ? 0.5 : 1.0
            // 越忙動得越快（跟光核共用同一個累積時間，快慢切換時不會跳）
            let t = OrbClock.shared.tick(now, rate: slow * (0.8 + 1.4 * orbEnergy))
            let b = pixelFrame(phase, t: t, local: ctx.date.timeIntervalSince(born))
            Canvas { g, _ in
                for i in 0..<(pixelN * pixelN) {
                    let r = CGFloat(i / pixelN), c = CGFloat(i % pixelN)
                    let rect = CGRect(x: c * (cell + gap), y: r * (cell + gap), width: cell, height: cell)
                    let a = 0.08 + 0.92 * b[i]                   // 沒亮的格子留一點底光
                    g.fill(Path(roundedRect: rect, cornerRadius: cell * 0.28), with: .color(base.opacity(a)))
                }
            }
            .frame(width: size, height: size)
            .shadow(color: base.opacity(0.55), radius: cell * 0.9)
        }
        .frame(width: size, height: size)
        .onAppear { born = Date() }
    }
}
