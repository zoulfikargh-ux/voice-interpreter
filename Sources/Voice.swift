import Foundation
import AVFoundation
import QuartzCore

struct ChatLine: Identifiable {
    enum Kind { case me, ai, err }
    let id = UUID()
    var kind: Kind
    var text: String
}

/// Talks to the OpenAI Realtime API over a WebSocket: streams the microphone up as 24 kHz PCM16
/// and plays the model's spoken answer as it arrives.
final class Voice: NSObject, ObservableObject, @unchecked Sendable {
    @Published var lines: [ChatLine] = []
    @Published var status = "اضغط المايك للبدء"
    @Published var running = false
    @Published var talking = false

    let s: Settings
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let outFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!
    private let playFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var gen = 0
    private var ready = false
    private var wantRun = false
    private var retry = 0
    private var headphonesNow = false

    private let lock = NSLock()
    private var speaking = 0
    private var playGen = 0

    // simultaneous mode (client side voice detection, audio is committed in short pieces)
    private let sendQ = DispatchQueue(label: "voice.send")
    private var respActive = false
    private var respPending = false
    private var chunkSamples = 0
    private var chunkHasSpeech = false
    private var lastLoud = CACurrentMediaTime()
    private var noise: Float = 0.004
    private var preRoll: [String] = []
    private var talkingFlag = false
    private var lastEnd = CACurrentMediaTime() - 10

    private var userLine: [String: UUID] = [:]
    private var respLine: UUID?

    init(settings: Settings) {
        self.s = settings
        super.init()
    }

    // MARK: start / stop

    func toggle() {
        if running { stop() } else { start() }
    }

    func start() {
        let k = s.keyOpenAI.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty { setStatus("حط مفتاح OpenAI بالإعدادات"); return }
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                if granted { self.begin() } else { self.setStatus("المايك مقفول: الإعدادات > الخصوصية > المايكروفون") }
            }
        }
    }

    private func begin() {
        do {
            let a = AVAudioSession.sharedInstance()
            try a.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try a.setActive(true)
            headphonesNow = Self.headphonesConnected()

            let input = engine.inputNode
            try input.setVoiceProcessingEnabled(true)
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: playFmt)
            let inFmt = input.outputFormat(forBus: 0)
            converter = AVAudioConverter(from: inFmt, to: outFmt)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: inFmt) { [weak self] buf, _ in
                self?.onMic(buf)
            }
            engine.prepare()
            try engine.start()
            player.play()
        } catch {
            setStatus("خطأ بالصوت: \(error.localizedDescription)")
            return
        }
        wantRun = true
        retry = 0
        resetChunk()
        running = true
        setStatus("عم يتصل…")
        connect()
    }

    func stop() {
        guard running || wantRun else { return }
        wantRun = false
        ready = false
        gen += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        engine.detach(player)
        lock.lock(); speaking = 0; playGen += 1; lock.unlock()
        running = false
        talking = false
        setStatus("متوقف")
    }

    static func headphonesConnected() -> Bool {
        let types: [AVAudioSession.Port] = [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { types.contains($0.portType) }
    }

    // MARK: websocket

    private func connect() {
        let model = s.model.trimmingCharacters(in: .whitespaces).isEmpty ? "gpt-realtime-2.1" : s.model.trimmingCharacters(in: .whitespaces)
        let enc = model.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? model
        guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=\(enc)") else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(s.keyOpenAI.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        let sess = URLSession(configuration: .default)
        session = sess
        let t = sess.webSocketTask(with: req)
        task = t
        gen += 1
        let g = gen
        ready = false
        t.resume()
        listen(t, g)
        sendConfig()
    }

    private func listen(_ t: URLSessionWebSocketTask, _ g: Int) {
        t.receive { [weak self] result in
            guard let self = self, g == self.gen else { return }
            switch result {
            case .success(let m):
                switch m {
                case .string(let str): self.handle(str)
                case .data(let d): if let str = String(data: d, encoding: .utf8) { self.handle(str) }
                @unknown default: break
                }
                self.listen(t, g)
            case .failure(let e):
                self.closed(e.localizedDescription, g)
            }
        }
    }

    private func closed(_ msg: String, _ g: Int) {
        DispatchQueue.main.async {
            guard g == self.gen, self.wantRun else { return }
            self.ready = false
            if self.retry < 3 {
                self.retry += 1
                self.setStatus("انقطع الاتصال، عم يعيد…")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8 * Double(self.retry)) {
                    if self.wantRun && g == self.gen { self.connect() }
                }
            } else {
                self.addLine(.err, "انقطع الاتصال: \(msg)\nتأكد من المفتاح والرصيد واسم الموديل.")
                self.stop()
            }
        }
    }

    private func sendJSON(_ obj: [String: Any]) {
        guard let t = task,
              let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return }
        t.send(.string(str)) { _ in }
    }

    private func sendConfig() {
        let instr = Instructions.build(mode: s.mode, pair: s.pair, glossary: s.glossary, live: s.live && s.mode == "interp")
        let manual = s.live && s.mode == "interp"
        var vad: Any = NSNull()
        if !manual {
            vad = [
                "type": "server_vad",
                "threshold": 0.7,
                "prefix_padding_ms": 300,
                "silence_duration_ms": s.silenceMs,
                "create_response": true,
                "interrupt_response": true
            ] as [String: Any]
        }
        sendJSON([
            "type": "session.update",
            "session": [
                "type": "realtime",
                "output_modalities": ["audio"],
                "instructions": instr,
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24000],
                        "transcription": ["model": "gpt-4o-mini-transcribe"],
                        "noise_reduction": ["type": (s.headphones || headphonesNow) ? "near_field" : "far_field"],
                        "turn_detection": vad
                    ],
                    "output": [
                        "format": ["type": "audio/pcm", "rate": 24000],
                        "voice": s.voice
                    ]
                ]
            ] as [String: Any]
        ])
    }

    /// Call after the mode, pair or word list changes while running.
    func refreshInstructions() {
        guard running, ready else { return }
        sendJSON([
            "type": "session.update",
            "session": ["type": "realtime", "instructions": Instructions.build(mode: s.mode, pair: s.pair, glossary: s.glossary, live: s.live && s.mode == "interp")]
        ])
    }

    // MARK: events

    private func handle(_ str: String) {
        guard let data = str.data(using: .utf8),
              let ev = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = ev["type"] as? String else { return }

        if type == "response.output_audio.delta", let b64 = ev["delta"] as? String {
            playDelta(b64)
            return
        }

        DispatchQueue.main.async {
            switch type {
            case "session.updated":
                if !self.ready {
                    self.ready = true
                    self.setStatus("جاهز، احكي…")
                }
            case "error":
                let msg = ((ev["error"] as? [String: Any])?["message"] as? String) ?? str
                self.addLine(.err, "خطأ: \(msg)")
            case "input_audio_buffer.speech_started":
                self.talking = true
                self.setStatus("عم سمعك…")
                self.bargeIn()
            case "input_audio_buffer.speech_stopped":
                self.talking = false
                self.setStatus("عم يفكر…")
            case "input_audio_buffer.committed":
                if let id = ev["item_id"] as? String { self.userLine[id] = self.addLine(.me, "…") }
            case "conversation.item.input_audio_transcription.completed":
                if let id = ev["item_id"] as? String, let lid = self.userLine[id] {
                    let t = ((ev["transcript"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    self.setLine(lid, t.isEmpty ? "(ما انفهم)" : t)
                }
            case "response.created":
                self.respLine = nil
                self.lock.lock(); self.respActive = true; self.lock.unlock()
            case "response.output_audio_transcript.delta":
                let d = (ev["delta"] as? String) ?? ""
                if self.respLine == nil { self.respLine = self.addLine(.ai, "") }
                if let lid = self.respLine { self.appendLine(lid, d) }
            case "response.done":
                self.respLine = nil
                self.responseFinished()
                self.lock.lock(); let sp = self.speaking; self.lock.unlock()
                if sp == 0 { self.setStatus("جاهز، احكي…") }
            default: break
            }
        }
    }

    // MARK: audio

    private func resetChunk() {
        chunkSamples = 0
        chunkHasSpeech = false
        lastLoud = CACurrentMediaTime()
        preRoll = []
        respActive = false
        respPending = false
    }

    private var manualMode: Bool { s.live && s.mode == "interp" }

    private func convert(_ buf: AVAudioPCMBuffer) -> (String, Int)? {
        guard let conv = converter else { return nil }
        let ratio = 24000.0 / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, st in
            if fed { st.pointee = .noDataNow; return nil }
            fed = true
            st.pointee = .haveData
            return buf
        }
        guard err == nil, out.frameLength > 0, let p = out.int16ChannelData?[0] else { return nil }
        let data = Data(bytes: p, count: Int(out.frameLength) * 2)
        return (data.base64EncodedString(), Int(out.frameLength))
    }

    private func appendAudio(_ b64: String) {
        sendQ.async { self.sendJSON(["type": "input_audio_buffer.append", "audio": b64]) }
    }

    private func onMic(_ buf: AVAudioPCMBuffer) {
        guard ready, task != nil else { return }
        lock.lock(); let sp = speaking; let ra = respActive; let le = lastEnd; lock.unlock()
        if !s.headphones && !headphonesNow {
            // no headphones: keep the microphone closed while the phone is answering, so it never hears itself
            if sp > 0 || ra || CACurrentMediaTime() - le < 1.0 { return }
        }
        guard let (b64, n) = convert(buf) else { return }

        if !manualMode {
            appendAudio(b64)
            return
        }

        // simultaneous mode: cut the audio at short pauses and ask for a translation of each piece
        var rms: Float = 0
        if let ch = buf.floatChannelData?[0] {
            var sum: Float = 0
            let c = Int(buf.frameLength)
            for i in 0..<c { sum += ch[i] * ch[i] }
            rms = (sum / Float(max(c, 1))).squareRoot()
        }
        let loud = rms > max(0.012, noise * 3)
        let now = CACurrentMediaTime()
        if !loud { noise = noise * 0.95 + min(rms, 0.05) * 0.05 }

        if loud {
            lastLoud = now
            if !chunkHasSpeech {
                chunkHasSpeech = true
                for p in preRoll { appendAudio(p) }
                preRoll = []
                setTalking(true)
            }
        }

        if chunkHasSpeech {
            appendAudio(b64)
            chunkSamples += n
            let dur = Double(chunkSamples) / 24000.0
            let quiet = now - lastLoud
            if (quiet >= 0.22 && dur >= 1.0) || (quiet >= 0.15 && dur >= 2.0) || dur >= 3.5 || quiet >= 0.7 {
                commitChunk()
            }
        } else {
            preRoll.append(b64)
            if preRoll.count > 4 { preRoll.removeFirst() }
        }
    }

    private func setTalking(_ t: Bool) {
        guard talkingFlag != t else { return }
        talkingFlag = t
        DispatchQueue.main.async { self.talking = t }
    }

    private func commitChunk() {
        chunkSamples = 0
        chunkHasSpeech = false
        setTalking(false)
        sendQ.async {
            self.sendJSON(["type": "input_audio_buffer.commit"])
            self.lock.lock()
            let go = !self.respActive
            if go { self.respActive = true } else { self.respPending = true }
            self.lock.unlock()
            if go { self.sendJSON(["type": "response.create"]) }
        }
    }

    private func responseFinished() {
        sendQ.async {
            self.lock.lock()
            self.respActive = false
            let go = self.respPending
            if go { self.respPending = false; self.respActive = true }
            self.lock.unlock()
            if go { self.sendJSON(["type": "response.create"]) }
        }
    }

    private func playDelta(_ b64: String) {
        guard let d = Data(base64Encoded: b64), d.count >= 2 else { return }
        let n = d.count / 2
        guard let buf = AVAudioPCMBuffer(pcmFormat: playFmt, frameCapacity: AVAudioFrameCount(n)),
              let dst = buf.floatChannelData?[0] else { return }
        buf.frameLength = AVAudioFrameCount(n)
        d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<n {
                let v = raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)
                dst[i] = Float(Int16(littleEndian: v)) / 32768.0
            }
        }
        lock.lock(); speaking += 1; let g = playGen; lock.unlock()
        DispatchQueue.main.async { if self.talking == false { self.setStatus("عم يحكي…") } }
        player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self = self else { return }
            self.lock.lock()
            var finished = false
            if self.playGen == g {
                self.speaking = max(0, self.speaking - 1)
                finished = self.speaking == 0
                if finished { self.lastEnd = CACurrentMediaTime() }
            }
            self.lock.unlock()
            if finished {
                DispatchQueue.main.async { if self.running && self.ready { self.setStatus("جاهز، احكي…") } }
            }
        }
    }

    private func bargeIn() {
        lock.lock(); let sp = speaking; lock.unlock()
        guard sp > 0 else { return }
        lock.lock(); speaking = 0; playGen += 1; lock.unlock()
        player.stop()
        player.play()
    }

    // MARK: transcript (main thread)

    private func setStatus(_ t: String) {
        if Thread.isMainThread { status = t } else { DispatchQueue.main.async { self.status = t } }
    }

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
        if let i = lines.firstIndex(where: { $0.id == id }) { lines[i].text += t }
    }

    func clear() { lines.removeAll(); userLine = [:]; respLine = nil }
}
