import SwiftUI

@MainActor
final class SettingsForm: ObservableObject {
    @Published var openAIKey: String
    @Published var thingsToken: String
    @Published var error: String?

    init(credentials: Credentials?, error: String?) {
        openAIKey = credentials?.openAIKey ?? ""
        thingsToken = credentials?.thingsToken ?? ""
        self.error = error
    }
}

struct SettingsView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var form: SettingsForm
    let saveCredentials: (Credentials) throws -> Void
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
                Text("Ajustes")
                    .font(.system(size: 23, weight: .bold))
            }

            VStack(alignment: .leading, spacing: 14) {
                field("Chave da API da OpenAI", placeholder: "sk-…", value: $form.openAIKey,
                      help: "Durante a captura, o Ramble envia áudio e texto à OpenAI para detectar tarefas.")

                Rectangle().fill(palette.line).frame(height: 1)

                field("Token de URL do Things 3", placeholder: "Cole o token do Things", value: $form.thingsToken,
                      help: "No Things, abra Ajustes → Geral → Ativar URLs do Things → Gerenciar.")
            }
            .padding(14)
            .background(palette.inset, in: RoundedRectangle(cornerRadius: 12))

            if let error = form.error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Label("Salvos nas Chaves do macOS", systemImage: "lock")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: save) {
                    Text("Salvar")
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
