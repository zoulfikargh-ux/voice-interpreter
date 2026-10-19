import Foundation
import AVFoundation
import QuartzCore

// MARK: - OpenAI audio calls

enum OpenAIAudio {
    /// Speech to text. The language is NOT forced: the caller keeps only the two languages of the chosen pair.
    static func transcribe(wav: Data, key: String, prompt: String) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", "gpt-4o-transcribe")
        field("response_format", "json")
        field("temperature", "0")
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AIError.badResponse }
        guard http.statusCode == 200 else {
            let snippet = String(String(data: data, encoding: .utf8)?.prefix(200) ?? "")
            throw AIError.http(http.statusCode, snippet)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String else { throw AIError.badResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Text to speech, raw PCM 24 kHz 16 bit mono.
    static func speak(text: String, voice: String, instructions: String, key: String) async throws -> Data {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": "gpt-4o-mini-tts",
            "input": text,
            "voice": voice,
            "instructions": instructions,
            "response_format": "pcm"
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AIError.badResponse }
        guard http.statusCode == 200 else {
            let snippet = String(String(data: data, encoding: .utf8)?.prefix(200) ?? "")
            throw AIError.http(http.statusCode, snippet)
        }
        return data
    }
}

// MARK: - microphone capture with voice detection (audio thread)

final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var speaking = 0
    private var lastEnd = CACurrentMediaTime() - 10
    private var generation = 0
    var headphones = false

    func begin() -> Int { lock.lock(); defer { lock.unlock() }; speaking += 1; return generation }
    func end(_ g: Int) {
        lock.lock(); defer { lock.unlock() }
        if g == generation { speaking = max(0, speaking - 1); if speaking == 0 { lastEnd = CACurrentMediaTime() } }
    }
    func reset() { lock.lock(); speaking = 0; generation += 1; lock.unlock() }
    var busy: Bool { lock.lock(); defer { lock.unlock() }; return speaking > 0 }
    /// True when the microphone should be ignored (the phone is speaking and no headphones are used).
    var closed: Bool {
        lock.lock(); defer { lock.unlock() }
        if headphones { return false }
        return speaking > 0 || CACurrentMediaTime() - lastEnd < 1.0
    }
}

final class Capture: @unchecked Sendable {
    var onChunk: ((Data) -> Void)?
    var onTalking: ((Bool) -> Void)?
    var gate: Gate?
    var pauseEnd: Double = 0.45
    var minChunk: Double = 0.8
    var maxChunk: Double = 6.0

    private var converter: AVAudioConverter?
    private let fmt16 = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var samples: [Int16] = []
    private var preRoll: [[Int16]] = []
    private var inSpeech = false
    private var loudSeconds = 0.0
    private var lastLoud = 0.0
    private var speechStart = 0.0
    private var noise: Float = 0.004
    private var talkingFlag = false

    func setInput(_ f: AVAudioFormat) {
        converter = AVAudioConverter(from: f, to: fmt16)
        reset()
    }

    func reset() {
        samples = []
        preRoll = []
        inSpeech = false
        loudSeconds = 0
        setTalking(false)
    }

    private func setTalking(_ t: Bool) {
        guard talkingFlag != t else { return }
        talkingFlag = t
        onTalking?(t)
    }

    private func ints(_ buf: AVAudioPCMBuffer) -> [Int16]? {
        guard let conv = converter else { return nil }
        let ratio = 16000.0 / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt16, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, st in
            if fed { st.pointee = .noDataNow; return nil }
            fed = true
            st.pointee = .haveData
            return buf
        }
        guard err == nil, out.frameLength > 0, let p = out.int16ChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: p, count: Int(out.frameLength)))
    }

    func process(_ buf: AVAudioPCMBuffer) {
        if gate?.closed == true {
            if inSpeech { samples = []; inSpeech = false; loudSeconds = 0; setTalking(false) }
            preRoll = []
            return
        }
        guard let chunk = ints(buf) else { return }

        var rms: Float = 0
        if let ch = buf.floatChannelData?[0] {
            var sum: Float = 0
            let c = Int(buf.frameLength)
            for i in 0..<c { sum += ch[i] * ch[i] }
            rms = (sum / Float(max(c, 1))).squareRoot()
        }
        let loud = rms > max(0.015, noise * 3.5)
        let now = CACurrentMediaTime()
        let secs = Double(buf.frameLength) / buf.format.sampleRate

        if !inSpeech {
            if !loud {
                noise = noise * 0.95 + min(rms, 0.05) * 0.05
                preRoll.append(chunk)
                if preRoll.count > 8 { preRoll.removeFirst() }
                return
            }
            inSpeech = true
            samples = preRoll.flatMap { $0 }
            preRoll = []
            loudSeconds = 0
            speechStart = now
            lastLoud = now
            setTalking(true)
        }

        samples.append(contentsOf: chunk)
        if loud { lastLoud = now; loudSeconds += secs }
        let quiet = now - lastLoud
        let dur = now - speechStart

        if (quiet >= pauseEnd && dur >= minChunk) || (quiet >= 0.2 && dur >= maxChunk * 0.7) || dur >= maxChunk {
            flush()
        } else if quiet >= 1.2 {
            // a short noise with nothing after it
            samples = []
            inSpeech = false
            loudSeconds = 0
            setTalking(false)
        }
    }

    private func flush() {
        let s = samples
        let enough = loudSeconds >= 0.3
        samples = []
        inSpeech = false
        loudSeconds = 0
        setTalking(false)
        guard enough, s.count > 4000 else { return }
        onChunk?(Self.wav(s))
    }

    static func wav(_ s: [Int16]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let bytes = UInt32(s.count * 2)
        d.append("RIFF".data(using: .ascii)!); u32(36 + bytes)
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(bytes)
        s.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }
}

// MARK: - the engine

/// Most accurate engine: OpenAI listens (speech to text), the chosen AI translates piece by piece while the person
/// is still talking, OpenAI speaks the result. The direction of every translation is decided from the written text
/// (Arabic letters or Chinese characters), never guessed by a model.
@MainActor
final class CloudEngine: ObservableObject {
    @Published var lines: [ChatLine] = []
    @Published var status = "اضغط المايك للبدء"
    @Published var running = false
    @Published var talking = false

    let s: Settings
    private let ai = AIService()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    private let capture = Capture()
    private let gate = Gate()

    private struct Grp {
        var lang: Lang
        var parts: [String]
        var meID: UUID
        var aiID: UUID
        var at: Date
    }
    private struct Job {
        var src: Lang
        var dst: Lang
        var chunk: String
        var previous: String
        var meID: UUID
        var aiID: UUID
    }

    private var cur: Grp? = nil
    private var prevA: Task<Job?, Never>? = nil
    private var prevB: Task<Void, Never>? = nil
    private var context: [String] = []
    private var history: [[String: String]] = []
    private var spokenCorpus = ""
    private var wired = false

    init(settings: Settings) { s = settings }

    // MARK: control

    func toggle() { running ? stop() : start() }

    func start() {
        let k = s.keyOpenAI.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty { status = "حط مفتاح OpenAI بالإعدادات (للسمع والنطق)"; return }
        guard let p = s.provider else { return }
        if s.key(for: p).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            status = "حط مفتاح \(p.label) بالإعدادات"
            return
        }
        Task {
            let granted = await AVAudioApplication.requestRecordPermission()
            if granted { begin() } else { status = "المايك مقفول: الإعدادات > الخصوصية > المايكروفون" }
        }
    }

    private func begin() {
        do {
            let a = AVAudioSession.sharedInstance()
            try a.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try a.setActive(true)
            gate.headphones = s.headphones || Self.headphonesConnected()

            let input = engine.inputNode
            try input.setVoiceProcessingEnabled(true)
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: playFmt)
            let inFmt = input.outputFormat(forBus: 0)
            capture.setInput(inFmt)
            wire()
            applyTuning()
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: inFmt) { [weak self] buf, _ in
                self?.capture.process(buf)
            }
            engine.prepare()
            try engine.start()
            player.play()
        } catch {
            status = "خطأ بالصوت: \(error.localizedDescription)"
            return
        }
        running = true
        status = "جاهز، احكي…"
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        engine.detach(player)
        gate.reset()
        capture.reset()
        running = false
        talking = false
        cur = nil
        status = "متوقف"
    }

    func refresh() {
        if running { applyTuning() }
    }

    func clear() { lines.removeAll(); context = []; history = []; cur = nil }

    private func wire() {
        if wired { return }
        wired = true
        capture.gate = gate
        capture.onTalking = { [weak self] t in Task { @MainActor in self?.talking = t } }
        capture.onChunk = { [weak self] wav in Task { @MainActor in self?.handleChunk(wav) } }
    }

    private func applyTuning() {
        gate.headphones = s.headphones || Self.headphonesConnected()
        if s.mode == "advisor" {
            capture.pauseEnd = 0.8; capture.minChunk = 0.8; capture.maxChunk = 20
        } else if s.live {
            capture.pauseEnd = 0.4; capture.minChunk = 0.8; capture.maxChunk = 5
        } else {
            capture.pauseEnd = 0.8; capture.minChunk = 0.8; capture.maxChunk = 20
        }
    }

    static func headphonesConnected() -> Bool {
        let ports: [AVAudioSession.Port] = [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .airPlay, .carAudio, .usbAudio]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { ports.contains($0.portType) }
    }

    // MARK: language from the text itself

    private func detect(_ t: String) -> Lang? {
        var ar = 0, zh = 0, latin = 0, other = 0
        for u in t.unicodeScalars {
            switch u.value {
            case 0x0600...0x06FF, 0x0750...0x077F: ar += 1
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: zh += 1
            case 0x41...0x5A, 0x61...0x7A: latin += 1
            case 0x3040...0x30FF, 0xAC00...0xD7AF, 0x0400...0x04FF, 0x0E00...0x0E7F: other += 1
            default: break
            }
        }
        if other > 0 { return nil }
        let p = s.mode == "advisor" ? (Lang.ar, Lang.ar) : s.langs
        let allowed: Set<Lang> = [p.0, p.1]
        var best: (Lang, Int)? = nil
        for (l, n) in [(Lang.ar, ar), (Lang.zh, zh), (Lang.en, latin)] where allowed.contains(l) && n > 0 {
            if best == nil || n > best!.1 { best = (l, n) }
        }
        guard let b = best else { return nil }
        if b.0 == .en && b.1 < 3 { return nil }
        return b.0
    }

    private static let junk = ["شكرا على المشاهدة", "اشترك", "ترجمة نانسي", "subscribe", "thanks for watching", "thank you for watching", "字幕", "请不吝", "点赞"]

    private func normalized(_ t: String) -> String {
        String(t.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private func isJunk(_ t: String) -> Bool {
        let low = t.lowercased()
        return Self.junk.contains { low.contains($0) }
    }

    private func isEcho(_ t: String) -> Bool {
        let n = normalized(t)
        return n.count >= 4 && spokenCorpus.contains(n)
    }

    private func destination(_ src: Lang) -> Lang {
        let p = s.langs
        return src == p.0 ? p.1 : p.0
    }

    // MARK: transcript

    @discardableResult
    private func addLine(_ k: ChatLine.Kind, _ t: String) -> UUID {
        let l = ChatLine(kind: k, text: t)
        lines.append(l)
        return l.id
    }
    private func setLine(_ id: UUID, _ t: String) {
        if let i = lines.firstIndex(where: { $0.id == id }) { lines[i].text = t }
    }
    private func appendLine(_ id: UUID, _ t: String) {
        if let i = lines.firstIndex(where: { $0.id == id }) {
            lines[i].text = (lines[i].text + " " + t).trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: pipeline

    private func handleChunk(_ wav: Data) {
        guard running, let p = s.provider else { return }
        let key = s.keyOpenAI.trimmingCharacters(in: .whitespacesAndNewlines)
        let glossary = s.glossary.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = glossary
        status = "عم يسمع…"

        let before = prevA
        let taskA = Task { @MainActor [weak self] () -> Job? in
            // 1) speech to text, runs in parallel with the other pieces
            var text = ""
            do {
                text = try await OpenAIAudio.transcribe(wav: wav, key: key, prompt: prompt)
            } catch {
                self?.addLine(.err, "تعذر السمع: \(error.localizedDescription)")
                _ = await before?.value
                return nil
            }
            // 2) keep the order of the pieces
            _ = await before?.value
            guard let self = self else { return nil }
            return self.group(text)
        }
        prevA = taskA

        let beforeB = prevB
        let advisor = s.mode == "advisor"
        prevB = Task { @MainActor [weak self] in
            guard let self = self else { return }
            guard let job = await taskA.value else { await beforeB?.value; return }
            if advisor {
                await self.advise(job, provider: p, beforeB)
            } else {
                await self.interpret(job, provider: p, beforeB)
            }
        }
    }

    /// Decides the language of the heard text and joins it with the previous pieces of the same sentence.
    private func group(_ raw: String) -> Job? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || isJunk(text) { status = "جاهز، احكي…"; return nil }
        guard let lang = detect(text) else { status = "جاهز، احكي…"; return nil }
        if isEcho(text) { return nil }

        let sep = (lang == .zh) ? "" : " "
        if s.mode == "advisor" {
            let me = addLine(.me, text)
            let ai = addLine(.ai, "")
            return Job(src: lang, dst: .ar, chunk: text, previous: "", meID: me, aiID: ai)
        }
        let now = Date()
        if var g = cur, g.lang == lang, now.timeIntervalSince(g.at) < 3.0, s.live {
            let previous = g.parts.joined(separator: sep)
            g.parts.append(text)
            g.at = now
            cur = g
            setLine(g.meID, g.parts.joined(separator: sep))
            return Job(src: lang, dst: destination(lang), chunk: text, previous: previous, meID: g.meID, aiID: g.aiID)
        }
        let me = addLine(.me, text)
        let ai = addLine(.ai, "")
        cur = Grp(lang: lang, parts: [text], meID: me, aiID: ai, at: now)
        return Job(src: lang, dst: destination(lang), chunk: text, previous: "", meID: me, aiID: ai)
    }

    private func interpret(_ job: Job, provider p: AIProvider, _ before: Task<Void, Never>?) async {
        status = "عم يترجم…"
        let key = s.key(for: p)
        let openai = s.keyOpenAI.trimmingCharacters(in: .whitespacesAndNewlines)
        var translation: String? = nil
        var errText = ""
        do {
            let r = try await ai.process(text: job.chunk, from: job.src, to: job.dst, context: Array(context.suffix(6)),
                                         glossary: s.glossary, provider: p, key: key, model: s.textModel,
                                         previous: job.previous, fragment: s.live)
            translation = r.translation
            let fixed = r.source.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fixed.isEmpty && job.previous.isEmpty { setLine(job.meID, fixed) }
        } catch {
            errText = error.localizedDescription
        }
        guard let t = translation else {
            addLine(.err, "تعذرت الترجمة: \(errText)")
            await before?.value
            return
        }

        var pcm: Data? = nil
        do {
            pcm = try await OpenAIAudio.speak(text: t, voice: s.voice, instructions: Self.ttsStyle(job.dst), key: openai)
        } catch {
            addLine(.err, "تعذر النطق: \(error.localizedDescription)")
        }

        await before?.value
        appendLine(job.aiID, t)
        context.append("\(job.src.englishName): \(job.chunk) => \(job.dst.englishName): \(t)")
        if context.count > 12 { context.removeFirst(context.count - 12) }
        spokenCorpus = String((spokenCorpus + normalized(t)).suffix(600))
        if let d = pcm { play(d) }
        status = "جاهز، احكي…"
    }

    private func advise(_ job: Job, provider p: AIProvider, _ before: Task<Void, Never>?) async {
        status = "عم يفكر…"
        history.append(["role": "user", "content": job.chunk])
        if history.count > 12 { history.removeFirst(history.count - 12) }
        let system = Instructions.build(mode: "advisor", pair: s.pair, glossary: s.glossary)
        do {
            let a = try await ai.chat(system: system, messages: history, provider: p, key: s.key(for: p), model: s.textModel)
            history.append(["role": "assistant", "content": a])
            let pcm = try? await OpenAIAudio.speak(text: a, voice: s.voice, instructions: Self.ttsStyle(.ar),
                                                    key: s.keyOpenAI.trimmingCharacters(in: .whitespacesAndNewlines))
            await before?.value
            setLine(job.aiID, a)
            spokenCorpus = String((spokenCorpus + normalized(a)).suffix(600))
            if let d = pcm { play(d) }
        } catch {
            addLine(.err, "تعذر الرد: \(error.localizedDescription)")
            await before?.value
        }
        status = "جاهز، احكي…"
    }

    static func ttsStyle(_ l: Lang) -> String {
        switch l {
        case .ar: return "Speak in a natural, conversational Lebanese Arabic accent (Levantine), at a natural, fairly quick pace, like a friendly person in daily life, not like a news reader."
        case .zh: return "Speak clear, natural, conversational Mandarin Chinese at a natural pace."
        case .en: return "Speak natural, conversational English at a natural pace."
        }
    }

    // MARK: playback

    private func play(_ pcm: Data) {
        let n = pcm.count / 2
        guard n > 0, running,
              let buf = AVAudioPCMBuffer(pcmFormat: playFmt, frameCapacity: AVAudioFrameCount(n)),
              let dst = buf.floatChannelData?[0] else { return }
        buf.frameLength = AVAudioFrameCount(n)
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<n {
                let v = raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)
                dst[i] = Float(Int16(littleEndian: v)) / 32768.0
            }
        }
        let g = gate.begin()
        let gt = gate
        player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { _ in gt.end(g) }
    }
}
