import Foundation
import Security

enum AIProvider: String, CaseIterable, Identifiable {
    case deepseek, openai, anthropic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic (Claude)"
        }
    }

    var defaultModel: String {
        switch self {
        case .deepseek: return "deepseek-chat"
        case .openai: return "gpt-4o-mini"
        case .anthropic: return "claude-haiku-5-5"
        }
    }

    var endpoint: String {
        switch self {
        case .deepseek: return "https://api.deepseek.com/chat/completions"
        case .openai: return "https://api.openai.com/v1/chat/completions"
        case .anthropic: return "https://api.anthropic.com/v1/messages"
        }
    }
}

/// Stores each provider's API key in the iOS Keychain instead of plain preferences.
enum KeyStore {
    private static func service(_ p: AIProvider) -> String { "translator.key.\(p.rawValue)" }

    static func load(_ p: AIProvider) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(p),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
           let data = out as? Data,
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return ""
    }

    static func save(_ value: String, _ p: AIProvider) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(p)
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

struct AIResult {
    let source: String
    let translation: String
}

enum AIError: LocalizedError {
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .http(let code, let body): return "خطأ \(code): \(body)"
        case .badResponse: return "رد غير مفهوم من الـAI"
        }
    }
}

/// Optional online step: fixes speech-recognition mistakes using the recent conversation
/// and translates. Arabic output is written in Lebanese colloquial wording.
/// Works with DeepSeek and OpenAI (chat completions) and Anthropic (messages).
final class AIService: @unchecked Sendable {

    func process(text: String,
                 from: Lang,
                 to: Lang,
                 context: [String],
                 glossary: String,
                 provider: AIProvider,
                 key: String,
                 model: String,
                 previous: String = "",
                 fragment: Bool = false) async throws -> AIResult {
        let system = """
        You are the engine of a live interpreter app. The input is automatic speech recognition output and often contains mistakes: wrong words, sound-alike words, missing or extra words, broken sentences and missing punctuation.
        Like a careful human interpreter, work out what the speaker really meant, using the recent conversation, the glossary and common sense, silently fix those mistakes, then translate. If a word is truly unclear, keep it as heard rather than inventing something.
        If the source language is Arabic, the speaker is Lebanese: the text is Lebanese colloquial Arabic, not Modern Standard Arabic. Understand it with the Lebanese dictionary below and never treat it as another language.
        If the target language is Arabic, write the translation in natural spoken Lebanese Arabic, in Arabic script, exactly as a Lebanese person would say it in daily speech, and NOT in formal Modern Standard Arabic.
        You are ONLY a translator: never answer, never reply to the speaker, never add comments. If the text is a question, translate the question. The translation MUST be in the target language, never in the source language. If the input is meaningless noise or a clear speech-recognition hallucination, return an empty translation.
        Keep names, numbers, prices and units exact. Keep the meaning and tone, do not add or remove information, and do not explain anything.
        \(fragment ? "IMPORTANT: this is simultaneous interpreting. The text to translate is only a FRAGMENT of a sentence that the speaker is still saying. Translate just this fragment so that it flows naturally after the earlier fragments. Do not repeat or redo the earlier fragments, do not complete the sentence, and do not add a final full stop if the fragment is clearly unfinished." : "")

        Lebanese dictionary (Lebanese = meaning):
        \(LebaneseDictionary.words)

        Examples:
        \(LebaneseDictionary.examples)

        Reply with a single JSON object and nothing else: {"source":"<corrected text in the source language>","translation":"<translation in the target language>"}
        """

        var user = "Source language: \(from.englishName)\nTarget language: \(to.englishName)\n"
        let g = glossary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !g.isEmpty { user += "Glossary and topic hints: \(g)\n" }
        if !context.isEmpty { user += "Recent conversation:\n" + context.joined(separator: "\n") + "\n" }
        if fragment && !previous.isEmpty { user += "Earlier fragments of this same sentence (already translated, do not repeat): \(previous)\n" }
        user += "Text to translate: \(text)"

        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let useModel = model.trimmingCharacters(in: .whitespaces).isEmpty ? provider.defaultModel : model

        var req = URLRequest(url: URL(string: provider.endpoint)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 25
        req.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any]
        switch provider {
        case .anthropic:
            req.setValue(trimmedKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = [
                "model": useModel,
                "max_tokens": 400,
                "system": system,
                "messages": [["role": "user", "content": user]]
            ]
        case .deepseek, .openai:
            req.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
            body = [
                "model": useModel,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user]
                ]
            ]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AIError.badResponse }
        guard http.statusCode == 200 else {
            let snippet = String(String(data: data, encoding: .utf8)?.prefix(160) ?? "")
            throw AIError.http(http.statusCode, snippet)
        }

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.badResponse
        }

        let raw: String?
        switch provider {
        case .anthropic:
            let content = obj["content"] as? [[String: Any]]
            raw = content?.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String
        case .deepseek, .openai:
            let choices = obj["choices"] as? [[String: Any]]
            let message = choices?.first?["message"] as? [String: Any]
            raw = message?["content"] as? String
        }

        guard let raw = raw,
              let open = raw.firstIndex(of: "{"),
              let close = raw.lastIndex(of: "}"),
              open < close,
              let jsonData = String(raw[open...close]).data(using: .utf8),
              let parsed = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let translation = parsed["translation"] as? String,
              !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw AIError.badResponse }

        let source = (parsed["source"] as? String) ?? ""
        return AIResult(source: source, translation: translation)
    }
}
