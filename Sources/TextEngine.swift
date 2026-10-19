import Foundation
import AVFoundation
import Speech

/// Text engine for DeepSeek, OpenAI (text) and Claude: the iPhone listens (on device),
/// the chosen AI translates piece by piece while the person is still talking, and the phone speaks it.
@MainActor
final class TextEngine: ObservableObject {
    @Published var lines: [ChatLine] = []
    @Published var status = "اضغط المايك للبدء"
    @Published var running = false
    @Published var talking = false

    let s: Settings
    private let pipeline = AudioPipeline()
    private let speaker = Speaker()
    private let ai = AIService()
    private var wired = false

    private struct Utt {
        var id: Int
        var lang: Lang
        var committed = 0
        var parts: [String] = []
        var meLine: UUID? = nil
        var aiLine: UUID? = nil
        var ignored = false
    }
    private var utt: Utt? = nil
    private var lastSpeakTask: Task<Void, Never>? = nil
    private var spokenCorpus = ""
    private var speakingNow = false
    private var lastSpeechEnd = Date.distantPast
    private var context: [String] = []
    private var history: [[String: String]] = []

    init(settings: Settings) { s = settings }

    // MARK: control

    func toggle() { running ? stop() : start() }

    func start() {
        guard let p = s.provider else { return }
        if s.key(for: p).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            status = "حط مفتاح \(p.label) بالإعدادات"
            return
        }
        wire()
        Task {
            let speechOK = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
            }
            let micOK = await AVAudioApplication.requestRecordPermission()
            guard speechOK, micOK else {
                status = "فعّل المايك والتعرف على الكلام للتطبيق من إعدادات الآيفون"
                return
            }
            applyLangs()
            do {
                try pipeline.start()
                running = true
                status = "عم سمع…"
            } catch {
                status = "تعذر تشغيل المايك: \(error.localizedDescription)"
            }
        }
    }

    func stop() {
        pipeline.stop()
        speaker.stop()
        running = false
        talking = false
        utt = nil
        status = "متوقف"
    }

    func refresh() {
        if running { applyLangs() }
    }

    func clear() { lines.removeAll(); context = []; history = [] }

    private func wire() {
        if wired { return }
        wired = true
        pipeline.onHeard = { [weak self] h in Task { @MainActor in self?.handle(h) } }
        pipeline.onLive = { [weak self] t in Task { @MainActor in self?.talking = !t.isEmpty } }
        pipeline.onStatus = { [weak self] t in Task { @MainActor in self?.status = t } }
        pipeline.onPartial = { [weak self] id, lang, text in Task { @MainActor in self?.handlePartial(id, lang, text) } }
        speaker.onBusy = { [weak self] busy in Task { @MainActor in self?.speakingChanged(busy) } }
        speaker.onMissingVoice = { [weak self] lang in
            Task { @MainActor in
                self?.status = "ما في صوت \(lang.name) على الجوال: الإعدادات > إمكانية الوصول > المحتوى المنطوق > الأصوات"
            }
        }
    }

    private func applyLangs() {
        let langs: [Lang]
        if s.mode == "advisor" {
            langs = [.ar]
            pipeline.setBias([:])
        } else {
            let p = s.langs
            langs = [p.0, p.1]
            pipeline.setBias((p.0 == .ar || p.1 == .ar) ? [.ar: 0.12] : [:])
        }
        let terms = s.glossary
            .split(whereSeparator: { ",،;؛\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        pipeline.setContext(terms)
        pipeline.setLangs(langs)
    }

    // MARK: speaking state and microphone gate

    private func headphonesConnected() -> Bool {
        let ports: [AVAudioSession.Port] = [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .airPlay, .carAudio, .usbAudio]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { ports.contains($0.portType) }
    }

    private func speakingChanged(_ busy: Bool) {
        speakingNow = busy
        if !busy { lastSpeechEnd = Date() }
        let gate = !(s.headphones || headphonesConnected())
        if gate {
            if busy { pipeline.setGate(true) } else { pipeline.setGate(false, after: 0.7) }
        } else {
            pipeline.setGate(false)
        }
        if busy { status = "عم يحكي…" } else if running { status = "عم سمع…" }
    }

    // MARK: text helpers

    private static let stops: Set<Character> = [".", ",", "!", "?", ";", ":", "،", "؛", "؟", "。", "，", "！", "？", "；", "："]

    private func units(_ text: String, _ lang: Lang) -> [String] {
        if lang == .zh { return text.filter { !$0.isWhitespace }.map { String($0) } }
        return text.split(whereSeparator: { $0.isWhitespace }).map { String($0) }
    }

    private func endsClause(_ unit: String) -> Bool {
        if let c = unit.last { return Self.stops.contains(c) }
        return false
    }

    private func normalized(_ t: String) -> String {
        String(t.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private func isEcho(_ t: String) -> Bool {
        guard speakingNow || Date().timeIntervalSince(lastSpeechEnd) < 2 else { return false }
        let n = normalized(t)
        return n.count >= 4 && spokenCorpus.contains(n)
    }

    private func destination(for src: Lang) -> Lang {
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

    // MARK: simultaneous translation

    private func handlePartial(_ id: Int, _ lang: Lang, _ text: String) {
        guard s.live, s.mode == "interp" else { return }
        if utt?.id != id { utt = Utt(id: id, lang: lang) }
        guard var u = utt, !u.ignored else { return }
        if u.committed > 0 && lang != u.lang { return }
        if u.committed == 0 { u.lang = lang }
        utt = u

        let us = units(text, u.lang)
        let committed = u.committed
        guard us.count > committed else { return }

        let zh = (u.lang == .zh)
        let minLen = committed == 0 ? (zh ? 5 : 3) : (zh ? 7 : 4)
        let hold = zh ? 2 : 1

        var cut = -1
        var p = us.count
        while p > committed + 1 {
            if endsClause(us[p - 1]) { cut = p; break }
            p -= 1
        }
        if cut < 0 {
            let stableEnd = us.count - hold
            if stableEnd - committed >= minLen { cut = stableEnd }
        }
        guard cut > committed else { return }
        commit(upTo: cut, units: us, final: false)
    }

    private func commit(upTo cut: Int, units us: [String], final: Bool) {
        guard var u = utt, cut > u.committed, cut <= us.count else { return }
        let sep = (u.lang == .zh) ? "" : " "
        let chunk = us[u.committed..<cut].joined(separator: sep)
        if isEcho(chunk) {
            u.ignored = true
            utt = u
            return
        }
        let idx = u.parts.count
        let previous = u.parts.joined(separator: sep)
        u.parts.append(chunk)
        u.committed = cut
        let src = u.lang
        let dst = destination(for: src)

        if u.meLine == nil {
            u.meLine = addLine(.me, "")
            u.aiLine = addLine(.ai, "")
        }
        utt = u
        let meID = u.meLine!
        let aiID = u.aiLine!
        setLine(meID, u.parts.joined(separator: sep))
        status = "عم يترجم…"

        let isFragment = !(final && idx == 0)
        let prevTask = lastSpeakTask
        lastSpeakTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            let r = await self.translate(chunk, from: src, to: dst, previous: previous, fragment: isFragment)
            await prevTask?.value
            self.apply(r, aiID: aiID, src: src, dst: dst, chunk: chunk)
        }
    }

    private func handle(_ h: Heard) {
        if s.mode == "advisor" { advise(h); return }
        if s.live, let u = utt, u.id == h.utt {
            if u.ignored { utt = nil; return }
            if u.committed > 0 {
                if h.lang == u.lang {
                    let us = units(h.text, u.lang)
                    if us.count > u.committed { commit(upTo: us.count, units: us, final: true) }
                }
                utt = nil
                return
            }
        }
        utt = nil
        if isEcho(h.text) { return }
        let src = h.lang
        let dst = destination(for: src)
        let meID = addLine(.me, h.text)
        let aiID = addLine(.ai, "")
        status = "عم يترجم…"
        let text = h.text
        let prevTask = lastSpeakTask
        lastSpeakTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            let r = await self.translate(text, from: src, to: dst, previous: "", fragment: false)
            await prevTask?.value
            if let f = r.fixed { self.setLine(meID, f) }
            self.apply(r, aiID: aiID, src: src, dst: dst, chunk: text)
        }
    }

    private struct Tr {
        var text: String?
        var fixed: String?
        var err: String
    }

    private func translate(_ text: String, from src: Lang, to dst: Lang, previous: String, fragment: Bool) async -> Tr {
        guard let p = s.provider else { return Tr(text: nil, fixed: nil, err: "ما في محرك") }
        do {
            let r = try await ai.process(text: text, from: src, to: dst, context: Array(context.suffix(6)),
                                         glossary: s.glossary, provider: p, key: s.key(for: p), model: s.textModel,
                                         previous: previous, fragment: fragment)
            let f = r.source.trimmingCharacters(in: .whitespacesAndNewlines)
            return Tr(text: r.translation, fixed: f.isEmpty ? nil : f, err: "")
        } catch {
            return Tr(text: nil, fixed: nil, err: error.localizedDescription)
        }
    }

    private func apply(_ r: Tr, aiID: UUID, src: Lang, dst: Lang, chunk: String) {
        if let t = r.text {
            appendLine(aiID, t)
            context.append("\(src.englishName): \(chunk) => \(dst.englishName): \(t)")
            if context.count > 12 { context.removeFirst(context.count - 12) }
            spokenCorpus = String((spokenCorpus + normalized(t)).suffix(500))
            speaker.speak(t, lang: dst, female: s.female)
        } else {
            addLine(.err, "تعذرت الترجمة: \(r.err)")
            status = "تعذرت الترجمة"
        }
    }

    // MARK: advisor

    private func advise(_ h: Heard) {
        utt = nil
        guard let p = s.provider else { return }
        if isEcho(h.text) { return }
        addLine(.me, h.text)
        let aiID = addLine(.ai, "")
        status = "عم يفكر…"
        history.append(["role": "user", "content": h.text])
        if history.count > 12 { history.removeFirst(history.count - 12) }
        let system = Instructions.build(mode: "advisor", pair: s.pair, glossary: s.glossary)
        let msgs = history
        let key = s.key(for: p)
        let model = s.textModel
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                let a = try await self.ai.chat(system: system, messages: msgs, provider: p, key: key, model: model)
                self.history.append(["role": "assistant", "content": a])
                self.setLine(aiID, a)
                self.spokenCorpus = String((self.spokenCorpus + self.normalized(a)).suffix(500))
                self.speaker.speak(a, lang: .ar, female: self.s.female)
            } catch {
                self.addLine(.err, "تعذر الرد: \(error.localizedDescription)")
                self.status = "تعذر الرد"
            }
        }
    }
}
