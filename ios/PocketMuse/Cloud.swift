import Foundation

/// Big Muse (Muse Spark Open on Baseten), for questions the pack can't answer while there's signal.
/// The key comes from ios/Secrets.xcconfig (gitignored) through Info.plist; without it, questions are queued.
enum Cloud {
    static let model = "meta-models/muse-spark-open-1026"
    static let system = "You are Muse, a helpful personal assistant speaking through smart glasses. "
        + "Answer in 2-3 short spoken sentences. Plain text only: no lists, markdown or LaTeX."

    static var key: String? {
        let k = (Bundle.main.object(forInfoDictionaryKey: "BasetenKey") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return k.isEmpty || k.hasPrefix("$(") ? nil : k
    }

    struct Reply { let text: String; let cost: Double }

    static func ask(_ question: String) async throws -> Reply {
        guard let key else { throw URLError(.userAuthenticationRequired) }
        var req = URLRequest(url: URL(string: "https://inference.baseten.co/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": question]],
            "max_tokens": 4000,
            "reasoning_effort": "low",
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])
        let text = (message?["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let usage = json?["usage"] as? [String: Any]
        let inTok = usage?["prompt_tokens"] as? Double ?? 0
        let outTok = usage?["completion_tokens"] as? Double ?? 0
        return Reply(text: text, cost: (inTok * 1.25 + outTok * 4.25) / 1_000_000)
    }
}
