import Foundation

/// Plain chat call used by the advisor mode of the text engines (DeepSeek, OpenAI, Claude).
extension AIService {
    func chat(system: String,
              messages: [[String: String]],
              provider: AIProvider,
              key: String,
              model: String) async throws -> String {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let useModel = model.trimmingCharacters(in: .whitespaces).isEmpty ? provider.defaultModel : model

        var req = URLRequest(url: URL(string: provider.endpoint)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any]
        switch provider {
        case .anthropic:
            req.setValue(trimmedKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = ["model": useModel, "max_tokens": 500, "system": system, "messages": messages]
        case .deepseek, .openai:
            req.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
            body = ["model": useModel, "messages": [["role": "system", "content": system]] + messages]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AIError.badResponse }
        guard http.statusCode == 200 else {
            let snippet = String(String(data: data, encoding: .utf8)?.prefix(160) ?? "")
            throw AIError.http(http.statusCode, snippet)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIError.badResponse }

        let raw: String?
        switch provider {
        case .anthropic:
            let content = obj["content"] as? [[String: Any]]
            raw = content?.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String
        case .deepseek, .openai:
            let choices = obj["choices"] as? [[String: Any]]
            raw = (choices?.first?["message"] as? [String: Any])?["content"] as? String
        }
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { throw AIError.badResponse }
        return text
    }
}
