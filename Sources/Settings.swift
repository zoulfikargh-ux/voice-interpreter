import Foundation
import Security

enum Keys {
    private static let service = "voice.openai.key"

    static func load() -> String {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
           let d = out as? Data, let s = String(data: d, encoding: .utf8) { return s }
        return ""
    }

    static func save(_ v: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let d = t.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = d
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

final class Settings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var mode: String { didSet { d.set(mode, forKey: "mode") } }          // interp | advisor
    @Published var pair: String { didSet { d.set(pair, forKey: "pair") } }          // arzh | aren | enzh
    @Published var voice: String { didSet { d.set(voice, forKey: "voice") } }
    @Published var model: String { didSet { d.set(model, forKey: "model") } }
    @Published var silenceMs: Int { didSet { d.set(silenceMs, forKey: "silenceMs") } }
    @Published var headphones: Bool { didSet { d.set(headphones, forKey: "headphones") } }
    @Published var glossary: String { didSet { d.set(glossary, forKey: "glossary") } }
    @Published var key: String { didSet { Keys.save(key) } }

    init() {
        mode = d.string(forKey: "mode") ?? "interp"
        pair = d.string(forKey: "pair") ?? "arzh"
        voice = d.string(forKey: "voice") ?? "marin"
        model = d.string(forKey: "model") ?? "gpt-realtime-2.1"
        let s = d.integer(forKey: "silenceMs")
        silenceMs = s == 0 ? 450 : s
        headphones = d.bool(forKey: "headphones")
        glossary = d.string(forKey: "glossary") ?? ""
        key = Keys.load()
    }
}

enum Instructions {
    static let names = ["ar": "Lebanese Arabic", "zh": "Mandarin Chinese", "en": "English"]
    static let pairs: [String: (String, String)] = ["arzh": ("ar", "zh"), "aren": ("ar", "en"), "enzh": ("en", "zh")]

    static func build(mode: String, pair: String, glossary: String) -> String {
        let g = glossary.trimmingCharacters(in: .whitespacesAndNewlines)
        let gl = g.isEmpty ? "" : "\nImportant names and terms: \(g)\n"
        if mode == "advisor" {
            return """
            You are a smart, warm and honest personal advisor and voice assistant for a Lebanese businessman who trades with China and also works with software. \
            Talk to him in natural spoken Lebanese Arabic with a Lebanese accent (not formal Modern Standard Arabic), the way a Lebanese friend would. \
            Keep every answer short and voice-friendly: usually one to three sentences. Ask a short question when you need more detail. \
            Give practical, honest advice, say when you are not sure, and do not flatter. If he speaks English or Chinese, still answer in Lebanese Arabic unless he asks you to switch.

            Lebanese dictionary (Lebanese = meaning) so you understand him well:
            \(LebaneseDictionary.words)
            \(gl)
            """
        }
        let p = pairs[pair] ?? ("ar", "zh")
        let a = names[p.0] ?? "", b = names[p.1] ?? ""
        return """
        You are a professional live voice interpreter. Two people are talking face to face and you sit between them.
        The two languages are: \(a) and \(b).
        STRICT RULES:
        1. You are ONLY an interpreter. Never answer questions yourself, never chat, never greet, never comment, never explain, never say that you are translating. Say nothing except the translation.
        2. When you hear \(a), immediately speak the translation in \(b). When you hear \(b), immediately speak the translation in \(a). Always translate into the OTHER language of the pair, never repeat in the same language.
        3. If you hear a third language, noise, silence or just breathing, say nothing.
        4. Translate completely and faithfully. Keep names, numbers, prices and units exact. Like a careful human interpreter, silently fix obvious mistakes in what you heard using context, and keep the meaning and tone.
        5. Arabic here always means Lebanese colloquial Arabic. Understand it using the dictionary below. When you speak Arabic, speak natural spoken Lebanese Arabic with a Lebanese accent, exactly as a Lebanese person would say it in daily speech, NOT formal Modern Standard Arabic.
        6. Be fast and natural: start speaking as soon as you understand, use short natural phrasing.
        \(gl)
        Lebanese dictionary (Lebanese = meaning):
        \(LebaneseDictionary.words)

        Examples of good translations:
        \(LebaneseDictionary.examples)
        """
    }
}
