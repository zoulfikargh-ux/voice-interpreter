import Foundation

enum Lang: String, CaseIterable, Identifiable, Codable, Hashable {
    case zh, en, ar

    var id: String { rawValue }

    var name: String {
        switch self {
        case .zh: return "صيني"
        case .en: return "إنجليزي"
        case .ar: return "عربي"
        }
    }

    var speechLocale: Locale {
        switch self {
        case .zh: return Locale(identifier: "zh-CN")
        case .en: return Locale(identifier: "en-US")
        case .ar: return Locale(identifier: "ar-SA")
        }
    }

    var englishName: String {
        switch self {
        case .zh: return "Mandarin Chinese"
        case .en: return "English"
        case .ar: return "Arabic"
        }
    }

    var ttsCode: String {
        switch self {
        case .zh: return "zh-CN"
        case .en: return "en-US"
        case .ar: return "ar-SA"
        }
    }
}

struct Heard {
    let lang: Lang
    let text: String
    let pitch: Float?
    let utt: Int
}
