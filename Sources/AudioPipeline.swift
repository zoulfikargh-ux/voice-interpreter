import Foundation
import AVFoundation
import Speech

extension AVAudioPCMBuffer {
    func copyBuffer() -> AVAudioPCMBuffer? {
        guard let c = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return nil }
        c.frameLength = frameLength
        let n = Int(frameLength)
        if let src = floatChannelData, let dst = c.floatChannelData {
            for ch in 0..<Int(format.channelCount) {
                memcpy(dst[ch], src[ch], n * MemoryLayout<Float>.size)
            }
        }
        return c
    }
}

/// Listens to the microphone, cuts speech into utterances, runs on-device recognition
/// for one or two languages at the same time and reports the best match.
final class AudioPipeline: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let q = DispatchQueue(label: "audio.pipeline")

    var onHeard: (@Sendable (Heard) -> Void)?
    var onLive: (@Sendable (String) -> Void)?
    /// Called while the speaker is still talking: (utterance id, best language, text so far).
    var onPartial: (@Sendable (Int, Lang, String) -> Void)?
    var onStatus: (@Sendable (String) -> Void)?

    // state confined to q
    private var recognizers: [Lang: SFSpeechRecognizer] = [:]
    private var tasks: [Lang: SFSpeechRecognitionTask] = [:]
    private var requests: [Lang: SFSpeechAudioBufferRecognitionRequest] = [:]
    private var results: [Lang: (text: String, conf: Float)] = [:]
    private var doneLangs = Set<Lang>()
    private var langs: [Lang] = []
    private var gated = false
    private var gateGen = 0
    private var inSpeech = false
    private var finishing = false
    private var uid = 0
    private var preRoll: [AVAudioPCMBuffer] = []
    private var samples: [Float] = []
    private var sampleRate: Double = 48000
    private var noise: Float = 0.004
    private var lastLoud = Date()
    private var startedAt = Date()
    private var loudCount = 0
    private var contextual: [String] = []
    private var bias: [Lang: Float] = [:]

    // MARK: control

    func start() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try s.setActive(true)

        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        q.async { self.sampleRate = fmt.sampleRate }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] buf, _ in
            guard let self = self, let copy = buf.copyBuffer() else { return }
            self.q.async { self.process(copy) }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        q.async { self.abortUtterance() }
    }

    func setLangs(_ l: [Lang]) {
        q.async {
            self.abortUtterance()
            self.langs = l
            for lang in l where self.recognizers[lang] == nil {
                self.recognizers[lang] = SFSpeechRecognizer(locale: lang.speechLocale)
            }
            for lang in l {
                if let r = self.recognizers[lang], !r.supportsOnDeviceRecognition {
                    self.onStatus?("حمّل لغة الإملاء (\(lang.name)) عشان تشتغل بدون نت: الإعدادات > عام > لوحة المفاتيح > الإملاء")
                }
            }
        }
    }

    /// Pitch of what has been heard so far in the current utterance (used to pick a male or female voice early).
    func pitchSoFar() async -> Float? {
        await withCheckedContinuation { (c: CheckedContinuation<Float?, Never>) in
            q.async {
                let smp = self.samples
                let sr = self.sampleRate
                DispatchQueue.global(qos: .userInitiated).async {
                    c.resume(returning: smp.count > 4000 ? Pitch.median(smp, sampleRate: sr) : nil)
                }
            }
        }
    }

    /// Words the recognizer should expect (names, product terms, numbers).
    func setContext(_ words: [String]) {
        q.async { self.contextual = Array(words.prefix(100)) }
    }

    /// Small score bonus per language, used to favour the home language.
    func setBias(_ b: [Lang: Float]) {
        q.async { self.bias = b }
    }

    /// Ignore the microphone while the phone is speaking, so it does not hear itself.
    func setGate(_ closed: Bool, after: Double = 0) {
        q.async {
            self.gateGen += 1
            let gen = self.gateGen
            if after <= 0 {
                self.applyGate(closed)
            } else {
                self.q.asyncAfter(deadline: .now() + after) {
                    if self.gateGen == gen { self.applyGate(closed) }
                }
            }
        }
    }

    private func applyGate(_ closed: Bool) {
        gated = closed
        if closed { abortUtterance() }
    }

    // MARK: audio processing (on q)

    private func process(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData?[0] else { return }
        let n = Int(buf.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        let rms = (sum / Float(max(n, 1))).squareRoot()

        if gated {
            preRoll.removeAll()
            return
        }

        let loud = rms > max(0.012, noise * 3)

        if !inSpeech {
            noise = noise * 0.95 + min(rms, 0.05) * 0.05
            preRoll.append(buf)
            if preRoll.count > 6 { preRoll.removeFirst() }
            if loud { beginUtterance() }
            return
        }

        if finishing { return }

        feed(buf)
        if loud {
            lastLoud = Date()
            loudCount += 1
        }
        let now = Date()
        if now.timeIntervalSince(lastLoud) > 0.8 || now.timeIntervalSince(startedAt) > 25 {
            endUtterance()
        }
    }

    private func feed(_ buf: AVAudioPCMBuffer) {
        for r in requests.values { r.append(buf) }
        if samples.count < Int(sampleRate * 8), let ch = buf.floatChannelData?[0] {
            samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(buf.frameLength)))
        }
    }

    private func beginUtterance() {
        inSpeech = true
        finishing = false
        uid += 1
        let my = uid
        startedAt = Date()
        lastLoud = Date()
        loudCount = 0
        requests = [:]
        tasks = [:]
        results = [:]
        doneLangs = []
        samples = []

        for l in langs {
            guard let rec = recognizers[l], rec.isAvailable else {
                doneLangs.insert(l)
                continue
            }
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.requiresOnDeviceRecognition = rec.supportsOnDeviceRecognition
            req.taskHint = .dictation
            req.addsPunctuation = true
            if !contextual.isEmpty { req.contextualStrings = contextual }
            requests[l] = req
            tasks[l] = rec.recognitionTask(with: req) { [weak self] res, err in
                guard let self = self else { return }
                self.q.async { self.handle(my, l, res, err) }
            }
        }
        for b in preRoll { feed(b) }
        preRoll.removeAll()
    }

    private func handle(_ my: Int, _ l: Lang, _ res: SFSpeechRecognitionResult?, _ err: Error?) {
        guard my == uid else { return }
        if let r = res {
            let segs = r.bestTranscription.segments
            let conf: Float = segs.isEmpty ? 0 : segs.map { $0.confidence }.reduce(0, +) / Float(segs.count)
            results[l] = (r.bestTranscription.formattedString, conf)
            if r.isFinal { doneLangs.insert(l) }
            if !finishing {
                let best = pick()
                onLive?(best?.1 ?? "")
                if let b = best { onPartial?(my, b.0, b.1) }
            }
        }
        if err != nil { doneLangs.insert(l) }
        if finishing && doneLangs.count >= langs.count { finish() }
    }

    private func endUtterance() {
        guard inSpeech, !finishing else { return }
        if loudCount < 5 {
            abortUtterance()
            return
        }
        finishing = true
        let my = uid
        for r in requests.values { r.endAudio() }
        q.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            if self.uid == my && self.finishing { self.finish() }
        }
        if doneLangs.count >= langs.count { finish() }
    }

    private func finish() {
        let choice = pick()
        let myUtt = uid
        let smp = samples
        let sr = sampleRate
        resetUtterance()
        onLive?("")
        guard let (lang, text) = choice else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let f0 = Pitch.median(smp, sampleRate: sr)
            self?.onHeard?(Heard(lang: lang, text: clean, pitch: f0, utt: myUtt))
        }
    }

    private func abortUtterance() {
        resetUtterance()
        onLive?("")
    }

    private func resetUtterance() {
        for t in tasks.values { t.cancel() }
        tasks = [:]
        requests = [:]
        results = [:]
        doneLangs = []
        samples = []
        inSpeech = false
        finishing = false
        loudCount = 0
        uid += 1
    }

    // MARK: language choice

    private func pick() -> (Lang, String)? {
        var best: (Lang, String, Float)? = nil
        for l in langs {
            guard let r = results[l], !r.text.isEmpty else { continue }
            var s: Float = r.conf > 0 ? r.conf : 0.5
            if !Self.matchesScript(r.text, l) { s *= 0.1 }
            if langs.count > 1 { s += Float(min(r.text.count, 40)) * 0.002 }
            s += bias[l] ?? 0
            if best == nil || s > best!.2 { best = (l, r.text, s) }
        }
        if let b = best { return (b.0, b.1) }
        return nil
    }

    private static func matchesScript(_ text: String, _ lang: Lang) -> Bool {
        var cjk = 0, latin = 0, arabic = 0
        for u in text.unicodeScalars {
            switch u.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: cjk += 1
            case 0x41...0x5A, 0x61...0x7A: latin += 1
            case 0x0600...0x06FF: arabic += 1
            default: break
            }
        }
        switch lang {
        case .zh: return cjk > 0
        case .en: return latin > 0 && cjk == 0 && arabic == 0
        case .ar: return arabic > 0
        }
    }
}
