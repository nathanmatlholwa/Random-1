import SwiftUI

struct AuthView: View {
    @EnvironmentObject var app: AppModel
    @State private var email = ""
    @State private var password = ""
    @State private var creating = false
    @State private var busy = false
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(creating ? .newPassword : .password)
                } footer: {
                    if creating { Text("At least 6 characters. Your papers and progress are saved to your own private account.") }
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Text(creating ? "Create account" : "Sign in").bold()
                            if busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(busy || email.isEmpty || password.count < 6)
                    Button(creating ? "I already have an account" : "Create a new account") {
                        creating.toggle()
                        message = nil
                    }
                }

                if let message {
                    Section {
                        Text(message).foregroundStyle(isError ? Theme.fail : Theme.pass)
                    }
                }
            }
            .navigationTitle("Maths to Failure")
        }
    }

    private func submit() async {
        busy = true
        defer { busy = false }
        let mail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if creating {
                let signedIn = try await app.signUp(email: mail, password: password)
                if !signedIn {
                    isError = false
                    message = "Check your email and tap the confirmation link, then come back and sign in."
                    creating = false
                }
            } else {
                try await app.signIn(email: mail, password: password)
            }
        } catch {
            isError = true
            message = error.localizedDescription
        }
    }
}
