import Foundation
import AVFoundation

/// Speaks the translation with a male or female voice installed on the phone.
final class Speaker: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synth = AVSpeechSynthesizer()
    private var pending = 0

    var onBusy: (@Sendable (Bool) -> Void)?
    var onMissingVoice: (@Sendable (Lang) -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Call on the main thread.
    func speak(_ text: String, lang: Lang, female: Bool) {
        guard let voice = Self.voice(lang, female) else {
            onMissingVoice?(lang)
            return
        }
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        pending += 1
        if pending == 1 { onBusy?(true) }
        synth.speak(u)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        pending = 0
        onBusy?(false)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.done() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.done() }
    }

    private func done() {
        pending = max(0, pending - 1)
        if pending == 0 { onBusy?(false) }
    }

    static func voice(_ lang: Lang, _ female: Bool) -> AVSpeechSynthesisVoice? {
        let all = AVSpeechSynthesisVoice.speechVoices()
        var cands = all.filter { $0.language == lang.ttsCode }
        if cands.isEmpty { cands = all.filter { $0.language.hasPrefix(lang.rawValue) } }
        if cands.isEmpty { return AVSpeechSynthesisVoice(language: lang.ttsCode) }

        let want: AVSpeechSynthesisVoiceGender = female ? .female : .male
        let matching = cands.filter { $0.gender == want }
        let pool = matching.isEmpty ? cands : matching
        return pool.max { $0.quality.rawValue < $1.quality.rawValue }
    }
}
