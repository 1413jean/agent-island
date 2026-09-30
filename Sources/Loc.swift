import Foundation

// 介面語言：中文或英文。設定裡可以選「自動（跟系統）」「中文」「English」。
// 字串直接寫成 L("中文", "English")，兩種語言放在一起，改字時不會漏改另一種。
enum AppLanguage {
    static var isEnglish: Bool {
        switch appTuning.t.language {
        case "en": return true
        case "zh": return false
        default: return !(Locale.preferredLanguages.first ?? "en").hasPrefix("zh")
        }
    }
}

func L(_ zh: String, _ en: String) -> String { AppLanguage.isEnglish ? en : zh }
