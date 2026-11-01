import Foundation
import MLX
import MLXEmbedders
import MLXLLM
import MLXLMCommon

/// The pack exported by `export_ios.py` (ios/Bundle/pack.json).
struct PackData: Decodable {
    struct Card: Decodable { let title: String; let kind: String }
    struct Fact: Decodable { let card: Int; let text: String }
    struct Unit: Decodable { let fact: Int; let text: String }
    struct Practice: Decodable { let q: String; let fact: Int }
    struct Scene: Decodable, Identifiable {
        let scene: String
        let online: Bool
        let q: String
        var id: String { q }
    }
    let name: String
    let title: String
    let student: String
    let bits: Int
    let not_in_pack: String
    let cards: [Card]
    let facts: [Fact]
    let units: [Unit]
    let practice: [Practice]
    let scenes: [Scene]
    let build: [String: Double]?
}

enum Bundled {
    static let root = Bundle.main.url(forResource: "Bundle", withExtension: nil)!
    static var model: URL { root.appending(component: "model") }
    static var embedder: URL { root.appending(component: "embedder") }
    static var pack: URL { root.appending(component: "pack.json") }
}

/// "Hey Meta, what's for lunch?" -> "what's for lunch?". Mirrors pocketmuse.config.strip_wake.
enum Wake {
    static let regex = try! NSRegularExpression(
        pattern: #"^\s*(hey|hi|ok|okay)[\s,]+(meta|muse)[\s,.!:?]*"#, options: [.caseInsensitive])

    static func strip(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let out = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
        return out.isEmpty ? text : out
    }

    /// Where the wake phrase ends inside a running transcript, if it was said.
    static func find(in text: String) -> String.Index? {
        let any = try! NSRegularExpression(
            pattern: #"\b(hey|hi|ok|okay)[\s,]+(meta|muse)\b[\s,.!:?]*"#, options: [.caseInsensitive])
        let ns = NSRange(text.startIndex..., in: text)
        guard let m = any.matches(in: text, range: ns).last, let r = Range(m.range, in: text) else { return nil }
        return r.upperBound
    }
}

/// Pocket Muse on the phone: the pack's fused Llama 3.2 student plus the same fact retrieval it was
/// trained with (pocketmuse.pack.FactIndex), all on-device.
actor Brain {
    let pack: PackData
    private var llm: MLXLMCommon.ModelContainer?
    private var embedder: MLXEmbedders.ModelContainer?
    private var unitVecs: [[Float]] = []
    private var practiceVecs: [[Float]] = []

    init() throws {
        pack = try JSONDecoder().decode(PackData.self, from: Data(contentsOf: Bundled.pack))
    }

    func load(progress: @escaping @Sendable (String) -> Void) async throws {
        MLX.GPU.set(cacheLimit: 256 * 1024 * 1024)
        progress("Loading embedder")
        let emb = try await MLXEmbedders.loadModelContainer(
            configuration: MLXEmbedders.ModelConfiguration(directory: Bundled.embedder))
        embedder = emb
        progress("Indexing \(pack.units.count) pack facts")
        unitVecs = try await embed(pack.units.map(\.text))
        practiceVecs = try await embed(pack.practice.map(\.q))
        progress("Loading Llama 3.2 student")
        llm = try await LLMModelFactory.shared.loadContainer(
            configuration: MLXLMCommon.ModelConfiguration(directory: Bundled.model))
        progress("Warming up")
        _ = try await answer("hello")
        progress("Ready")
    }

    // MARK: Retrieval (port of FactIndex)

    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard let embedder else { return [] }
        var out: [[Float]] = []
        for start in stride(from: 0, to: texts.count, by: 32) {
            let batch = Array(texts[start ..< min(start + 32, texts.count)])
            let vecs = await embedder.perform { model, tokenizer, _ -> [[Float]] in
                let ids = batch.map { Array(tokenizer.encode(text: $0, addSpecialTokens: true).prefix(512)) }
                let maxLen = ids.map(\.count).max() ?? 1
                let padded = stacked(ids.map { MLXArray($0 + Array(repeating: 0, count: maxLen - $0.count)) })
                let mask = padded .!= 0
                let out = model(padded, positionIds: nil, tokenTypeIds: MLXArray.zeros(like: padded), attentionMask: mask)
                // bge uses the [CLS] hidden state, L2-normalized (as sentence-transformers does).
                var cls = out.hiddenStates![0..., 0, 0...]
                cls = cls / MLX.sqrt(MLX.sum(cls * cls, axis: -1, keepDims: true))
                cls.eval()
                return (0 ..< batch.count).map { cls[$0].asArray(Float.self) }
            }
            out += vecs
        }
        return out
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        for i in 0 ..< min(a.count, b.count) { s += a[i] * b[i] }
        return s
    }

    private static let sentence = try! NSRegularExpression(pattern: #"(?<=[.!?])\s+(?=[A-Z0-9])"#)

    /// The sentence that actually asks something; preamble pulls retrieval toward the wrong facts.
    static func focus(_ q: String) -> String {
        let s = q.trimmingCharacters(in: .whitespaces)
        var parts: [String] = []
        var last = s.startIndex
        for m in sentence.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let r = Range(m.range, in: s) else { continue }
            parts.append(String(s[last ..< r.lowerBound]))
            last = r.upperBound
        }
        parts.append(String(s[last...]))
        parts = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let asks = parts.filter { $0.hasSuffix("?") }
        return parts.count > 1 && !asks.isEmpty ? asks.last! : q
    }

    static func labelDay(_ fact: String, today: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE MMM d:"
        for (offset, word) in [(0, "Today"), (1, "Tomorrow")] {
            let day = Calendar.current.date(byAdding: .day, value: offset, to: today)!
            if fact.hasPrefix(f.string(from: day)) { return "\(word), \(fact)" }
        }
        return fact
    }

    func notes(for question: String, k: Int = 4) async throws -> String {
        let q = Self.focus(question)
        guard let qv = try await embed([q]).first else { return "" }
        var scores = [Float](repeating: -1, count: pack.facts.count)
        for (i, u) in pack.units.enumerated() {
            scores[u.fact] = max(scores[u.fact], Self.dot(unitVecs[i], qv))
        }
        let sims = practiceVecs.map { Self.dot($0, qv) }
        for i in sims.indices.sorted(by: { sims[$0] > sims[$1] }).prefix(5)
        where sims[i] >= 0.75 && pack.practice[i].q != q {
            scores[pack.practice[i].fact] += 0.1 * sims[i]
        }
        var picked = Array(scores.indices.sorted { scores[$0] > scores[$1] }.prefix(k))
        // Forecast days in date order (today first), as in training.
        let isForecast = { (i: Int) in self.pack.cards[self.pack.facts[i].card].kind == "forecast" }
        var forecast = picked.filter(isForecast).sorted()
        picked = picked.map { isForecast($0) ? forecast.removeFirst() : $0 }

        var order: [Int] = []
        var groups: [Int: [String]] = [:]
        for i in picked {
            let fact = pack.facts[i]
            let text = isForecast(i) ? Self.labelDay(fact.text, today: Date()) : fact.text
            if groups[fact.card] == nil { order.append(fact.card) }
            groups[fact.card, default: []].append(text)
        }
        return order.map { c in
            "## \(pack.cards[c].title)\n" + groups[c]!.map { "- \($0)" }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    // MARK: Answer

    func systemPrompt(notes: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE, MMMM d"
        return "You are Pocket Muse, the on-device part of Muse. Muse prepared you ahead for: \(pack.title). "
            + "Today is \(f.string(from: Date())).\n"
            + "Answer in 1-2 short sentences using only the pack notes below. "
            + "If the notes do not answer the question, say \"\(pack.not_in_pack)\" and that you will ask Muse "
            + "when you're online.\n\n"
            + "Pack notes:\n\(notes.isEmpty ? "(none)" : notes)"
    }

    func answer(_ raw: String, maxTokens: Int = 120) async throws -> String {
        guard let llm else { return "" }
        let question = Wake.strip(raw)
        let notes = try await notes(for: question)
        let input = UserInput(chat: [.system(systemPrompt(notes: notes)), .user(question)])
        var params = GenerateParameters(maxTokens: maxTokens, temperature: 0)
        params.prefillStepSize = 512
        return try await llm.perform { context in
            let lmInput = try await context.processor.prepare(input: input)
            var text = ""
            for await item in try MLXLMCommon.generate(input: lmInput, parameters: params, context: context) {
                if let chunk = item.chunk { text += chunk }
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func isNotInPack(_ text: String) -> Bool {
        text.lowercased().contains(pack.not_in_pack.lowercased())
    }
}
