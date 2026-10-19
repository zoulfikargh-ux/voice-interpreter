import Foundation
import Security

/// Small Keychain helper for the Azure key.
enum AzureStore {
    private static let service = "translator.key.azure"
    static func load() -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data, let s = String(data: d, encoding: .utf8) { return s }
        return ""
    }
    static func save(_ v: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let data = t.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Azure neural text to speech (Lebanese Arabic, Mandarin, English). Raw PCM 24 kHz 16 bit mono.
enum AzureTTS {
    static func voice(_ l: Lang, female: Bool) -> (locale: String, name: String) {
        switch l {
        case .ar: return ("ar-LB", female ? "ar-LB-LaylaNeural" : "ar-LB-RamiNeural")
        case .zh: return ("zh-CN", female ? "zh-CN-XiaoxiaoNeural" : "zh-CN-YunxiNeural")
        case .en: return ("en-US", female ? "en-US-JennyNeural" : "en-US-GuyNeural")
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func speak(text: String, lang: Lang, female: Bool, key: String, region: String) async throws -> Data {
        let v = voice(lang, female: female)
        let reg = region.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let url = URL(string: "https://\(reg).tts.speech.microsoft.com/cognitiveservices/v1") else { throw AIError.badResponse }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue(key.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        req.setValue("application/ssml+xml", forHTTPHeaderField: "Content-Type")
        req.setValue("raw-24khz-16bit-mono-pcm", forHTTPHeaderField: "X-Microsoft-OutputFormat")
        req.setValue("VoiceInterpreter", forHTTPHeaderField: "User-Agent")
        let ssml = "<speak version='1.0' xml:lang='\(v.locale)'><voice name='\(v.name)'>\(escape(text))</voice></speak>"
        req.httpBody = ssml.data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AIError.badResponse }
        guard http.statusCode == 200 else {
            let snippet = String(String(data: data, encoding: .utf8)?.prefix(200) ?? "")
            throw AIError.http(http.statusCode, snippet)
        }
        return data
    }
}

/// Azure speech to text (fast transcription). Several candidate languages: Azure picks the spoken one.
enum AzureSTT {
    static func locale(_ l: Lang) -> String {
        switch l { case .ar: return "ar-LB"; case .zh: return "zh-CN"; case .en: return "en-US" }
    }

    static func transcribe(wav: Data, langs: [Lang], key: String, region: String) async throws -> String {
        let reg = region.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let url = URL(string: "https://\(reg).api.cognitive.microsoft.com/speechtotext/transcriptions:transcribe?api-version=2024-11-15") else { throw AIError.badResponse }
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue(key.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let locales = Array(Set(langs.map { locale($0) })).sorted()
        let defJSON = try JSONSerialization.data(withJSONObject: ["locales": locales])
        var body = Data()
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"definition\"\r\nContent-Type: application/json\r\n\r\n".data(using: .utf8)!)
        body.append(defJSON)
        body.append("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AIError.badResponse }
        guard http.statusCode == 200 else {
            let snippet = String(String(data: data, encoding: .utf8)?.prefix(200) ?? "")
            throw AIError.http(http.statusCode, snippet)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIError.badResponse }
        if let c = obj["combinedPhrases"] as? [[String: Any]], let t = c.first?["text"] as? String {
            return t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }
}
