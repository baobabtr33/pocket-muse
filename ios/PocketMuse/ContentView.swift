import AVFoundation
import SwiftUI

private let accent = Color(red: 0.45, green: 0.62, blue: 1.0)
private let warm = Color(red: 1.0, green: 0.72, blue: 0.42)

struct ContentView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var voice: Voice
    @State private var showHow = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.04), Color(red: 0.05, green: 0.06, blue: 0.12)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                header
                chips
                Orb(phase: app.ready ? voice.phase : .busy)
                    .frame(height: 170)
                    .padding(.top, 4)
                caption
                conversation
                controls
            }
            .padding(.horizontal, 16)
        }
        .sheet(isPresented: $showHow) { HowSheet().environmentObject(app) }
        .sheet(isPresented: $showSettings) { SettingsSheet().environmentObject(app).environmentObject(voice) }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pocket Muse").font(.system(size: 26, weight: .semibold, design: .rounded))
                Text(app.brain?.pack.title ?? "Muse thinks ahead for you")
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { showHow = true } label: { Image(systemName: "info.circle") }
            Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
        }
        .font(.title3)
        .tint(.white)
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
            Chip(icon: "cpu", text: "Llama 3.2 1B on-device", color: .purple)
            Spacer(minLength: 0)
        }
    }

    private var caption: some View {
        VStack(spacing: 6) {
            Text(phaseText).font(.headline)
            Text(voice.transcript.isEmpty ? " " : voice.transcript)
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(2).multilineTextAlignment(.center)
            if let err = voice.error { Text(err).font(.caption).foregroundStyle(.red) }
        }
        .frame(maxWidth: .infinity)
    }

    private var phaseText: String {
        guard app.ready else { return app.status }
        switch voice.phase {
        case .off: return "Microphone off"
        case .waiting: return voice.wakeEnabled ? "Say “Hey Meta…”" : "Hold to talk"
        case .hearing: return "Listening"
        case .busy: return "Thinking"
        case .speaking: return "Speaking"
        }
    }

    private var conversation: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if app.turns.isEmpty {
                    Text("Answers appear here. Everything in your pack is answered on this phone, with no signal.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .padding(.top, 20)
                }
                ForEach(app.turns) { TurnCard(turn: $0) }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(app.brain?.pack.scenes ?? []) { s in
                    Button(s.scene) {
                        app.simulateNoSignal = !s.online
                        voice.stopSpeaking()
                        Task { await app.ask(s.q) }
                    }
                }
                if app.queuedCount > 0 && app.online {
                    Button("Sync \(app.queuedCount) queued with Muse") { Task { await app.sync() } }
                }
            } label: {
                Image(systemName: "list.bullet").font(.title3)
                    .frame(width: 54, height: 54).background(Circle().fill(Color.white.opacity(0.08)))
            }
            .tint(.white)

            HoldButton(enabled: app.ready)

            Button { voice.stopSpeaking() } label: {
                Image(systemName: "stop.fill").font(.title3)
                    .frame(width: 54, height: 54).background(Circle().fill(Color.white.opacity(0.08)))
            }
            .tint(.white)
        }
        .padding(.bottom, 8)
    }
}

struct HoldButton: View {
    @EnvironmentObject var voice: Voice
    let enabled: Bool
    @State private var pressed = false

    var body: some View {
        Text(pressed ? "Listening…" : "Hold to talk")
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(Capsule().fill(pressed ? accent : Color.white.opacity(0.12)))
            .scaleEffect(pressed ? 0.97 : 1)
            .opacity(enabled ? 1 : 0.4)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard enabled, !pressed else { return }
                        pressed = true
                        voice.holdBegan()
                    }
                    .onEnded { _ in
                        guard pressed else { return }
                        pressed = false
                        voice.holdEnded()
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
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(turn.question).font(.subheadline.weight(.semibold))
            Text(turn.answer).font(.callout).foregroundStyle(.primary.opacity(0.85))
            HStack(spacing: 6) {
                Text(badge).font(.caption2.weight(.bold)).foregroundStyle(color)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(color.opacity(0.35), lineWidth: 1))
    }

    private var badge: String {
        switch turn.source {
        case .device: return "POCKET MUSE · ON-DEVICE"
        case .cloud: return "BIG MUSE · CLOUD"
        case .queued: return "QUEUED FOR MUSE"
        }
    }
    private var color: Color {
        switch turn.source {
        case .device: return .green
        case .cloud: return accent
        case .queued: return warm
        }
    }
    private var detail: String {
        switch turn.source {
        case .queued: return "asks Muse when back online"
        default: return String(format: "%.2fs · $%.4f", turn.seconds, turn.cost)
        }
    }
}

/// A soft breathing orb: idle blue while waiting, bright while hearing, warm while speaking.
struct Orb: View {
    let phase: Voice.Phase
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let speed: Double = phase == .waiting || phase == .off ? 0.8 : 3.0
            let amp: Double = phase == .waiting || phase == .off ? 0.04 : 0.12
            let s = 1 + amp * sin(t * speed)
            ZStack {
                Circle().fill(color.opacity(0.18)).scaleEffect(s * 1.25).blur(radius: 24)
                Circle().fill(
                    RadialGradient(colors: [color.opacity(0.95), color.opacity(0.35)],
                                   center: .init(x: 0.4, y: 0.35), startRadius: 4, endRadius: 80))
                    .frame(width: 120, height: 120)
                    .scaleEffect(s)
                if phase == .busy {
                    Circle().trim(from: 0, to: 0.28)
                        .stroke(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 146, height: 146)
                        .rotationEffect(.radians(t * 4))
                }
            }
        }
    }
    private var color: Color {
        switch phase {
        case .off: return .gray
        case .waiting: return accent
        case .hearing: return Color(red: 0.55, green: 0.85, blue: 1.0)
        case .busy: return .purple
        case .speaking: return warm
        }
    }
}

struct HowSheet: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        let b = app.brain?.pack.build ?? [:]
        let pack = app.brain?.pack
        NavigationStack {
            List {
                Section("Muse thought ahead") {
                    row("Teacher", "Muse Spark Open (cloud)")
                    row("Cards", "\(pack?.cards.filter { $0.kind == "safety" }.count ?? 0) safety first, then \(pack?.cards.filter { $0.kind != "safety" }.count ?? 0) for the day")
                    row("Practice Q&A", "\(Int(b["pairs"] ?? 0)) in \(Int(b["teach_seconds"] ?? 0))s")
                    row("Muse cost", String(format: "$%.2f", b["teach_cost_usd"] ?? 0))
                }
                Section("Llama learned it") {
                    row("Student", "Llama 3.2 1B Instruct")
                    row("Training", "\(Int(b["iters"] ?? 0)) LoRA steps, \(Int((b["train_seconds"] ?? 0) / 60)) min on a Mac")
                    row("Adapter", String(format: "%.0f MB, fused, %d-bit on phone", b["adapter_mb"] ?? 0, pack?.bits ?? 8))
                }
                Section("Answering now") {
                    row("Where", "This iPhone, no network needed")
                    row("Speech", "On-device recognition and voice")
                    row("Cost per answer", "$0")
                }
            }
            .navigationTitle("How it's built")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).multilineTextAlignment(.trailing) }
    }
}

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
                    Button("Preview") { voice.speak("Hi, I'm Muse. The emergency kit is inside Lifeguard Tower 2.") }
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
