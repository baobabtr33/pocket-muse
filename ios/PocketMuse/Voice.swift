import AVFoundation
import Speech

/// Glasses audio: listens through the Ray-Ban Meta microphone (Bluetooth HFP), waits for
/// "Hey Meta" / "Hey Muse" (or hold-to-talk), captures the question, and speaks the answer back.
/// Speech recognition runs on-device, so it works with no signal.
///
/// The self-test feeds recorded questions through exactly the same path instead of the microphone.
/// When the speaker last made a sound. Fed from the audio thread, read on the main actor.
/// End of speech is judged from the audio itself: the recognizer's partial results arrive in bursts with
/// gaps over a second mid-sentence, so "no new words for 1.3 s" cut questions off.
final class VoiceActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var lastVoice = Date.distantPast
    private var heardVoice = false
    static let threshold: Float = 0.012

    func reset() { lock.withLock { lastVoice = Date(); heardVoice = false } }

    func observe(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var sum: Float = 0
        for i in 0 ..< Int(buffer.frameLength) { sum += data[i] * data[i] }
        if (sum / Float(buffer.frameLength)).squareRoot() > Self.threshold {
            lock.withLock { lastVoice = Date(); heardVoice = true }
        }
    }

    /// Seconds of quiet since the last voiced audio (0 until someone has spoken).
    var quietFor: TimeInterval { lock.withLock { heardVoice ? Date().timeIntervalSince(lastVoice) : 0 } }
}

@MainActor
final class Voice: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    enum Phase: Equatable { case off, waiting, hearing, busy, speaking }
    enum Source { case mic, file(URL) }

    @Published var phase: Phase = .off
    @Published var transcript = ""
    @Published var route = "—"
    @Published var onGlasses = false
    @Published var notice: String?
    @Published var voiceID: String = UserDefaults.standard.string(forKey: "voiceID") ?? ""
    @Published var wakeEnabled = true
    /// Self-test: don't speak aloud and don't reopen the mic after an answer.
    var testMode = false

    var onQuestion: ((String) -> Void)?
    /// Self-test: called when a recorded question has been fully played in (the "user" stops talking).
    var onFileSpoken: (() -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var feeder: Task<Void, Never>?
    private let synth = AVSpeechSynthesizer()
    private var wakeEnd: String.Index?
    private var timer: Task<Void, Never>?
    private var holding = false
    private var gotFinal = false
    private var generation = 0
    private let activity = VoiceActivity()
    private var endpointer: Task<Void, Never>?

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
            notice = "Allow microphone and speech recognition in Settings."
            return
        }
        configureSession()
        if !testMode { listen() }
    }

    private func configureSession() {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker])
            try s.setActive(true)
            preferGlasses()
        } catch {
            notice = "Audio session: \(error.localizedDescription)"
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
        if phase == .waiting && !testMode { listen() }  // input format changed; restart the tap
    }

    // MARK: Capture

    /// Start (or restart) recognition. From the mic it waits for the wake word; while holding, it
    /// takes everything said.
    func listen(source: Source = .mic) {
        stopRecognition()
        guard let recognizer, recognizer.isAvailable else { notice = "Speech recognizer unavailable."; return }
        generation += 1
        let gen = generation
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        req.addsPunctuation = true
        req.contextualStrings = ["Hey Meta", "Hey Muse", "emergency kit", "lifeguard", "kayak", "coyote"]
        request = req
        wakeEnd = nil
        gotFinal = false
        transcript = ""
        activity.reset()
        let activity = activity

        switch source {
        case .mic:
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { notice = "No microphone input."; return }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                req.append(buffer)
                activity.observe(buffer)
            }
            engine.prepare()
            do { try engine.start() } catch { notice = "Mic: \(error.localizedDescription)"; return }
        case .file(let url):
            feeder = Task { [weak self] in
                await Self.feed(url, into: req, activity: activity) { self?.onFileSpoken?() }
            }
        }

        phase = holding ? .hearing : .waiting
        task = recognizer.recognitionTask(with: req) { [weak self] result, err in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                if let text { self.heard(text) }
                if final || err != nil { self.gotFinal = true }
                // Recognition ends after about a minute or a long silence; reopen it while idle.
                if err != nil, self.phase == .waiting, !self.testMode {
                    try? await Task.sleep(for: .milliseconds(300))
                    if gen == self.generation, self.phase == .waiting { self.listen() }
                }
            }
        }
        endpointer = Task { [weak self] in  // wake-word path: end the question on real silence
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, gen == self.generation, !self.holding, self.phase == .hearing else { continue }
                let quiet = activity.quietFor
                if self.question(from: self.transcript).count > 2 {
                    if quiet > 1.0 { self.endCapture(); return }
                } else if quiet > 5 {
                    self.reset(); return
                }
            }
        }
        if case .mic = source, !holding {
            timer = Task { [weak self] in  // keep each task short, well under Apple's per-task limit
                try? await Task.sleep(for: .seconds(50))
                guard let self, !Task.isCancelled, gen == self.generation, self.phase == .waiting else { return }
                self.listen()
            }
        }
    }

    /// Recorded audio at real-time pace, then a little silence, like someone speaking and pausing.
    nonisolated private static func feed(
        _ url: URL, into req: SFSpeechAudioBufferRecognitionRequest, activity: VoiceActivity,
        spoken: @escaping @MainActor () -> Void
    ) async {
        guard let file = try? AVAudioFile(forReading: url) else { return }
        let format = file.processingFormat
        let chunk = AVAudioFrameCount(format.sampleRate / 10)
        while !Task.isCancelled, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) {
            guard (try? file.read(into: buf, frameCount: chunk)) != nil, buf.frameLength > 0 else { break }
            req.append(buf)
            activity.observe(buf)
            try? await Task.sleep(for: .milliseconds(100))
        }
        await spoken()
        for _ in 0 ..< 25 where !Task.isCancelled {
            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
            silence.frameLength = chunk
            req.append(silence)
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func heard(_ text: String) {
        transcript = text
        guard !holding, phase == .waiting || phase == .hearing else { return }
        if wakeEnd == nil, wakeEnabled, let end = Wake.end(in: text) {
            wakeEnd = end
            phase = .hearing  // the endpointer now waits for a real pause after the question
        }
    }

    private func question(from text: String) -> String {
        if let end = wakeEnd, end <= text.endIndex {
            return String(text[end...]).trimmingCharacters(in: .whitespaces)
        }
        return Wake.strip(text).trimmingCharacters(in: .whitespaces)
    }

    /// Stop taking audio, wait briefly for the recognizer's final words, then send the question.
    private func endCapture() {
        phase = .busy
        stopAudio()
        request?.endAudio()
        let gen = generation
        Task {
            for _ in 0 ..< 60 where !gotFinal { try? await Task.sleep(for: .milliseconds(50)) }
            guard gen == generation else { return }
            submit()
        }
    }

    private func submit() {
        let q = question(from: transcript)
        task?.cancel()
        task = nil
        request = nil
        guard q.count > 2 else {
            notice = "Didn't catch that. Try again."
            reset()
            return
        }
        notice = nil
        phase = .busy
        onQuestion?(q)
    }

    // MARK: Hold to talk

    func holdBegan(source: Source = .mic) {
        synth.stopSpeaking(at: .immediate)
        holding = true
        notice = nil
        listen(source: source)
    }

    func holdEnded() {
        guard holding else { return }
        holding = false
        endCapture()
    }

    /// Stop everything (speech, capture) and go back to waiting.
    func cancel() {
        holding = false
        synth.stopSpeaking(at: .immediate)
        reset()
    }

    private func reset() {
        stopRecognition()
        if testMode { phase = .off } else { listen() }
    }

    private func stopAudio() {
        endpointer?.cancel()
        feeder?.cancel()
        feeder = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    private func stopRecognition() {
        timer?.cancel()
        stopAudio()
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
    }

    // MARK: Speaking

    static var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }

    /// Muse's voice: the best installed English voice (premium > enhanced).
    /// Download better voices in Settings > Accessibility > Read & Speak > Voices.
    var voice: AVSpeechSynthesisVoice? {
        if !voiceID.isEmpty, let v = AVSpeechSynthesisVoice(identifier: voiceID) { return v }
        let us = Self.voices.filter { $0.language == "en-US" }
        let preferred = ["Ava", "Zoe", "Evan", "Samantha"]
        for quality in [AVSpeechSynthesisVoiceQuality.premium, .enhanced] {
            for name in preferred {
                if let v = us.first(where: { $0.name.hasPrefix(name) && $0.quality == quality }) { return v }
            }
            if let v = us.first(where: { $0.quality == quality }) { return v }
        }
        return us.first ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    func setVoice(_ id: String) {
        voiceID = id
        UserDefaults.standard.set(id, forKey: "voiceID")
    }

    func speak(_ text: String) {
        stopRecognition()
        if testMode { phase = .off; return }
        phase = .speaking
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        u.pitchMultiplier = 1.0
        u.preUtteranceDelay = 0.1
        synth.speak(u)
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in if self.phase == .speaking { self.listen() } }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in if self.phase == .speaking { self.listen() } }
    }

    /// After an answer that isn't spoken: go back to waiting.
    func resume() {
        if phase == .busy { reset() }
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
