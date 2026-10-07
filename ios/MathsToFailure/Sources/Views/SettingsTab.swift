import SwiftUI

struct SettingsTab: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    if let email = app.email { LabeledContent("Signed in as", value: email) }
                    Button("Sign out", role: .destructive) { Task { await app.signOut() } }
                }

                Section {
                    ForEach(Provider.allCases) { p in KeyRow(provider: p) }
                } header: {
                    Text("API keys")
                } footer: {
                    Text("Keys are stored in this device's Keychain. They are never sent to Supabase or anywhere except the provider they belong to, and they do not sync to your other devices, so enter them on each one.")
                }

                Section {
                    ForEach(Role.allCases) { role in RoleRow(role: role) }
                } header: {
                    Text("Models for each job")
                } footer: {
                    Text("Each job can use a different model. If the chosen provider has no key but the other one does, the other provider's default model is used. Model names change over time, so type any model id the provider lists.")
                }

                Section {
                    Toggle("Check new questions by solving them twice", isOn: Binding(
                        get: { app.settings.verify },
                        set: { v in app.updateSettings { $0.verify = v } }
                    ))
                } footer: {
                    Text("Slower and costs more, but catches questions whose memorandum is wrong. Best when checking uses a different model family from writing.")
                }

                Section("About") {
                    Text("Marking is done by an AI reading your handwriting and can be wrong. Use the disagree button when a mark looks off. Each marked question sends your working to the provider you chose, and costs a small amount on your API account.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

private struct KeyRow: View {
    let provider: Provider
    @State private var input = ""
    @State private var saved: Bool
    @State private var last4 = ""
    @State private var testing = false
    @State private var result: String?
    @State private var resultOK = false
    @EnvironmentObject var app: AppModel

    init(provider: Provider) {
        self.provider = provider
        _saved = State(initialValue: LLMService.hasKey(provider))
        let existing = KeychainStore.get(provider.keyAccount) ?? ""
        _last4 = State(initialValue: String(existing.suffix(4)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(provider.title) API key").font(.headline)
            if saved {
                HStack {
                    Image(systemName: "lock.fill").foregroundStyle(Theme.pass)
                    Text("Saved, ending \(last4)")
                    Spacer()
                    Button("Remove", role: .destructive) { remove() }.buttonStyle(.bordered)
                }
            }
            SecureField(saved ? "Paste a new key to replace it" : provider.keyPrefixHint, text: $input)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.password)
            HStack {
                Button("Save key") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button {
                    Task { await test() }
                } label: {
                    if testing { ProgressView() } else { Text("Test") }
                }
                .buttonStyle(.bordered)
                .disabled(!saved || testing)
            }
            if let result {
                Text(result).font(.footnote).foregroundStyle(resultOK ? Theme.pass : Theme.fail)
            }
            Text("Get a key at \(provider.consoleHint).").font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func save() {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try KeychainStore.set(key, for: provider.keyAccount)
            saved = true
            last4 = String(key.suffix(4))
            input = ""
            result = nil
        } catch {
            resultOK = false
            result = error.localizedDescription
        }
    }

    private func remove() {
        KeychainStore.delete(provider.keyAccount)
        saved = false
        last4 = ""
        result = nil
    }

    private func test() async {
        testing = true
        defer { testing = false }
        let choice = ModelChoice(provider: provider, model: ModelCatalog.defaultModel(for: provider))
        do {
            let reply = try await app.llm.complete(choice, system: "Reply with the JSON object {\"ok\":true} and nothing else.",
                                                   parts: [.text("ping")], maxTokens: 50)
            resultOK = reply.contains("ok")
            result = resultOK ? "Connected." : "Connected, but the reply was unexpected."
        } catch {
            resultOK = false
            result = error.localizedDescription
        }
    }
}

private struct RoleRow: View {
    let role: Role
    @EnvironmentObject var app: AppModel

    private var choice: ModelChoice { app.settings.choice(for: role) }

    private func save(_ c: ModelChoice) {
        app.updateSettings { $0.roles[role.rawValue] = c }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(role.title).font(.headline)
            Text(role.detail).font(.footnote).foregroundStyle(.secondary)
            Picker("Provider", selection: Binding(
                get: { choice.provider },
                set: { p in save(ModelChoice(provider: p, model: ModelCatalog.defaultModel(for: p))) }
            )) {
                ForEach(Provider.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                TextField("Model id", text: Binding(
                    get: { choice.model },
                    set: { m in save(ModelChoice(provider: choice.provider, model: m)) }
                ))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())
                Menu("Suggested") {
                    ForEach(ModelCatalog.options(for: choice.provider)) { option in
                        Button(option.label) { save(ModelChoice(provider: choice.provider, model: option.id)) }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
