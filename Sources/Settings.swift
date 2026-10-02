import AppKit
import ServiceManagement
import SwiftUI

// 設定視窗：參考 Claude 桌面版設定的質感 —— 深色、扁平、沒有卡片底；
// 左邊側欄最上面是 app 圖示和名稱，底下分組列出分頁；右邊每一列左邊是名稱（下面灰色說明）、右邊是控制項，列和列之間一條細線。

let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? L("開發版", "Development build")
let appBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""

// 測試版（./build.sh 裝在自己電腦的，編譯時加 -D DEV）才有示範模式、測試用的啟動參數；發佈給別人的正式版沒有。
#if DEV
let isDevBuild = true
#else
let isDevBuild = false
#endif

// 登入時自動啟動：用 macOS 的「登入項目」（系統設定 → 一般 → 登入項目 裡看得到、也能關）
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isOn: Bool { status == .enabled }
    static var needsApproval: Bool { status == .requiresApproval }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Agent Island 登入項目設定失敗：\(error.localizedDescription)")
        }
        NSLog("Agent Island 登入項目狀態：\(status.rawValue)（0 未登記、1 已開啟、2 等待允許、3 找不到）")
    }

    // 第一次打開 app：預設幫忙打開（跟以前的常駐服務一樣開機就有）
    static func setUpOnFirstLaunch() {
        let key = "loginItemSetUp"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if status != .enabled { set(true) }
    }
}

// MARK: - 顏色與字（整個設定視窗共用）

private enum SettingsStyle {
    static let bg = Color(white: 0.118)                 // 內容區
    static let sidebar = Color(white: 0.105)            // 側欄
    static let line = Color.white.opacity(0.08)         // 分隔線
    static let text = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.5)
    static let selected = Color.white.opacity(0.09)
    static let accent = Color(red: 0.23, green: 0.47, blue: 0.93)
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, claudeCode, notifications, appearance, layout, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return L("一般", "General")
        case .claudeCode: return L("連接", "Connections")
        case .notifications: return L("通知", "Notifications")
        case .appearance: return L("外觀", "Appearance")
        case .layout: return L("尺寸與外框", "Size & Frame")
        case .about: return L("關於", "About")
        }
    }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .claudeCode: return "link"
        case .notifications: return "bell"
        case .appearance: return "paintpalette"
        case .layout: return "rectangle.dashed"
        case .about: return "info.circle"
        }
    }
}

final class SettingsNav: ObservableObject {
    static let shared = SettingsNav()
    @Published var page: SettingsPage = .general
}

struct SettingsView: View {
    @ObservedObject var store: TuningStore
    @ObservedObject private var nav = SettingsNav.shared
    private var page: SettingsPage { nav.page }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(page: $nav.page)
                .frame(width: 184)
                .background(SettingsStyle.sidebar)
            Rectangle().fill(SettingsStyle.line).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    switch page {
                    case .general: GeneralPage(store: store)
                    case .claudeCode: ClaudeCodePage()
                    case .notifications: NotificationsPage(store: store)
                    case .appearance: AppearancePage(store: store)
                    case .layout: LayoutPage(store: store)
                    case .about: AboutPage()
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 36)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
                .buttonStyle(SettingsButtonStyle())
            }
            .background(SettingsStyle.bg)
            .id(page)                                    // 換分頁時從最上面開始
        }
        .tint(SettingsStyle.accent)
        .environment(\.colorScheme, .dark)
        .frame(minWidth: 760, idealWidth: 820, minHeight: 540, idealHeight: 640)
        .ignoresSafeArea()
    }
}

// 側欄：最上面是 app 圖示＋名稱，底下分組
private struct Sidebar: View {
    @Binding var page: SettingsPage

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Agent Island").font(.system(size: 14, weight: .semibold)).foregroundStyle(SettingsStyle.text)
                UpdateBadge()
            }
            .padding(.horizontal, 10)
            .padding(.top, 42)                           // 讓出左上角的紅黃綠按鈕
            .padding(.bottom, 18)

            group(L("設定", "Settings"), [.general, .claudeCode, .notifications, .appearance, .layout])
            Spacer().frame(height: 14)
            group(L("其他", "Other"), [.about])
            Spacer()
        }
        .padding(.horizontal, 8)
    }

    private func group(_ title: String, _ pages: [SettingsPage]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(SettingsStyle.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            ForEach(pages) { p in SidebarItem(item: p, selected: page == p) { page = p } }
        }
    }
}

// 側欄的一項：選中的底色亮一點，滑鼠經過時淡淡的底色
private struct SidebarItem: View {
    let item: SettingsPage
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: item.icon)
                    .font(.system(size: 12.5))
                    .frame(width: 16)
                    .foregroundStyle(SettingsStyle.text.opacity(selected || hover ? 1 : 0.75))
                Text(item.title)
                    .font(.system(size: 13))
                    .foregroundStyle(SettingsStyle.text.opacity(selected || hover ? 1 : 0.8))
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(selected ? SettingsStyle.selected : (hover ? Color.white.opacity(0.05) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

// MARK: - 共用的區塊和列

// 一個區塊：粗體標題，底下一列一列
struct SettingSection<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(SettingsStyle.text)
                .padding(.bottom, 10)
            content
            if let footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
        }
    }
}

// 一列：左邊名稱＋灰色說明，右邊控制項；下面一條細線（最後一列不畫）
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    var last = false
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14)).foregroundStyle(SettingsStyle.text)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(SettingsStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            if !last { Rectangle().fill(SettingsStyle.line).frame(height: 1) }
        }
    }
}

// 設定裡的一般按鈕：灰色圓角小膠囊（像參考圖），不是藍色文字
struct SettingsButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(SettingsStyle.text)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.09)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.08)))
            .contentShape(Rectangle())
    }
}

// 開關列
struct ToggleRow: View {
    let title: String
    var detail: String? = nil
    var last = false
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(title: title, detail: detail, last: last) {
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
    }
}

// 小膠囊分段選擇（像參考圖的 System | Reduced）
struct PillPicker<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let (v, label) = options[i]
                Button { selection = v } label: {
                    Text(label)
                        .font(.system(size: 13))
                        .foregroundStyle(selection == v ? SettingsStyle.text : SettingsStyle.secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(selection == v ? Color.white.opacity(0.12) : .clear)
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selection == v ? Color.white.opacity(0.1) : .clear)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.05)))
    }
}

// 下拉選單（文字＋小箭頭，沒有框）
struct MenuPicker<T: Hashable>: View {
    @Binding var selection: T
    let options: [(T, String)]

    var body: some View {
        Menu {
            ForEach(options.indices, id: \.self) { i in
                Button(options[i].1) { selection = options[i].0 }
            }
        } label: {
            HStack(spacing: 6) {
                Text(options.first(where: { $0.0 == selection })?.1 ?? "")
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .font(.system(size: 14))
            .foregroundStyle(SettingsStyle.text)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// 滑桿＋可以直接打數字（Enter 或點別的地方就套用，超出範圍自動拉回）
struct SliderControl: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var unit = "pt"
    @State private var text = ""
    @FocusState private var focused: Bool

    private func show(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }
    private func commit() {
        if let v = Double(text.trimmingCharacters(in: .whitespaces)) {
            value = min(range.upperBound, max(range.lowerBound, v))
        }
        text = show(value)
    }

    var body: some View {
        HStack(spacing: 10) {
            Slider(value: Binding(get: { value }, set: { value = ($0 / step).rounded() * step }), in: range)
                .frame(width: 170).controlSize(.small)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(SettingsStyle.text)
                .padding(.horizontal, 8)
                .frame(width: 52, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? SettingsStyle.accent : Color.white.opacity(0.08)))
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, now in if !now { commit() } }
            Text(unit).font(.system(size: 12)).foregroundStyle(SettingsStyle.secondary).frame(width: 20, alignment: .leading)
        }
        .onAppear { text = show(value) }
        .onChange(of: value) { _, v in if !focused { text = show(v) } }
    }
}

struct SliderSettingRow: View {
    let title: String
    var detail: String? = nil
    var last = false
    @Binding var value: Double
    let range: ClosedRange<Double>
    var unit = "pt"

    var body: some View {
        SettingRow(title: title, detail: detail, last: last) {
            SliderControl(value: $value, range: range, unit: unit)
        }
    }
}

// 完成音效：下拉選單＋試聽
struct SoundControl: View {
    @Binding var selection: String
    private let mine = listSounds(repoSoundsDir, ext: "mp3")
    private let system = listSounds(systemSoundsDir, ext: "aiff")
    private let uisfx: [(feel: String, names: [String])] = {
        let base = repoSoundsDir + "/uisfx"
        return listDirs(base).map { feel in (feel, listSounds(base + "/" + feel, ext: "mp3").map { "uisfx/\(feel)/\($0)" }) }
    }()

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Section(L("自訂", "Custom")) { ForEach(mine, id: \.self) { n in Button(n) { pick(n) } } }
                ForEach(uisfx, id: \.feel) { g in
                    Section("UI SFX · \(g.feel.capitalized)") {
                        ForEach(g.names, id: \.self) { n in Button(n.split(separator: "/").last.map(String.init) ?? n) { pick(n) } }
                    }
                }
                Section(L("macOS 內建", "macOS built-in")) { ForEach(system, id: \.self) { n in Button(n) { pick(n) } } }
            } label: {
                HStack(spacing: 6) {
                    Text(selection.split(separator: "/").last.map(String.init) ?? selection)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 14))
                .foregroundStyle(SettingsStyle.text)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            Button { SoundPreview.play(selection) } label: {
                Image(systemName: "play.circle.fill").font(.system(size: 18)).foregroundStyle(SettingsStyle.secondary)
            }
            .buttonStyle(.plain)
            .help(L("試聽", "Preview"))
        }
    }

    private func pick(_ n: String) {
        selection = n
        SoundPreview.play(n)
    }
}

// 預覽卡片外面加一點邊距
private struct PreviewBlock: View {
    let t: Tuning
    var body: some View {
        PreviewCard(t: t).padding(.bottom, 6)
    }
}

// MARK: - 一般

struct GeneralPage: View {
    @ObservedObject var store: TuningStore
    @State private var login = LoginItem.isOn
    @State private var approval = LoginItem.needsApproval

    var body: some View {
        SettingSection(title: L("語言", "Language")) {
            SettingRow(title: L("介面語言", "Interface language"),
                       detail: L("自動會跟著系統的語言。", "Auto follows your system language."), last: true) {
                PillPicker(selection: $store.t.language, options: [("auto", L("自動", "Auto")), ("zh", "中文"), ("en", "English")])
            }
        }

        SettingSection(title: L("啟動", "Startup")) {
            SettingRow(title: L("登入時自動啟動", "Launch at login"), detail: L("每次登入 Mac 都自動開好小島。也可以在「系統設定 → 一般 → 登入項目」管理。", "Opens the island every time you log in. You can also manage this in System Settings → General → Login Items."),
                       last: !approval) {
                Toggle("", isOn: Binding(get: { login }, set: { on in
                    LoginItem.set(on)
                    login = LoginItem.isOn
                    approval = LoginItem.needsApproval
                }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            if approval {
                SettingRow(title: L("需要在系統設定允許", "Needs approval in System Settings"), detail: L("macOS 要你確認一次，才會在登入時打開。", "macOS asks you to confirm once before it opens at login."), last: true) {
                    Button(L("打開登入項目設定…", "Open Login Items…")) { SMAppService.openSystemSettingsLoginItems() }
                }
            }
        }
        .onAppear { login = LoginItem.isOn; approval = LoginItem.needsApproval }

        SettingSection(title: L("小島", "Island")) {
            SettingRow(title: L("顯示方式", "Display"), detail: store.t.mode.hint) {
                PillPicker(selection: $store.t.mode, options: DisplayMode.allCases.map { ($0, $0.title) })
            }
            SettingRow(title: L("多螢幕", "Multiple displays"), detail: store.t.screenSwitch == "top"
                       ? L("滑鼠碰一下另一個螢幕的頂端，小島就搬過去；碰回原本螢幕的頂端再搬回來。", "Touch the top edge of another display and the island moves there; touch the top of the original display to bring it back.")
                       : store.t.screenSwitch == "follow" ? L("滑鼠移到哪個螢幕，小島就跟到那個螢幕。", "The island follows the pointer to whichever display it's on.") : L("小島一直待在主螢幕（有瀏海的那個）。", "The island always stays on the main display (the one with the notch).")) {
                MenuPicker(selection: $store.t.screenSwitch,
                           options: [("top", L("碰到頂端時移過去", "Move on top-edge touch")), ("follow", L("跟著滑鼠", "Follow the pointer")), ("fixed", L("固定在主螢幕", "Main display only"))])
            }
            ToggleRow(title: L("滑鼠經過時讓開", "Get out of the way on hover"),
                      detail: L("滑鼠移到展開的小島上，小島先縮回瀏海，讓你點得到下面的東西；碰到最上面的瀏海則維持展開。", "When the pointer moves over the expanded island, it shrinks back into the notch so you can click what's underneath. Hovering the notch itself keeps it open."),
                      isOn: $store.t.yieldOnHover)
            ToggleRow(title: L("多個任務時顯示 session 標題", "Show session titles with multiple tasks"), last: true, isOn: $store.t.showTitle)
        }

        SettingSection(title: L("任務", "Tasks")) {
            SliderSettingRow(title: L("送出後沒動靜自動暫停", "Auto-pause when nothing happens"),
                             detail: L("送出後馬上取消時 Claude Code 不會留下紀錄；這麼多秒沒動靜就當作停了。設 0 不自動暫停。", "If you cancel right after sending, Claude Code leaves no record, so after this many seconds of silence the task counts as stopped. Set to 0 to turn this off."),
                             last: true, value: $store.t.idlePause, range: 0...60, unit: L("秒", "s"))
        }

        SettingSection(title: L("工具", "Tools")) {
            if isDevBuild {
                SettingRow(title: L("示範模式", "Demo mode"), detail: L("讓小島照各種狀態跑一遍，方便錄影。（只有測試版有）", "Runs the island through every state, handy for screen recordings. (Test build only)")) {
                    Button(L("開啟示範…", "Open demo…")) { NotificationCenter.default.post(name: openDemoNotification, object: nil) }
                }
            }
            SettingRow(title: L("恢復預設外觀", "Reset appearance"), detail: L("外觀、尺寸回到預設值；行為和通知的設定不變。設定都會自動儲存。", "Restores appearance and size defaults; behavior and notification settings stay as they are. Settings save automatically."), last: true) {
                Button(L("恢復預設", "Reset")) {
                    let keep = store.t
                    store.t = Tuning()
                    store.t.mode = keep.mode
                    store.t.external = keep.external
                    store.t.screenSwitch = keep.screenSwitch
                    store.t.yieldOnHover = keep.yieldOnHover
                    store.t.idlePause = keep.idlePause
                    store.t.popOnFinish = keep.popOnFinish
                    store.t.systemNotify = keep.systemNotify
                    store.t.completionSound = keep.completionSound
                    store.t.sound = keep.sound
                }
            }
        }
    }
}

// MARK: - 通知

struct NotificationsPage: View {
    @ObservedObject var store: TuningStore

    var body: some View {
        SettingSection(title: L("小島", "Island")) {
            ToggleRow(title: L("任務結束時彈出提醒", "Pop up when a task ends"), detail: L("就算小島沒在顯示，任務完成或停下時也彈出來讓你知道。", "Even when the island is hidden, it pops out to let you know a task finished or stopped."),
                      last: true, isOn: $store.t.popOnFinish)
        }
        SettingSection(title: L("完成時", "When done"),
                       footer: L("額度用完、中斷、出錯不會發通知，由小島本身提醒。", "Usage limits, interruptions and errors don't send notifications; the island shows them instead.")) {
            ToggleRow(title: L("系統通知", "System notification"), detail: L("點通知會回到那個任務所在的 Terminal 分頁。", "Clicking the notification takes you back to that task's Terminal tab."), isOn: $store.t.systemNotify)
            ToggleRow(title: L("播放音效", "Play a sound"), isOn: $store.t.completionSound)
            SettingRow(title: L("完成音效", "Completion sound"), last: true) {
                SoundControl(selection: $store.t.sound)
                    .disabled(!store.t.completionSound)
                    .opacity(store.t.completionSound ? 1 : 0.4)
            }
        }
    }
}

// MARK: - 外觀

struct AppearancePage: View {
    @ObservedObject var store: TuningStore

    var body: some View {
        SettingSection(title: L("預覽", "Preview")) {
            PreviewBlock(t: store.t)
            ToggleRow(title: L("在螢幕上預覽", "Preview on screen"), detail: L("直接在瀏海上展開範例，邊調邊看。", "Expands a sample on the notch so you can see changes as you make them."), last: true, isOn: $store.preview)
        }
        SettingSection(title: L("顯示內容", "Content"), footer: L("關掉的部分不顯示，小島也會跟著變小。全部關掉、只留貓咪場景，就是最小的樣子。", "Anything you turn off is hidden and the island shrinks to fit. Turn everything off except the cat scene for the smallest island.")) {
            ToggleRow(title: L("上面那行細節", "Detail line"), detail: L("正在讀的檔案、跑的指令、完成了什麼。", "The file being read, the command running, what got done."), isOn: $store.t.showDetail)
            ToggleRow(title: L("狀態字", "Status text"), detail: "Thinking、Running command…", isOn: $store.t.showLabel)
            ToggleRow(title: L("想事情時用 Claude Code 的趣味動詞", "Claude Code's playful thinking words"),
                      detail: L("Thinking 改成 Claude Code 轉圈時的 Whirring…、Pondering…、Brewing… 這類字，每 8 秒換一個。",
                                "Shows Claude Code's spinner words like Whirring…, Pondering… and Brewing… instead of Thinking, changing every 8 seconds."),
                      isOn: $store.t.funVerbs)
                .disabled(!store.t.showLabel).opacity(store.t.showLabel ? 1 : 0.4)
            ToggleRow(title: L("token 數", "Token count"), last: true, isOn: $store.t.showTokens)
        }
        SettingSection(title: L("圖示", "Icon")) {
            ToggleRow(title: L("顯示圖示", "Show icon"), isOn: $store.t.showIcon)
            SettingRow(title: L("圖示風格", "Icon style")) {
                PillPicker(selection: $store.t.iconStyle, options: [("pixel", L("像素格", "Pixel")), ("orb", L("光核", "Orb"))])
                    .disabled(!store.t.showIcon).opacity(store.t.showIcon ? 1 : 0.4)
            }
            SliderSettingRow(title: L("圖示大小", "Icon size"), last: true, value: $store.t.iconCell, range: 3...12)
                .disabled(!store.t.showIcon).opacity(store.t.showIcon ? 1 : 0.4)
        }
        SettingSection(title: L("小島底部", "Island bottom")) {
            ToggleRow(title: L("貓咪場景", "Cat scene"), detail: L("點陣貓照 Claude 的狀態奔跑、坐著想事情、睡覺…", "A dot-matrix cat that runs, sits and thinks, or sleeps along with Claude."), isOn: $store.t.catScene)
            ToggleRow(title: L("底部漸層光", "Bottom glow"), detail: L("顏色跟著圖示，像呼吸一樣慢慢亮暗。", "Matches the icon color and slowly breathes brighter and dimmer."), last: true, isOn: $store.t.orbAura)
        }
        SettingSection(title: L("文字", "Text")) {
            SliderSettingRow(title: L("狀態字級", "Status text size"), value: $store.t.labelSize, range: 11...26)
            SliderSettingRow(title: L("細節字級", "Detail text size"), value: $store.t.detailSize, range: 9...22)
            SliderSettingRow(title: L("標題字級", "Title text size"), last: true, value: $store.t.titleSize, range: 8...16)
                .disabled(!store.t.showTitle).opacity(store.t.showTitle ? 1 : 0.4)
        }
    }
}

// MARK: - 尺寸與外框

struct LayoutPage: View {
    @ObservedObject var store: TuningStore

    var body: some View {
        SettingSection(title: L("預覽", "Preview")) { PreviewBlock(t: store.t) }
        SettingSection(title: L("尺寸", "Size")) {
            SliderSettingRow(title: L("最小寬度", "Minimum width"), value: $store.t.minWidth, range: 200...600)
            SliderSettingRow(title: L("最大寬度", "Maximum width"), value: $store.t.maxWidth, range: 260...800)
            SliderSettingRow(title: L("上下留白", "Vertical padding"), value: $store.t.vGap, range: 4...40)
            SliderSettingRow(title: L("左右留白", "Horizontal padding"), value: $store.t.sidePad, range: 8...80)
            SliderSettingRow(title: L("行距", "Line spacing"), last: true, value: $store.t.lineGap, range: 0...24)
        }
        SettingSection(title: L("外框", "Frame"), footer: L("到「外觀」打開「在螢幕上預覽」，可以看展開／收合的彈跳效果。", "Turn on Preview on screen under Appearance to see the expand/collapse bounce.")) {
            SliderSettingRow(title: L("內凹寬度", "Wing width"), value: $store.t.wing, range: 0...60)
            SliderSettingRow(title: L("下緣圓角", "Corner radius"), value: $store.t.radius, range: 6...50)
            SliderSettingRow(title: L("彈跳程度", "Bounce"), last: true, value: $store.t.bounce, range: 0...100, unit: "%")
        }
    }
}

// MARK: - 關於

struct AboutPage: View {
    @State private var showLicenses = false
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var store = appTuning

    var body: some View {
        HStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 80, height: 80)
            VStack(alignment: .leading, spacing: 5) {
                Text("Agent Island").font(.system(size: 22, weight: .bold)).foregroundStyle(SettingsStyle.text)
                Text(L("版本 ", "Version ") + appVersion + (appBuild.isEmpty ? "" : " (\(appBuild))") + (isDevBuild ? L(" · 測試版", " · Test build") : ""))
                    .font(.system(size: 13)).foregroundStyle(SettingsStyle.secondary)
                Text(L("你的 AI Agent 在做什麼，瀏海上一眼就知道。", "See what your AI agent is doing at a glance, right in your MacBook's notch."))
                    .font(.system(size: 13)).foregroundStyle(SettingsStyle.secondary)
            }
        }
        SettingSection(title: L("更新", "Updates")) {
            ToggleRow(title: L("自動檢查更新", "Check for updates automatically"), detail: L("每小時去 GitHub 看一次有沒有新版本，有的話在設定視窗最上面和選單裡提醒你。", "Checks GitHub every hour. When a new version is out, you'll see it at the top of Settings and in the menu."), isOn: $store.t.autoUpdate)
                .onChange(of: store.t.autoUpdate) { _, on in updater.setAutomatic(on) }
            SettingRow(title: L("目前版本 \(appVersion)", "Current version \(appVersion)"), detail: updateDetail, last: true) {
                switch updater.state {
                case .available(let v): Button(L("更新到 \(v)", "Update to \(v)")) { updater.checkNow() }
                default: Button(L("檢查更新", "Check for updates")) { updater.checkNow() }
                }
            }
        }
        SettingSection(title: L("資訊", "Info")) {
            SettingRow(title: L("原始碼", "Source code")) {
                Link("github.com/1413jean/agent-island", destination: URL(string: "https://github.com/1413jean/agent-island")!)
                    .font(.system(size: 13))
            }
            SettingRow(title: L("開源授權", "Open-source licenses"), detail: L("用到的開源元件和它們的授權聲明。", "Open-source components used and their license notices."), last: true) {
                Button(L("第三方授權…", "Third-party licenses…")) { showLicenses = true }
            }
        }
        .sheet(isPresented: $showLicenses) { LicensesView() }
        SettingSection(title: L("結束", "Quit")) {
            SettingRow(title: L("結束 Agent Island", "Quit Agent Island"),
                       detail: L("結束後小島就不會顯示；要再打開，從「應用程式」資料夾或 Spotlight 開 Agent Island。", "After quitting, the island won't show. To bring it back, open Agent Island from Applications or Spotlight."), last: true) {
                Button(L("結束", "Quit")) { NSApp.terminate(nil) }
            }
        }
    }
}

extension AboutPage {
    var updateDetail: String {
        let when = updater.lastChecked.map { L("上次檢查：", "Last checked: ") + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
        switch updater.state {
        case .idle: return when.isEmpty ? L("按「檢查更新」看看有沒有新版本。", "Click Check for updates to see if there's a new version.") : when
        case .upToDate: return L("已經是最新版本。", "You're on the latest version.") + (when.isEmpty ? "" : " " + when)
        case .available(let v): return L("有新版本 \(v)。按「更新」可以看更新內容並安裝，裝好會自動重新打開。", "Version \(v) is available. Click Update to see what's new and install it; the app reopens when it's done.")
        case .failed(let why): return L("檢查失敗：\(why)", "Check failed: \(why)")
        }
    }
}

// MARK: - Claude Code

struct ClaudeCodePage: View {
    @ObservedObject private var store = appTuning
    @State private var status = ClaudeCodeLink.status()
    @State private var confirm = false
    @State private var error: String?

    var body: some View {
        SettingSection(title: L("連接", "Connection"),
                       footer: L("已經開著的 Claude Code 要重新開，才會開始通知小島。hook 用 macOS 內建的 python3 執行；第一次用時，系統可能會請你安裝「命令列開發工具」。", "Restart any Claude Code session that's already open before it starts reporting to the island. The hook runs with macOS's built-in python3; the first time, macOS may ask you to install the Command Line Developer Tools.")) {
            SettingRow(title: title, detail: detail, last: true) {
                switch status {
                case .connected: Button(L("中斷連接", "Disconnect")) { run(ClaudeCodeLink.disconnect) }
                case .disconnected: Button(L("連接…", "Connect…")) { confirm = true }
                case .outdated: Button(L("更新連接", "Update connection")) { run(ClaudeCodeLink.connect) }
                case .noClaudeCode: Button(L("重新檢查", "Check again")) { status = ClaudeCodeLink.status() }
                }
            }
        }
        .alert(L("連接 Claude Code", "Connect Claude Code"), isPresented: $confirm) {
            Button(L("連接", "Connect")) { run(ClaudeCodeLink.connect) }
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L("會在 ~/.claude/settings.json 加上小島的 hook（UserPromptSubmit、PreToolUse、PostToolUse、Stop、SessionEnd、Notification 各一條），其他設定都不會動。寫入前會先把原檔備份成 settings.json.agent-island-backup。", "This adds the island's hooks to ~/.claude/settings.json (one each for UserPromptSubmit, PreToolUse, PostToolUse, Stop, SessionEnd and Notification) and leaves your other settings alone. The original file is backed up to settings.json.agent-island-backup first."))
        }
        .alert(L("沒辦法完成", "Couldn't finish"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L("好", "OK")) {}
        } message: { Text(error ?? "") }
        .onAppear { status = ClaudeCodeLink.status() }

        SettingSection(title: "Codex",
                       footer: L("讀 Codex 自己寫的工作紀錄（~/.codex/sessions），不用另外設定、不花 token。紀錄格式不是公開規格，Codex 改版時可能要更新小島。",
                                 "Reads the work log Codex writes itself (~/.codex/sessions): no setup, no tokens. The log format isn't a public spec, so a Codex update may need an island update.")) {
            ToggleRow(title: L("也顯示 Codex 的任務", "Show Codex tasks too"),
                      detail: CodexWatcher.available ? L("有找到 Codex。", "Codex found on this Mac.")
                                                     : L("這台 Mac 還沒有 Codex 的紀錄。", "No Codex logs on this Mac yet."),
                      last: true, isOn: $store.t.codexEnabled)
        }

        SettingSection(title: L("細節", "Details")) {
            SettingRow(title: L("hook 程式", "Hook script"), detail: ClaudeCodeLink.hookScript) { EmptyView() }
            SettingRow(title: L("設定檔", "Settings file"), detail: ClaudeCodeLink.settingsPath, last: true) {
                Button(L("在 Finder 顯示", "Show in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: ClaudeCodeLink.settingsPath)])
                }
            }
        }
    }

    private var title: String {
        switch status {
        case .connected: return L("已連接 Claude Code", "Connected to Claude Code")
        case .disconnected: return L("還沒連接", "Not connected")
        case .outdated: return L("連接需要更新", "Connection needs an update")
        case .noClaudeCode: return L("找不到 Claude Code", "Claude Code not found")
        }
    }

    private var detail: String {
        switch status {
        case .connected: return L("Claude Code 做的每一步都會即時顯示在小島上。", "Every step Claude Code takes shows up on the island in real time.")
        case .disconnected: return L("按「連接」後，小島才看得到 Claude Code 正在做什麼。", "Connect so the island can see what Claude Code is doing.")
        case .outdated: return L("之前的連接指向別的位置（可能是舊版或 app 搬過家），更新後才會用這個 app 內建的 hook。", "The existing connection points somewhere else (an older version, or the app was moved). Update it to use this app's built-in hook.")
        case .noClaudeCode: return L("這台 Mac 還沒有 ~/.claude。先安裝並打開過一次 Claude Code，再回來按「重新檢查」。", "This Mac has no ~/.claude yet. Install Claude Code and open it once, then come back and click Check again.")
        }
    }

    private func run(_ f: () throws -> Void) {
        do { try f() } catch { self.error = error.localizedDescription }
        status = ClaudeCodeLink.status()
    }
}

// 第三方授權：打包在 app 裡的 THIRD_PARTY_NOTICES.md（MIT 要求散布時附上原作者的版權聲明）
struct LicensesView: View {
    @Environment(\.dismiss) private var dismiss
    private let text: String = {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return L("找不到授權檔案。", "License file not found.") }
        return s
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("第三方授權", "Third-party licenses")).font(.title3.bold())
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button(L("完成", "Done")) { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 560, height: 460)
    }
}

// 標題列的更新按鈕：有新版本時才出現，按了打開 Sparkle 的更新視窗
private struct UpdateBadge: View {
    @ObservedObject private var updater = Updater.shared
    @State private var hover = false

    var body: some View {
        if let v = updater.latestVersion {
            Button { updater.checkNow() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 12, weight: .semibold))
                    Text(L("更新到 \(v)", "Update to \(v)")).font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(SettingsStyle.accent.opacity(hover ? 1 : 0.88)))
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help(L("有新版本，按這裡看更新內容並安裝", "A new version is available. Click to see what's new and install it."))
        }
    }
}
