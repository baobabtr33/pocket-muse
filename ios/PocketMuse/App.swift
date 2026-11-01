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

struct Turn: Identifiable {
    enum Source { case device, cloud, queued }
    let id = UUID()
    let question: String
    var answer: String
    var source: Source
    var seconds: Double
    var cost: Double
}

@MainActor
final class AppModel: ObservableObject {
    let voice = Voice()
    @Published var status = "Starting"
    @Published var ready = false
    @Published var turns: [Turn] = []
    @Published var networkUp = true
    @Published var simulateNoSignal = false
    @Published var speakCloud = true
    private(set) var brain: Brain?
    private let monitor = NWPathMonitor()

    var online: Bool { networkUp && !simulateNoSignal }
    var queuedCount: Int { turns.filter { $0.source == .queued }.count }

    init() {
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
            try await brain.load { msg in Task { @MainActor in self.status = msg } }
            ready = true
            await voice.start()
        } catch {
            status = "Failed to load: \(error.localizedDescription)"
        }
    }

    /// On-device first. If the pack doesn't cover it: big Muse when online, queued when not.
    func ask(_ raw: String) async {
        guard let brain, ready else { voice.resume(); return }
        let question = Wake.strip(raw)
        let t0 = Date()
        do {
            let text = try await brain.answer(question)
            let secs = Date().timeIntervalSince(t0)
            if !(await brain.isNotInPack(text)) {
                turns.insert(Turn(question: question, answer: text, source: .device, seconds: secs, cost: 0), at: 0)
                voice.speak(text)
                return
            }
            if online, Cloud.key != nil {
                let reply = try await Cloud.ask(question)
                turns.insert(Turn(question: question, answer: reply.text, source: .cloud,
                                  seconds: Date().timeIntervalSince(t0), cost: reply.cost), at: 0)
                if speakCloud { voice.speak(reply.text) } else { voice.resume() }
            } else {
                let msg = "That's not in your pack, and there's no signal. I'll ask Muse when you're back online."
                turns.insert(Turn(question: question, answer: msg, source: .queued, seconds: secs, cost: 0), at: 0)
                voice.speak(msg)
            }
        } catch {
            turns.insert(Turn(question: question, answer: "Couldn't reach Muse: \(error.localizedDescription)",
                              source: .queued, seconds: 0, cost: 0), at: 0)
            voice.resume()
        }
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
            }
        }
    }
}
