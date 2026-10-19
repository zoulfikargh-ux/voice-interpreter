import SwiftUI

@main
struct VoiceApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @StateObject private var settings: Settings
    @StateObject private var voice: Voice
    @StateObject private var text: TextEngine
    @State private var showSettings = false

    init() {
        let st = Settings()
        _settings = StateObject(wrappedValue: st)
        _voice = StateObject(wrappedValue: Voice(settings: st))
        _text = StateObject(wrappedValue: TextEngine(settings: st))
    }

    private var isRT: Bool { settings.engine == "realtime" }
    private var lines: [ChatLine] { isRT ? voice.lines : text.lines }
    private var status: String { isRT ? voice.status : text.status }
    private var running: Bool { isRT ? voice.running : text.running }
    private var talking: Bool { isRT ? voice.talking : text.talking }

    private func refresh() { voice.refreshInstructions(); text.refresh() }
    private func toggle() { if isRT { voice.toggle() } else { text.toggle() } }

    private let pairs: [(String, String)] = [("arzh", "عربي ⇄ صيني"), ("aren", "عربي ⇄ إنجليزي"), ("enzh", "إنجليزي ⇄ صيني")]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            footer
        }
        .environment(\.layoutDirection, .rightToLeft)
        .sheet(isPresented: $showSettings) { SettingsView(settings: settings, voice: voice, text: text) }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Text("مترجم مباشر").font(.headline)
                Spacer()
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            Picker("", selection: Binding(get: { settings.mode }, set: { settings.mode = $0; refresh() })) {
                Text("مترجم").tag("interp")
                Text("مستشار").tag("advisor")
            }
            .pickerStyle(.segmented)
            if settings.mode == "interp" {
                Picker("", selection: Binding(get: { settings.pair }, set: { settings.pair = $0; refresh() })) {
                    ForEach(pairs, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(12)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if lines.isEmpty {
                    Text("اضغط المايك مرة وحدة وخلّيه شغّال.\nمترجم: بيسمع اللغتين ويترجم من وحدة للتانية.\nمستشار: بتحكي معه وبيرد عليك بصوته.\nيفضّل تلبس سماعات.")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding(30)
                }
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(lines) { l in
                        Text(l.text)
                            .font(l.kind == .ai ? .title3.weight(.semibold) : .body)
                            .foregroundColor(color(l.kind))
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: l.kind == .ai ? .trailing : .leading)
                            .background(Color.gray.opacity(0.12))
                            .cornerRadius(12)
                            .id(l.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: lines.last?.text) { _ in
                if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func color(_ k: ChatLine.Kind) -> Color {
        switch k {
        case .me: return .orange
        case .ai: return .green
        case .err: return .red
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Text(status).font(.footnote).foregroundColor(.secondary)
            Button { toggle() } label: {
                Image(systemName: running ? "stop.fill" : "mic.fill")
                    .font(.system(size: 34))
                    .foregroundColor(.white)
                    .frame(width: 84, height: 84)
                    .background(running ? Color.red : Color.green)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.red.opacity(0.3), lineWidth: talking ? 10 : 0))
            }
        }
        .padding(.vertical, 12)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var voice: Voice
    @ObservedObject var text: TextEngine
    @Environment(\.dismiss) private var dismiss

    private let voices: [(String, String)] = [
        ("marin", "بنت: marin"), ("coral", "بنت: coral"), ("sage", "بنت: sage"), ("shimmer", "بنت: shimmer"),
        ("cedar", "شب: cedar"), ("ash", "شب: ash"), ("echo", "شب: echo"), ("verse", "شب: verse"),
        ("ballad", "ballad"), ("alloy", "alloy")
    ]
    private let speeds: [(Int, String)] = [(300, "أسرع"), (450, "سريع"), (700, "عادي"), (1000, "بطيء")]

    var body: some View {
        NavigationStack {
            Form {
                Section("المحرك (اللي بدك تشتغل عليه)") {
                    Picker("المحرك", selection: Binding(get: { settings.engine }, set: { v in
                        voice.stop(); text.stop(); settings.engine = v
                    })) {
                        Text("OpenAI صوتي مباشر (الأسرع)").tag("realtime")
                        Text("DeepSeek (نصي)").tag("deepseek")
                        Text("OpenAI (نصي)").tag("openai")
                        Text("Claude (نصي)").tag("anthropic")
                    }
                    Text("الصوتي المباشر بيسمع وبيحكي بنفسه. النصي بيسمع الآيفون، والـAI بيترجم، والآيفون بينطق.")
                        .font(.footnote).foregroundColor(.secondary)
                    Toggle("ترجمة فورية (بيبلّش وإنت لسا عم تحكي)", isOn: $settings.live)
                    Text("غيّر الفوري ووقّف وشغّل من جديد ليتطبّق.")
                        .font(.footnote).foregroundColor(.secondary)
                }
                Section("المفاتيح") {
                    SecureField("OpenAI  sk-...", text: $settings.keyOpenAI)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .environment(\.layoutDirection, .leftToRight)
                    SecureField("DeepSeek  sk-...", text: $settings.keyDeepSeek)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .environment(\.layoutDirection, .leftToRight)
                    SecureField("Claude  sk-ant-...", text: $settings.keyAnthropic)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .environment(\.layoutDirection, .leftToRight)
                    TextField("موديل الصوتي: gpt-realtime-2.1", text: $settings.model)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .environment(\.layoutDirection, .leftToRight)
                    TextField("موديل النصي (اختياري)", text: $settings.textModel)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .environment(\.layoutDirection, .leftToRight)
                    Text("المفاتيح بتتحفظ بالـKeychain على التليفون وما بتتبعت إلا لشركتها. المحرك الصوتي بيحتاج مفتاح OpenAI.")
                        .font(.footnote).foregroundColor(.secondary)
                }
                Section("الصوت") {
                    Picker("الصوت", selection: $settings.voice) {
                        ForEach(voices, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Text("الصوت بيتثبت أول ما تبلش الجلسة. لتغييره وقّف وشغّل من جديد.")
                        .font(.footnote).foregroundColor(.secondary)
                    Picker("سرعة الرد", selection: $settings.silenceMs) {
                        ForEach(speeds, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Toggle("صوت بنت بالمحركات النصية", isOn: $settings.female)
                    Toggle("أنا لابس سماعات (يسمع وهو عم يحكي)", isOn: $settings.headphones)
                }
                Section("كلمات مهمة") {
                    TextField("أسماء، بضاعة، مصطلحات", text: $settings.glossary, axis: .vertical)
                    Button("تطبيق") { voice.refreshInstructions(); text.refresh() }
                }
                Section {
                    Button("مسح المحادثة") { voice.clear(); text.clear() }
                }
            }
            .navigationTitle("الإعدادات")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } } }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
}
