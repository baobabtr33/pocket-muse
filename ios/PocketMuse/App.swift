import AVFoundation
import Network
import SwiftUI

@main
struct PocketMuseApp: App {
    @StateObject private var app = AppModel()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(app)
                .environmentObject(app.voice)
                .preferredColorScheme(.dark)
        }
    }
}

struct Turn: Identifiable, Sendable {
    enum Source: Sendable { case device, cloud, queued }
    let id = UUID()
    let question: String
    var answer: String
    var source: Source
    var seconds: Double
    var cost: Double
    var notes: String
    var why: String
}

struct TestResult: Identifiable, Sendable {
    let id = UUID()
    let pack: String
    let spoken: String
    let heard: String
    let answer: String
    let source: Turn.Source?
    let seconds: Double
    let passed: Bool
    let expect: String
}

@MainActor
final class AppModel: ObservableObject {
    let voice = Voice()
    @Published var status = "Starting"
    @Published var ready = false
    @Published var answering = false
    @Published var packs: [PackEntry] = []
    @Published var pack: PackData?
    @Published var turns: [Turn] = []
    @Published var networkUp = true
    @Published var simulateNoSignal = false
    @Published var speakCloud = true
    @Published var tests: [TestResult] = []
    @Published var testing = false
    private(set) var brain: Brain?
    private let monitor = NWPathMonitor()
    private var turnWaiter: CheckedContinuation<Turn?, Never>?
    private var waiterID = UUID()

    var online: Bool { networkUp && !simulateNoSignal }
    var queuedCount: Int { turns.filter { $0.source == .queued }.count }
    static let selfTestOnLaunch = ProcessInfo.processInfo.arguments.contains("-selftest")

    init() {
        voice.testMode = Self.selfTestOnLaunch
        voice.onQuestion = { [weak self] q in Task { await self?.ask(q) } }
        monitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.networkUp = up }
        }
        monitor.start(queue: .global(qos: .utility))
        Task { await boot() }
    }

    func boot() async {
        do {
            let brain = try Brain()
            self.brain = brain
            packs = brain.index
            try await brain.load { msg in Task { @MainActor in self.status = msg } }
            let saved = UserDefaults.standard.string(forKey: "pack")
            try await use(packs.first { $0.id == saved }?.id ?? packs.first!.id)
            await voice.start()
            if Self.selfTestOnLaunch { await selfTest(exitWhenDone: true) }
        } catch {
            status = "Failed to load: \(error.localizedDescription)"
            print("POCKETMUSE load error: \(error)")
        }
    }

    func use(_ id: String) async throws {
        guard let brain else { return }
        ready = false
        status = "Loading \(packs.first { $0.id == id }?.name ?? id)"
        pack = try await brain.use(id)
        voice.vocabulary = await brain.vocabulary()
        UserDefaults.standard.set(id, forKey: "pack")
        turns = []
        ready = true
        status = "Ready"
    }

    func switchPack(_ id: String) {
        guard id != pack?.id else { return }
        voice.cancel()
        Task {
            do { try await use(id) } catch { status = "Couldn't load pack: \(error.localizedDescription)" }
        }
    }

    /// On-device first. If the pack doesn't cover it: big Muse when online, queued when not.
    func ask(_ raw: String) async {
        guard let brain, ready, !answering else { voice.resume(); return }
        answering = true
        defer { answering = false }
        let question = Wake.strip(raw)
        let t0 = Date()
        var turn: Turn
        do {
            let a = try await brain.answer(question)
            let secs = Date().timeIntervalSince(t0)
            if !a.notInPack {
                turn = Turn(question: question, answer: a.text, source: .device, seconds: secs, cost: 0, notes: a.notes,
                            why: "Muse prepared this ahead of time. Llama 3.2 1B answered on this phone from the "
                                + "pack notes below, which the fact search picked for your question. No network used.")
            } else if online, Cloud.key != nil {
                let reply = try await Cloud.ask(question)
                turn = Turn(question: question, answer: reply.text, source: .cloud,
                            seconds: Date().timeIntervalSince(t0), cost: reply.cost, notes: a.notes,
                            why: "Your pack doesn't cover this: the on-device model said “not in your pack”. "
                                + "There's signal, so big Muse (Muse Spark Open) answered from the cloud.")
            } else {
                turn = Turn(question: question,
                            answer: "That's not in your pack, and there's no signal. I'll ask Muse when you're back online.",
                            source: .queued, seconds: secs, cost: 0, notes: a.notes,
                            why: "The closest pack notes (below) don't answer this, so the on-device model said "
                                + "“not in your pack” instead of guessing. With no signal, it's queued for big Muse.")
            }
        } catch {
            turn = Turn(question: question, answer: "Couldn't reach Muse: \(error.localizedDescription)",
                        source: .queued, seconds: 0, cost: 0, notes: "",
                        why: "The cloud request failed, so the question is queued.")
        }
        turns.insert(turn, at: 0)
        if turn.source == .cloud && !speakCloud { voice.resume() } else { voice.speak(turn.answer) }
        turnWaiter?.resume(returning: turn)
        turnWaiter = nil
    }

    /// Send queued questions to big Muse once there's signal.
    func sync() async {
        guard online, Cloud.key != nil else { return }
        for i in turns.indices where turns[i].source == .queued {
            let t0 = Date()
            if let reply = try? await Cloud.ask(turns[i].question) {
                turns[i].answer = reply.text
                turns[i].source = .cloud
                turns[i].seconds = Date().timeIntervalSince(t0)
                turns[i].cost = reply.cost
                turns[i].why = "Queued while offline, then answered by big Muse once back online."
            }
        }
    }

    // MARK: Self-test: a simulated user speaking to the glasses

    /// For every pack: plays each recorded question (macOS `say`) through the real capture path
    /// (hold to talk, released once the recording ends), with no signal, and checks the answer.
    func selfTest(exitWhenDone: Bool = false) async {
        guard !testing else { return }
        setvbuf(stdout, nil, _IOLBF, 0)  // line-buffer so `devicectl --console` sees each result as it lands
        testing = true
        tests = []
        let wasTest = voice.testMode
        voice.testMode = true
        voice.cancel()
        simulateNoSignal = true
        let startPack = pack?.id
        for entry in packs {
            let dir = Bundled.selftest(entry.id)
            guard let data = try? Data(contentsOf: dir.appending(component: "tests.json")),
                  let items = try? JSONDecoder().decode([[String: String]].self, from: data) else { continue }
            do { try await use(entry.id) } catch { continue }
            for (i, item) in items.enumerated() {
                let spoken = item["q"] ?? ""
                let expect = item["expect"] ?? ""
                let url = dir.appending(component: "\(i).wav")
                let t0 = Date()
                let turn = await speakAsUser(url)
                let r = TestResult(pack: entry.name, spoken: spoken, heard: voice.transcript,
                                   answer: turn?.answer ?? "(no answer: \(voice.notice ?? "timeout"))",
                                   source: turn?.source, seconds: turn?.seconds ?? Date().timeIntervalSince(t0),
                                   passed: Self.check(turn, expect: expect), expect: expect)
                tests.append(r)
                print("SELFTEST \(r.passed ? "PASS" : "FAIL") [\(entry.id)] said: \(spoken) | heard: \(r.heard) | "
                    + "\(String(describing: r.source)) \(String(format: "%.2f", r.seconds))s | \(r.answer)")
            }
        }
        let passed = tests.filter(\.passed).count
        print("SELFTEST DONE \(passed)/\(tests.count)")
        Self.saveReport(tests)
        simulateNoSignal = false
        voice.testMode = wasTest
        testing = false
        if let startPack { try? await use(startPack) }
        if exitWhenDone { exit(0) }
        voice.cancel()
    }

    private func speakAsUser(_ url: URL) async -> Turn? {
        let seconds = (try? AVAudioFile(forReading: url)).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 3
        let id = UUID()
        waiterID = id
        return await withCheckedContinuation { (c: CheckedContinuation<Turn?, Never>) in
            turnWaiter = c
            voice.onFileSpoken = { [weak self] in  // done talking: let go of the button shortly after
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    if self?.waiterID == id { self?.voice.holdEnded() }
                }
            }
            voice.holdBegan(source: .file(url))
            Task {  // give up on this question (only this one) if no answer comes
                try? await Task.sleep(for: .seconds(seconds * 2 + 15))
                if waiterID == id, let w = turnWaiter { turnWaiter = nil; w.resume(returning: nil) }
            }
        }
    }

    /// Documents/selftest.json, pulled by the verify skill with `devicectl device copy from`.
    static func saveReport(_ results: [TestResult]) {
        let rows: [[String: Any]] = results.map {
            ["pack": $0.pack, "spoken": $0.spoken, "heard": $0.heard, "answer": $0.answer,
             "source": $0.source.map { "\($0)" } ?? "none", "seconds": $0.seconds, "passed": $0.passed,
             "expect": $0.expect]
        }
        let report: [String: Any] = ["finished": ISO8601DateFormatter().string(from: Date()),
                                     "passed": results.filter(\.passed).count, "total": results.count, "results": rows]
        let url = URL.documentsDirectory.appending(component: "selftest.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]) {
            try? data.write(to: url)
        }
    }

    static func check(_ turn: Turn?, expect: String) -> Bool {
        guard let turn else { return false }
        if expect == "REFUSE" { return turn.source != .device }
        let a = turn.answer.lowercased()
        return turn.source == .device && expect.lowercased().split(separator: "|").contains { a.contains($0) }
    }
}
