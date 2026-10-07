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

                ModelSection()

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

/// A dropdown of known models. Models whose provider has no saved key are marked.
private struct ModelPicker: View {
    let title: String
    @Binding var selection: ModelChoice
    let custom: [ModelChoice]

    private func models(for provider: Provider) -> [ModelChoice] {
        var items = ModelCatalog.options(for: provider).map { ModelChoice(provider: provider, model: $0.id) }
        for c in custom where c.provider == provider && !items.contains(c) { items.append(c) }
        if selection.provider == provider && !items.contains(selection) { items.append(selection) }
        return items
    }

    private func label(_ c: ModelChoice) -> String {
        let known = ModelCatalog.options(for: c.provider).first(where: { $0.id == c.model })?.label ?? c.model
        return LLMService.hasKey(c.provider) ? known : known + " (no key)"
    }

    var body: some View {
        Picker(title, selection: $selection) {
            Section("Claude") {
                ForEach(models(for: .claude), id: \.self) { Text(label($0)).tag($0) }
            }
            Section("Gemini") {
                ForEach(models(for: .gemini), id: \.self) { Text(label($0)).tag($0) }
            }
        }
        .pickerStyle(.menu)
    }
}

private struct ModelSection: View {
    @EnvironmentObject var app: AppModel
    @State private var newProvider: Provider = .claude
    @State private var newID = ""

    private var custom: [ModelChoice] { app.settings.customModels }

    var body: some View {
        Section {
            ModelPicker(
                title: app.settings.useOneModel ? "Model" : "Default model",
                selection: Binding(
                    get: { app.settings.allModel },
                    set: { m in app.updateSettings { $0.allModel = m } }
                ),
                custom: custom
            )

            Toggle("Choose a different model for each job", isOn: Binding(
                get: { !app.settings.useOneModel },
                set: { perJob in
                    app.updateSettings { s in
                        s.useOneModel = !perJob
                        if perJob && s.roles.isEmpty {
                            for role in Role.allCases { s.roles[role.rawValue] = s.allModel }
                        }
                    }
                }
            ))

            if !app.settings.useOneModel {
                ForEach(Role.allCases) { role in
                    VStack(alignment: .leading, spacing: 2) {
                        ModelPicker(
                            title: role.title,
                            selection: Binding(
                                get: { app.settings.roles[role.rawValue] ?? app.settings.allModel },
                                set: { m in app.updateSettings { $0.roles[role.rawValue] = m } }
                            ),
                            custom: custom
                        )
                        Text(role.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            DisclosureGroup("Add a model that is not listed") {
                Picker("Provider", selection: $newProvider) {
                    ForEach(Provider.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField("Model id from the provider", text: $newID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                Button("Add to the lists above") {
                    let id = newID.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !id.isEmpty else { return }
                    let choice = ModelChoice(provider: newProvider, model: id)
                    app.updateSettings { s in
                        if !s.customModels.contains(choice) { s.customModels.append(choice) }
                    }
                    newID = ""
                }
                .disabled(newID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                ForEach(custom, id: \.self) { c in
                    HStack {
                        Text(c.model).font(.footnote.monospaced())
                        Spacer()
                        Text(c.provider.title).font(.caption).foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            app.updateSettings { s in s.customModels.removeAll { $0 == c } }
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                    }
                }
            }
        } header: {
            Text("Model")
        } footer: {
            Text("Pick the model the app should use. If the provider of your choice has no saved key but the other one does, the other provider's default model is used instead. With one model for every job, answer checking uses the same model that wrote the question; choose separate models if you want a different one to check.")
        }
    }
}
