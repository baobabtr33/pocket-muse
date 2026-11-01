import Foundation
import MLX
import MLXEmbedders
import MLXLLM
import MLXLMCommon

/// One day's pack, exported by `export_ios.py` (ios/Bundle/packs/<id>/pack.json).
struct PackData: Decodable, Sendable {
    struct Card: Decodable, Sendable, Identifiable {
        let title: String
        let kind: String
        let why: String
        let facts: [String]
        var id: String { title }
    }
    struct Fact: Decodable, Sendable { let card: Int; let text: String }
    struct Unit: Decodable, Sendable { let fact: Int; let text: String }
    struct Practice: Decodable, Sendable { let q: String; let fact: Int }
    struct Learned: Decodable, Sendable, Identifiable {
        let q: String
        let a: String
        let card: Int?
        let kind: String
        var id: String { q + a }
    }
    struct Scene: Decodable, Sendable, Identifiable {
        let scene: String
        let online: Bool
        let q: String
        var id: String { q }
    }
    let id: String
    let name: String
    let plan: String
    let title: String
    let reasoning: String
    let student: String
    let not_in_pack: String
    let cards: [Card]
    let facts: [Fact]
    let units: [Unit]
    let practice: [Practice]
    let learned: [Learned]
    let scenes: [Scene]
    let build: [String: Double]?
}

struct PackEntry: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let name: String
    let title: String
}

struct Answer: Sendable {
    let text: String
    let notes: String
    let notInPack: Bool
}

enum Bundled {
    static let root = Bundle.main.url(forResource: "Bundle", withExtension: nil)!
    static var base: URL { root.appending(component: "base") }
    static var embedder: URL { root.appending(component: "embedder") }
    static var index: URL { root.appending(component: "index.json") }
    static func pack(_ id: String) -> URL { root.appending(components: "packs", id) }
    static func selftest(_ id: String) -> URL { root.appending(components: "selftest", id) }
}

/// "Hey Meta, what's for lunch?" -> "what's for lunch?". Mirrors pocketmuse.config.strip_wake.
enum Wake {
    static let leading = try! NSRegularExpression(
        pattern: #"^\s*(hey|hi|ok|okay)[\s,]+(meta|muse)[\s,.!:?]*"#, options: [.caseInsensitive])
    static let anywhere = try! NSRegularExpression(
        pattern: #"\b(hey|hi|ok|okay)[\s,]+(meta|muse)\b[\s,.!:?]*"#, options: [.caseInsensitive])

    static func strip(_ text: String) -> String {
        let out = leading.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ""
        ).trimmingCharacters(in: .whitespaces)
        return out.isEmpty ? text : out
    }

    /// Where the wake phrase ends inside a running transcript, if it was said.
    static func end(in text: String) -> String.Index? {
        let ns = NSRange(text.startIndex..., in: text)
        guard let m = anywhere.matches(in: text, range: ns).last, let r = Range(m.range, in: text) else { return nil }
        return r.upperBound
    }
}

/// Pocket Muse on the phone: Llama 3.2 1B (8-bit, shared) plus the day's LoRA adapter, and the same
/// fact retrieval the student was trained with (pocketmuse.pack.FactIndex). All on-device.
actor Brain {
    let index: [PackEntry]
    private(set) var pack: PackData?
    private var llm: MLXLMCommon.ModelContainer?
    private var embedder: MLXEmbedders.ModelContainer?
    private var adapter: LoRAContainer?
    private var unitVecs: [[Float]] = []
    private var practiceVecs: [[Float]] = []

    init() throws {
        index = try JSONDecoder().decode([PackEntry].self, from: Data(contentsOf: Bundled.index))
    }

    func load(progress: @escaping @Sendable (String) -> Void) async throws {
        MLX.GPU.set(cacheLimit: 256 * 1024 * 1024)
        progress("Loading embedder")
        embedder = try await MLXEmbedders.loadModelContainer(
            configuration: MLXEmbedders.ModelConfiguration(directory: Bundled.embedder))
        progress("Loading Llama 3.2 1B")
        llm = try await LLMModelFactory.shared.loadContainer(
            configuration: MLXLMCommon.ModelConfiguration(directory: Bundled.base))
    }

    /// Swap in another day's pack: its adapter (what Muse taught Llama) and its facts.
    func use(_ id: String) async throws -> PackData {
        guard let llm else { throw CocoaError(.featureUnsupported) }
        let dir = Bundled.pack(id)
        let data = try JSONDecoder().decode(PackData.self, from: Data(contentsOf: dir.appending(component: "pack.json")))
        let new = try LoRAContainer.from(directory: dir.appending(component: "adapter"))
        let old = adapter
        try await llm.perform { context in
            if let old { context.model.unload(adapter: old) }
            try context.model.load(adapter: new)
        }
        adapter = new
        pack = data
        unitVecs = try await embed(data.units.map(\.text))
        practiceVecs = try await embed(data.practice.map(\.q))
        _ = try await answer("hello")  // warm up so the first real question is fast
        return data
    }

    // MARK: Retrieval (port of FactIndex)

    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard let embedder else { return [] }
        var out: [[Float]] = []
        for start in stride(from: 0, to: texts.count, by: 32) {
            let batch = Array(texts[start ..< min(start + 32, texts.count)])
            out += await embedder.perform { model, tokenizer, _ -> [[Float]] in
                let ids = batch.map { Array(tokenizer.encode(text: $0, addSpecialTokens: true).prefix(512)) }
                let maxLen = ids.map(\.count).max() ?? 1
                let padded = stacked(ids.map { MLXArray($0 + Array(repeating: 0, count: maxLen - $0.count)) })
                let out = model(padded, positionIds: nil, tokenTypeIds: MLXArray.zeros(like: padded),
                                attentionMask: padded .!= 0)
                // bge uses the [CLS] hidden state, L2-normalized (as sentence-transformers does).
                var cls = out.hiddenStates![0..., 0, 0...]
                cls = cls / MLX.sqrt(MLX.sum(cls * cls, axis: -1, keepDims: true))
                cls.eval()
                return (0 ..< batch.count).map { cls[$0].asArray(Float.self) }
            }
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
        guard let pack else { return "" }
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
        let isForecast = { (i: Int) in pack.cards[pack.facts[i].card].kind == "forecast" }
        var forecast = picked.filter(isForecast).sorted()  // forecast days in date order, as in training
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

    /// Training and inference use this exact prompt (pocketmuse.config.student_system_prompt).
    func systemPrompt(title: String, notes: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE, MMMM d"
        return "You are Pocket Muse, the on-device part of Muse. Muse prepared you ahead for: \(title). "
            + "Today is \(f.string(from: Date())).\n"
            + "Answer in 1-2 short sentences using only the pack notes below. "
            + "If the notes do not answer the question, say \"That's not in your pack\" and that you will ask Muse "
            + "when you're online.\n\n"
            + "Pack notes:\n\(notes.isEmpty ? "(none)" : notes)"
    }

    func answer(_ raw: String, maxTokens: Int = 120) async throws -> Answer {
        guard let llm, let pack else { throw CocoaError(.featureUnsupported) }
        let question = Wake.strip(raw)
        let notes = try await notes(for: question)
        let input = UserInput(chat: [.system(systemPrompt(title: pack.title, notes: notes)), .user(question)])
        var params = GenerateParameters(maxTokens: maxTokens, temperature: 0)
        params.prefillStepSize = 512
        let text = try await llm.perform { context in
            let lmInput = try await context.processor.prepare(input: input)
            var text = ""
            for await item in try MLXLMCommon.generate(input: lmInput, parameters: params, context: context) {
                if let chunk = item.chunk { text += chunk }
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Answer(text: text, notes: notes,
                      notInPack: text.lowercased().contains(pack.not_in_pack.lowercased()))
    }
}
