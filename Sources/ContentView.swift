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
    @StateObject private var cloud: CloudEngine
    @State private var showSettings = false

    init() {
        let st = Settings()
        _settings = StateObject(wrappedValue: st)
        _voice = StateObject(wrappedValue: Voice(settings: st))
        _text = StateObject(wrappedValue: TextEngine(settings: st))
        _cloud = StateObject(wrappedValue: CloudEngine(settings: st))
    }

    private var lines: [ChatLine] {
        switch settings.engine {
        case "realtime": return voice.lines
        case "apple": return text.lines
        default: return cloud.lines
        }
    }
    private var status: String {
        switch settings.engine {
        case "realtime": return voice.status
        case "apple": return text.status
        default: return cloud.status
        }
    }
    private var running: Bool {
        switch settings.engine {
        case "realtime": return voice.running
        case "apple": return text.running
        default: return cloud.running
        }
    }
    private var talking: Bool {
        switch settings.engine {
        case "realtime": return voice.talking
        case "apple": return text.talking
        default: return cloud.talking
        }
    }

    private func refresh() { voice.refreshInstructions(); text.refresh(); cloud.refresh() }
    private func toggle() {
        switch settings.engine {
        case "realtime": voice.toggle()
        case "apple": text.toggle()
        default: cloud.toggle()
        }
    }

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
        .sheet(isPresented: $showSettings) { SettingsView(settings: settings, voice: voice, text: text, cloud: cloud) }
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
    @ObservedObject var cloud: CloudEngine
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
                Section("المحرك") {
                    Picker("المحرك", selection: Binding(get: { settings.engine }, set: { v in
                        voice.stop(); text.stop(); cloud.stop(); settings.engine = v
                    })) {
                        Text("الأدق: سمع OpenAI + ترجمة + نطق OpenAI").tag("cloud")
                        Text("OpenAI صوتي مباشر (تجريبي)").tag("realtime")
                        Text("آيفون بس (سمع ونطق من آبل)").tag("apple")
                    }
                    if settings.engine != "realtime" {
                        Picker("مين بيترجم", selection: $settings.brain) {
                            Text("OpenAI").tag("openai")
                            Text("DeepSeek").tag("deepseek")
                            Text("Claude").tag("anthropic")
                        }
                    }
                    Text("الأدق: الاتجاه بيتحدد من نص الكلام نفسه (حروف عربية أو صينية)، واللغة التالتة والضجيج بيتجاهلهم. المحرك الصوتي المباشر بيخمّن لحاله وممكن يغلط.")
                        .font(.footnote).foregroundColor(.secondary)
                    Toggle("ترجمة شبه فورية (أقل دقة، الافتراضي مطفي)", isOn: $settings.live)
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
                    SecureField("Azure Speech key (سمع ونطق)", text: $settings.keyAzure)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .environment(\.layoutDirection, .leftToRight)
                    TextField("منطقة Azure مثل westeurope", text: $settings.azureRegion)
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
                    Toggle("صوت بنت (Azure وآبل)", isOn: $settings.female)
                    Toggle("أنا لابس سماعات (يسمع وهو عم يحكي)", isOn: $settings.headphones)
                }
                Section("كلمات مهمة") {
                    TextField("أسماء، بضاعة، مصطلحات", text: $settings.glossary, axis: .vertical)
                    Button("تطبيق") { voice.refreshInstructions(); text.refresh(); cloud.refresh() }
                }
                Section {
                    Button("مسح المحادثة") { voice.clear(); text.clear(); cloud.clear() }
                }
            }
            .navigationTitle("الإعدادات")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } } }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
}
