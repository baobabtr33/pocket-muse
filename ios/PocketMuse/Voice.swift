import AVFoundation
import Speech

/// Glasses audio: listens through the Ray-Ban Meta microphone (Bluetooth HFP), waits for
/// "Hey Meta" / "Hey Muse", captures the question, and speaks the answer back through the glasses.
/// Speech recognition runs on-device, so it works with no signal.
@MainActor
final class Voice: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    enum Phase: Equatable { case off, waiting, hearing, busy, speaking }

    @Published var phase: Phase = .off
    @Published var transcript = ""
    @Published var route = "—"
    @Published var onGlasses = false
    @Published var error: String?
    @Published var voiceID: String = UserDefaults.standard.string(forKey: "voiceID") ?? ""
    @Published var wakeEnabled = true

    var onQuestion: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let synth = AVSpeechSynthesizer()
    private var wakeEnd: String.Index?
    private var silence: Task<Void, Never>?
    private var recycle: Task<Void, Never>?
    private var holding = false
    private var generation = 0

    override init() {
        super.init()
        synth.delegate = self
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.routeChanged() } }
    }

    // MARK: Setup

    func start() async {
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        guard speech == .authorized, mic else {
            error = "Allow microphone and speech recognition in Settings."
            return
        }
        if recognizer?.supportsOnDeviceRecognition != true {
            error = "On-device speech isn't available for English on this phone."
        }
        configureSession()
        listen()
    }

    private func configureSession() {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord, mode: .default,
                              options: [.allowBluetoothHFP, .defaultToSpeaker])
            try s.setActive(true)
            preferGlasses()
        } catch {
            self.error = "Audio session: \(error.localizedDescription)"
        }
        updateRoute()
    }

    /// Route the mic (and with it, playback) to the Bluetooth glasses when they're connected.
    private func preferGlasses() {
        let s = AVAudioSession.sharedInstance()
        if let bt = s.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
            try? s.setPreferredInput(bt)
        }
    }

    private func updateRoute() {
        let r = AVAudioSession.sharedInstance().currentRoute
        let input = r.inputs.first
        onGlasses = input?.portType == .bluetoothHFP
        route = [input?.portName, r.outputs.first?.portName].compactMap { $0 }.uniqued().joined(separator: " → ")
    }

    private func routeChanged() {
        preferGlasses()
        updateRoute()
        if phase == .waiting || phase == .hearing { listen() }  // the input format changed; restart the tap
    }

    // MARK: Listening

    /// Start (or restart) continuous recognition, waiting for the wake phrase.
    func listen() {
        stopRecognition()
        guard let recognizer, recognizer.isAvailable else { error = "Speech recognizer unavailable."; return }
        generation += 1
        let gen = generation
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        req.addsPunctuation = true
        req.taskHint = .search
        req.contextualStrings = ["Hey Meta", "Hey Muse", "emergency kit", "lifeguard tower", "lunch"]
        request = req

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { error = "No microphone input."; return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in req.append(buffer) }
        engine.prepare()
        do { try engine.start() } catch { self.error = "Mic: \(error.localizedDescription)"; return }

        wakeEnd = nil
        transcript = ""
        phase = holding ? .hearing : .waiting
        task = recognizer.recognitionTask(with: req) { [weak self] result, err in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                if let result { self.heard(result.bestTranscription.formattedString) }
                if err != nil, self.phase == .waiting || self.phase == .hearing {
                    // Recognition times out after about a minute of audio, or on long silence; just restart.
                    try? await Task.sleep(for: .milliseconds(300))
                    if gen == self.generation { self.listen() }
                }
            }
        }
        // Keep each recognition task short so it never hits Apple's per-task limit mid-question.
        recycle?.cancel()
        recycle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard let self, !Task.isCancelled, gen == self.generation, self.phase == .waiting else { return }
            self.listen()
        }
    }

    private func heard(_ text: String) {
        transcript = text
        if holding {
            return
        }
        if wakeEnd == nil {
            guard wakeEnabled, let end = Wake.find(in: text) else { return }
            wakeEnd = end
            phase = .hearing
        }
        // Question = everything after the wake phrase. Finish after a short pause.
        silence?.cancel()
        let gen = generation
        silence = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1300))
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            self.finish()
        }
    }

    private func finish() {
        let text = transcript
        let question: String
        if holding || wakeEnd == nil {
            question = Wake.strip(text)
        } else {
            let idx = wakeEnd!
            question = idx <= text.endIndex ? String(text[idx...]).trimmingCharacters(in: .whitespaces) : ""
        }
        guard question.count > 2 else {
            // Wake word with no question yet: keep waiting a little longer.
            if !holding, wakeEnd != nil, phase == .hearing {
                let gen = generation
                silence = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    guard let self, !Task.isCancelled, gen == self.generation, self.phase == .hearing else { return }
                    self.listen()
                }
                return
            }
            listen()
            return
        }
        stopRecognition()
        phase = .busy
        onQuestion?(question)
    }

    /// Push-to-talk on the phone screen, for when the wake word isn't practical.
    func holdBegan() {
        holding = true
        synth.stopSpeaking(at: .immediate)
        listen()
        phase = .hearing
    }

    func holdEnded() {
        guard holding else { return }
        holding = false
        Task {
            try? await Task.sleep(for: .milliseconds(500))  // let the last words come in
            finish()
        }
    }

    private func stopRecognition() {
        silence?.cancel()
        recycle?.cancel()
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    // MARK: Speaking

    static var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }

    /// Muse's voice: the best installed English voice (premium > enhanced), warm and unhurried.
    /// Download better voices in Settings > Accessibility > Spoken Content > Voices.
    var voice: AVSpeechSynthesisVoice? {
        if !voiceID.isEmpty, let v = AVSpeechSynthesisVoice(identifier: voiceID) { return v }
        let us = Self.voices.filter { $0.language == "en-US" }
        let preferred = ["Ava", "Zoe", "Evan", "Samantha"]
        for name in preferred {
            if let v = us.first(where: { $0.name.hasPrefix(name) && $0.quality != .default }) { return v }
        }
        return us.first ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    func setVoice(_ id: String) {
        voiceID = id
        UserDefaults.standard.set(id, forKey: "voiceID")
    }

    func speak(_ text: String) {
        stopRecognition()
        phase = .speaking
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.04
        u.pitchMultiplier = 1.02
        u.preUtteranceDelay = 0.15
        u.postUtteranceDelay = 0.1
        synth.speak(u)
    }

    func stopSpeaking() {
        synth.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.listen() }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in if !self.holding { self.listen() } }
    }

    func resume() {
        if phase == .busy { listen() }
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
