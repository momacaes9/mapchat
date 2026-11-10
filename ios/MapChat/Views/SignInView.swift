import SwiftUI

/// Email sign-in with a one-time code (also works as a magic link).
/// Local stack: open http://127.0.0.1:54324 (Mailpit) to read the email.
struct SignInView: View {
    @EnvironmentObject var supabase: SupabaseService
    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("you@unc.edu", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if codeSent {
                        TextField("6-digit code", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                    }
                } footer: {
                    Text(codeSent
                         ? "Enter the code from the email, or tap the link in it."
                         : "We'll email you a sign-in code. No password needed.")
                }

                Section {
                    Button(codeSent ? "Sign in" : "Send code") { Task { await submit() } }
                        .disabled(busy || !email.contains("@") || (codeSent && code.count < 6))
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("MapChat")
        }
    }

    private func submit() async {
        busy = true
        defer { busy = false }
        error = nil
        do {
            let trimmed = email.trimmingCharacters(in: .whitespaces).lowercased()
            if codeSent {
                try await supabase.verify(email: trimmed, code: code.trimmingCharacters(in: .whitespaces))
            } else {
                try await supabase.sendCode(email: trimmed)
                codeSent = true
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
