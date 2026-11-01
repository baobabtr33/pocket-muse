import AVFoundation
import SwiftUI

private let accent = Color(red: 0.45, green: 0.62, blue: 1.0)
private let warm = Color(red: 1.0, green: 0.72, blue: 0.42)
private let bg = LinearGradient(colors: [Color(white: 0.04), Color(red: 0.05, green: 0.06, blue: 0.12)],
                                startPoint: .top, endPoint: .bottom)

struct ContentView: View {
    var body: some View {
        TabView {
            MuseView().tabItem { Label("Muse", systemImage: "eyeglasses") }
            PackView().tabItem { Label("Pack", systemImage: "shippingbox") }
            HowView().tabItem { Label("How", systemImage: "sparkles") }
        }
        .tint(accent)
    }
}

// MARK: - Muse (talk)

struct MuseView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var voice: Voice
    @State private var showSettings = false

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()
            VStack(spacing: 14) {
                header
                chips
                Orb(phase: app.ready ? (app.answering ? .busy : voice.phase) : .busy)
                    .frame(height: 160)
                caption
                conversation
                controls
            }
            .padding(.horizontal, 16)
        }
        .sheet(isPresented: $showSettings) { SettingsSheet().environmentObject(app).environmentObject(voice) }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pocket Muse").font(.system(size: 26, weight: .semibold, design: .rounded))
                PackPicker()
            }
            Spacer()
            Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3").font(.title3) }
                .tint(.white)
        }
        .padding(.top, 8)
    }

    private var chips: some View {
        HStack(spacing: 8) {
            Chip(icon: voice.onGlasses ? "eyeglasses" : "iphone",
                 text: voice.onGlasses ? "Glasses" : "Phone mic",
                 color: voice.onGlasses ? .green : .gray)
            Button { app.simulateNoSignal.toggle() } label: {
                Chip(icon: app.online ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash",
                     text: app.online ? "Online" : "No signal",
                     color: app.online ? accent : warm)
            }
            Chip(icon: "cpu", text: "On-device", color: .purple)
            Spacer(minLength: 0)
        }
    }

    private var caption: some View {
        VStack(spacing: 6) {
            Text(phaseText).font(.headline)
            Text(voice.transcript.isEmpty ? " " : "“\(voice.transcript)”")
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(2).multilineTextAlignment(.center)
            if let n = voice.notice { Text(n).font(.caption).foregroundStyle(warm) }
        }
        .frame(maxWidth: .infinity)
    }

    private var phaseText: String {
        guard app.ready else { return app.status }
        if app.testing { return "Self-test running…" }
        if app.answering { return "Thinking" }
        switch voice.phase {
        case .off: return "Microphone off"
        case .waiting: return voice.wakeEnabled ? "Say “Hey Meta…” or hold to talk" : "Hold to talk"
        case .hearing: return "Listening"
        case .busy: return "Thinking"
        case .speaking: return "Speaking"
        }
    }

    private var conversation: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if app.turns.isEmpty {
                    Text("Ask about your day. Anything in your pack is answered on this phone, even with no signal. "
                        + "Tap a card's “Why this answer” to see what it used.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .padding(.top, 16)
                }
                ForEach(app.turns) { TurnCard(turn: $0) }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Menu {
                Section("Try a scene") {
                    ForEach(app.pack?.scenes ?? []) { s in
                        Button(s.scene) {
                            app.simulateNoSignal = !s.online
                            voice.cancel()
                            Task { await app.ask(s.q) }
                        }
                    }
                }
                if app.queuedCount > 0 && app.online {
                    Button("Ask Muse the \(app.queuedCount) queued") { Task { await app.sync() } }
                }
            } label: {
                CircleIcon(name: "text.bubble")
            }
            .tint(.white)

            HoldButton(enabled: app.ready && !app.answering && !app.testing)

            Button { voice.cancel() } label: { CircleIcon(name: "stop.fill") }
                .tint(.white)
                .accessibilityLabel("Stop")
        }
        .padding(.bottom, 8)
    }
}

struct PackPicker: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        Menu {
            ForEach(app.packs) { p in
                Button { app.switchPack(p.id) } label: {
                    if p.id == app.pack?.id { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(app.pack.map { "\($0.name) · \($0.title)" } ?? "Loading…").lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct CircleIcon: View {
    let name: String
    var body: some View {
        Image(systemName: name).font(.title3)
            .frame(width: 54, height: 54).background(Circle().fill(Color.white.opacity(0.08)))
    }
}

struct HoldButton: View {
    @EnvironmentObject var voice: Voice
    let enabled: Bool
    @State private var pressed = false

    var body: some View {
        Text(pressed ? "Listening… release to ask" : "Hold to talk")
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(Capsule().fill(pressed ? accent : Color.white.opacity(0.12)))
            .scaleEffect(pressed ? 0.97 : 1)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard enabled, !pressed else { return }
                        pressed = true
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        voice.holdBegan()
                    }
                    .onEnded { _ in
                        guard pressed else { return }
                        pressed = false
                        voice.holdEnded()  // the answer starts automatically
                    }
            )
            .animation(.easeOut(duration: 0.12), value: pressed)
    }
}

struct Chip: View {
    let icon: String
    let text: String
    let color: Color
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(color.opacity(0.18)))
        .foregroundStyle(color)
    }
}

struct TurnCard: View {
    let turn: Turn
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(turn.question).font(.subheadline.weight(.semibold))
            Text(turn.answer).font(.callout).foregroundStyle(.primary.opacity(0.88))
            HStack(spacing: 6) {
                Text(sourceBadge(turn.source)).font(.caption2.weight(.bold)).foregroundStyle(sourceColor(turn.source))
                Text(detail).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button(open ? "Hide" : "Why this answer") { withAnimation { open.toggle() } }
                    .font(.caption2.weight(.semibold)).tint(accent)
            }
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    Text(turn.why).font(.caption)
                    if !turn.notes.isEmpty {
                        Text("Pack notes it was given").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                        Text(turn.notes).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(sourceColor(turn.source).opacity(0.35), lineWidth: 1))
    }

    private var detail: String {
        turn.source == .queued ? "asks Muse when online" : String(format: "%.2fs · $%.4f", turn.seconds, turn.cost)
    }
}

func sourceBadge(_ s: Turn.Source?) -> String {
    switch s {
    case .device: return "ON-DEVICE"
    case .cloud: return "BIG MUSE · CLOUD"
    case .queued: return "QUEUED"
    case nil: return "NO ANSWER"
    }
}

func sourceColor(_ s: Turn.Source?) -> Color {
    switch s {
    case .device: return .green
    case .cloud: return accent
    case .queued: return warm
    case nil: return .red
    }
}

/// A soft breathing orb: blue while waiting, bright while hearing, purple thinking, warm speaking.
struct Orb: View {
    let phase: Voice.Phase
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let calm = phase == .waiting || phase == .off
            let s = 1 + (calm ? 0.04 : 0.12) * sin(t * (calm ? 0.8 : 3.0))
            ZStack {
                Circle().fill(tint.opacity(0.18)).scaleEffect(s * 1.25).blur(radius: 24)
                Circle().fill(RadialGradient(colors: [tint.opacity(0.95), tint.opacity(0.35)],
                                             center: .init(x: 0.4, y: 0.35), startRadius: 4, endRadius: 80))
                    .frame(width: 116, height: 116)
                    .scaleEffect(s)
                if phase == .busy {
                    Circle().trim(from: 0, to: 0.28)
                        .stroke(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 142, height: 142)
                        .rotationEffect(.radians(t * 4))
                }
            }
        }
    }
    private var tint: Color {
        switch phase {
        case .off: return .gray
        case .waiting: return accent
        case .hearing: return Color(red: 0.55, green: 0.85, blue: 1.0)
        case .busy: return .purple
        case .speaking: return warm
        }
    }
}

// MARK: - Pack (what Muse prepared, and why)

struct PackView: View {
    @EnvironmentObject var app: AppModel
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                if let p = app.pack {
                    Section {
                        Text("“\(p.plan)”").font(.callout.italic())
                        if !p.reasoning.isEmpty {
                            Text(p.reasoning).font(.callout)
                        }
                    } header: {
                        Text("Your plan, and Muse's thinking")
                    } footer: {
                        Text("Muse reads your plan ahead of time and predicts what you'll ask. Safety comes first, "
                            + "then each part of the day.")
                    }
                    Section("\(p.cards.count) cards Muse wrote") {
                        ForEach(Array(p.cards.enumerated()), id: \.offset) { i, c in
                            NavigationLink {
                                CardDetail(card: c, learned: p.learned.filter { $0.card == i })
                            } label: {
                                CardRow(card: c, count: p.learned.filter { $0.card == i }.count)
                            }
                        }
                    }
                    Section {
                        ForEach(filtered(p)) { l in LearnedRow(item: l, card: l.card.map { p.cards[$0].title }) }
                    } header: {
                        Text("\(p.learned.count) questions Llama learned")
                    } footer: {
                        Text("Muse wrote these practice questions and answers. Llama 3.2 1B trained on them, "
                            + "including questions it should refuse (“not in your pack”), so it doesn't guess.")
                    }
                }
            }
            .searchable(text: $search, prompt: "Search learned questions")
            .navigationTitle(app.pack?.name ?? "Pack")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { PackPicker() } }
        }
    }

    private func filtered(_ p: PackData) -> [PackData.Learned] {
        let items = search.isEmpty ? Array(p.learned.prefix(60)) : p.learned.filter {
            $0.q.localizedCaseInsensitiveContains(search) || $0.a.localizedCaseInsensitiveContains(search)
        }
        return items
    }
}

struct CardRow: View {
    let card: PackData.Card
    let count: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(kindLabel(card.kind)).font(.caption2.weight(.bold)).foregroundStyle(kindColor(card.kind))
                Spacer()
                Text("\(count) Q&A").font(.caption2).foregroundStyle(.secondary)
            }
            Text(card.title).font(.subheadline.weight(.semibold))
            if !card.why.isEmpty { Text(card.why).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 2)
    }
}

struct CardDetail: View {
    let card: PackData.Card
    let learned: [PackData.Learned]
    var body: some View {
        List {
            if !card.why.isEmpty {
                Section("Why Muse wrote it") { Text(card.why) }
            }
            Section("Facts") { ForEach(card.facts, id: \.self) { Text($0).font(.callout) } }
            Section("What Llama learned from it (\(learned.count))") {
                ForEach(learned) { LearnedRow(item: $0, card: nil) }
            }
        }
        .navigationTitle(card.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LearnedRow: View {
    let item: PackData.Learned
    let card: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.q).font(.callout.weight(.semibold))
            Text(item.a).font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if item.kind == "gap" {
                    Text("LEARNS TO REFUSE").font(.caption2.weight(.bold)).foregroundStyle(warm)
                } else if item.kind == "smalltalk" {
                    Text("SMALL TALK").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                }
                if let card { Text(card).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
            }
        }
        .padding(.vertical, 2)
    }
}

func kindLabel(_ k: String) -> String {
    switch k {
    case "safety": return "SAFETY FIRST"
    case "forecast": return "FORECAST"
    default: return "YOUR DAY"
    }
}

func kindColor(_ k: String) -> Color {
    switch k {
    case "safety": return .red
    case "forecast": return accent
    default: return .green
    }
}

// MARK: - How (build record, pipeline, self-test)

struct HowView: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        let b = app.pack?.build ?? [:]
        let p = app.pack
        NavigationStack {
            List {
                Section {
                    Step(n: 1, title: "Muse thinks ahead",
                         text: "Muse Spark Open, Meta's large model, read your plan and wrote "
                            + "\(p?.cards.filter { $0.kind == "safety" }.count ?? 0) safety cards first, then "
                            + "\(p?.cards.filter { $0.kind != "safety" }.count ?? 0) for the rest of the day.")
                    Step(n: 2, title: "Muse teaches",
                         text: "It wrote \(Int(b["pairs"] ?? 0)) practice questions and answers in "
                            + "\(Int(b["teach_seconds"] ?? 0))s for about \(String(format: "$%.2f", b["teach_cost_usd"] ?? 0)), "
                            + "including ones Llama should refuse.")
                    Step(n: 3, title: "Llama learns",
                         text: "Llama 3.2 1B trained on them for \(Int(b["iters"] ?? 0)) steps "
                            + "(\(Int((b["train_seconds"] ?? 0) / 60)) min on a Mac). What it learned is a "
                            + "\(String(format: "%.0f", b["adapter_mb"] ?? 0)) MB add-on (LoRA adapter) for this day.")
                    Step(n: 4, title: "Answers on this phone",
                         text: "Your voice becomes text on the phone. A fact search picks the 4 most relevant pack "
                            + "notes, and Llama answers from them in about a second, for $0, with no signal. "
                            + "If the pack doesn't cover it, big Muse answers when online, or it's queued.")
                } header: {
                    Text("How \(p?.name ?? "this pack") was made")
                }
                Section {
                    Button(app.testing ? "Running…" : "Run self-test (simulated user, no signal)") {
                        Task { await app.selfTest() }
                    }
                    .disabled(app.testing || !app.ready)
                    if !app.tests.isEmpty {
                        let passed = app.tests.filter(\.passed).count
                        Text("\(passed)/\(app.tests.count) passed").font(.headline)
                        ForEach(app.tests) { TestRow(r: $0) }
                    }
                } header: {
                    Text("Self-test")
                } footer: {
                    Text("Plays recorded questions through the same speech recognition, wake word and hold-to-talk "
                        + "path as your voice, for every pack, and checks each answer.")
                }
            }
            .navigationTitle("How it works")
        }
    }
}

struct Step: View {
    let n: Int
    let title: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.headline).frame(width: 28, height: 28).background(Circle().fill(accent.opacity(0.25)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct TestRow: View {
    let r: TestResult
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: r.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(r.passed ? .green : .red)
                Text(r.pack).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(sourceBadge(r.source)) · \(String(format: "%.2fs", r.seconds))")
                    .font(.caption2).foregroundStyle(sourceColor(r.source))
            }
            Text("Said: \(r.spoken)").font(.caption)
            Text("Heard: \(r.heard)").font(.caption).foregroundStyle(.secondary)
            Text(r.answer).font(.caption)
        }
    }
}

// MARK: - Settings

struct SettingsSheet: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var voice: Voice
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Wake word (“Hey Meta” / “Hey Muse”)", isOn: $voice.wakeEnabled)
                    Toggle("Simulate no signal", isOn: $app.simulateNoSignal)
                    Toggle("Speak big Muse answers", isOn: $app.speakCloud)
                } footer: {
                    Text("Turn off “Hey Meta” in the Meta AI app so the glasses don't answer too. Audio: \(voice.route)")
                }
                Section("Muse voice") {
                    Picker("Voice", selection: Binding(get: { voice.voice?.identifier ?? "" },
                                                       set: { voice.setVoice($0) })) {
                        ForEach(Voice.voices, id: \.identifier) { v in
                            Text("\(v.name) · \(quality(v))").tag(v.identifier)
                        }
                    }
                    Button("Preview") { voice.speak("Hi, I'm Muse. I thought ahead about your day.") }
                }
                Section {
                    Text(Cloud.key == nil ? "No Baseten key: off-pack questions are queued." : "Baseten key set.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    private func quality(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Default"
        }
    }
}
