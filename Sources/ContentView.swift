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
    @State private var showSettings = false

    init() {
        let st = Settings()
        _settings = StateObject(wrappedValue: st)
        _voice = StateObject(wrappedValue: Voice(settings: st))
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
        .sheet(isPresented: $showSettings) { SettingsView(settings: settings, voice: voice) }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Text("مترجم مباشر").font(.headline)
                Spacer()
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            Picker("", selection: Binding(get: { settings.mode }, set: { settings.mode = $0; voice.refreshInstructions() })) {
                Text("مترجم").tag("interp")
                Text("مستشار").tag("advisor")
            }
            .pickerStyle(.segmented)
            if settings.mode == "interp" {
                Picker("", selection: Binding(get: { settings.pair }, set: { settings.pair = $0; voice.refreshInstructions() })) {
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
                if voice.lines.isEmpty {
                    Text("اضغط المايك مرة وحدة وخلّيه شغّال.\nمترجم: بيسمع اللغتين ويترجم من وحدة للتانية.\nمستشار: بتحكي معه وبيرد عليك بصوته.\nيفضّل تلبس سماعات.")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding(30)
                }
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(voice.lines) { l in
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
            .onChange(of: voice.lines.last?.text) { _ in
                if let last = voice.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
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
            Text(voice.status).font(.footnote).foregroundColor(.secondary)
            Button { voice.toggle() } label: {
                Image(systemName: voice.running ? "stop.fill" : "mic.fill")
                    .font(.system(size: 34))
                    .foregroundColor(.white)
                    .frame(width: 84, height: 84)
                    .background(voice.running ? Color.red : Color.green)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.red.opacity(0.3), lineWidth: voice.talking ? 10 : 0))
            }
        }
        .padding(.vertical, 12)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var voice: Voice
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
                Section("مفتاح OpenAI") {
                    SecureField("sk-...", text: $settings.key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .environment(\.layoutDirection, .leftToRight)
                    TextField("gpt-realtime-2.1", text: $settings.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .environment(\.layoutDirection, .leftToRight)
                    Text("المفتاح بيتحفظ بالـKeychain على التليفون وما بيتبعت إلا لـOpenAI.")
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
                    Toggle("أنا لابس سماعات (يسمع وهو عم يحكي)", isOn: $settings.headphones)
                }
                Section("كلمات مهمة") {
                    TextField("أسماء، بضاعة، مصطلحات", text: $settings.glossary, axis: .vertical)
                    Button("تطبيق") { voice.refreshInstructions() }
                }
                Section {
                    Button("مسح المحادثة") { voice.clear() }
                }
            }
            .navigationTitle("الإعدادات")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } } }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
}
