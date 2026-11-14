import SwiftUI
import Speech

enum TranscriptionProvider: String {
    case apple
    case gpt

    static let preference = "transcriptionProvider"
    static let showTranscriptPreference = "showLiveTranscript"

    static var appleAvailable: Bool {
        if #available(macOS 26, *) { return SpeechTranscriber.isAvailable }
        return false
    }

    static var defaultProvider: Self { appleAvailable ? .apple : .gpt }

    static var current: Self {
        UserDefaults.standard.string(forKey: preference).flatMap(Self.init(rawValue:)) ?? defaultProvider
    }
}

@MainActor
final class SettingsForm: ObservableObject {
    @Published var openAIKey: String
    @Published var thingsToken: String
    @Published var error: String?
    @Published var appleStatus = ""

    init(credentials: Credentials?, error: String?) {
        openAIKey = credentials?.openAIKey ?? ""
        thingsToken = credentials?.thingsToken ?? ""
        self.error = error
    }
}

struct SettingsView: View {
    @Environment(\.colorScheme) private var scheme
    @AppStorage(RambleLanguage.preference) private var language = RambleLanguage.portuguese
    @AppStorage(TranscriptionProvider.preference) private var transcriber = TranscriptionProvider.defaultProvider
    @AppStorage(TranscriptionProvider.showTranscriptPreference) private var showTranscript = true
    @AppStorage(Vocabulary.preference) private var vocabulary = ""
    @AppStorage("recordTimings") private var recordTimings = false
    @ObservedObject var form: SettingsForm
    let saveCredentials: (Credentials) throws -> Void
    let onLanguageChange: () -> Void
    let onSave: () -> Void

    var body: some View {
        let palette = RamblePalette(scheme)
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 11) {
                Image(systemName: "waveform")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(palette.blue)
                    .frame(width: 35, height: 35)
                    .background(palette.blue.opacity(0.11), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                Text(tr("Ajustes"))
                    .font(.system(size: 23, weight: .bold))
            }

            VStack(alignment: .leading, spacing: 14) {
                field(tr("Chave da API da OpenAI"), placeholder: "sk-…", value: $form.openAIKey,
                      help: tr("A OpenAI extrai as tarefas do texto. A opção GPT também envia o áudio à OpenAI."))

                Rectangle().fill(palette.line).frame(height: 1)

                field(tr("Token de URL do Things 3"), placeholder: tr("Cole o token do Things"), value: $form.thingsToken,
                      help: tr("No Things, abra Ajustes → Geral → Ativar URLs do Things → Gerenciar."))
            }
            .padding(14)
            .background(palette.inset, in: RoundedRectangle(cornerRadius: 12))

            Picker(tr("Idioma"), selection: $language) {
                ForEach(RambleLanguage.allCases, id: \.self) { option in
                    Text(option.name).tag(option)
                }
            }
            .onChange(of: language) {
                form.error = nil
                onLanguageChange()
            }

            Picker(tr("Transcrição"), selection: $transcriber) {
                Text(tr("Apple (no Mac)")).tag(TranscriptionProvider.apple)
                Text("GPT (OpenAI)").tag(TranscriptionProvider.gpt)
            }
            if transcriber == .apple {
                Text(form.appleStatus)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .task(id: language) { await updateAppleStatus() }
            }
            Toggle(tr("Mostrar transcrição ao vivo"), isOn: $showTranscript)

            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Vocabulário personalizado")).font(.system(size: 13, weight: .semibold))
                TextEditor(text: $vocabulary)
                    .font(.system(size: 13))
                    .frame(height: 65)
                    .border(palette.line)
                    .accessibilityLabel(tr("Vocabulário personalizado"))
                Text(tr("Um termo por linha, até 120 caracteres. No modo GPT, a lista vai para a OpenAI."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Toggle(tr("Registrar tempos localmente"), isOn: $recordTimings)

            if let error = form.error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Label(tr("Salvos nas Chaves do macOS"), systemImage: "lock")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: save) {
                    Text(tr("Salvar"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 17)
                        .frame(height: 31)
                        .background(RamblePalette.action, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 410)
        .background(palette.surface)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func updateAppleStatus() async {
        form.appleStatus = ""
        guard #available(macOS 26, *), SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: language.speechLocale) else {
            form.appleStatus = tr("A transcrição da Apple não está disponível para este idioma ou Mac. Escolha GPT nos Ajustes.")
            return
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let status = await AssetInventory.status(forModules: [transcriber])
        guard !Task.isCancelled else { return }
        switch status {
        case .installed: form.appleStatus = tr("Modelo da Apple instalado.")
        case .downloading: form.appleStatus = tr("Modelo da Apple em download…")
        case .supported: form.appleStatus = tr("O modelo da Apple será baixado na primeira captura neste idioma.")
        default: form.appleStatus = tr("A transcrição da Apple não está disponível para este idioma ou Mac. Escolha GPT nos Ajustes.")
        }
    }

    private func field(_ title: String, placeholder: String, value: Binding<String>, help: String) -> some View {
        let palette = RamblePalette(scheme)
        return VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 13, weight: .semibold))
            SecureField(placeholder, text: value)
                .font(.system(size: 13))
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(palette.surface, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7).strokeBorder(palette.line, lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .accessibilityLabel(title)
            Text(help)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func save() {
        do {
            try saveCredentials(Credentials(
                openAIKey: form.openAIKey.trimmingCharacters(in: .whitespacesAndNewlines),
                thingsToken: form.thingsToken.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
            onSave()
        } catch {
            form.error = error.localizedDescription
        }
    }
}
