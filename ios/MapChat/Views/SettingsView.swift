import SwiftUI

/// User preferences stored on the device.
enum Prefs {
    static let elevatorOnly = "elevatorOnlyRoutes"
    static let onboardingDone = "onboardingDone"
}

struct SettingsView: View {
    @EnvironmentObject var supabase: SupabaseService
    @AppStorage(Prefs.elevatorOnly) private var elevatorOnly = false
    @AppStorage(Prefs.onboardingDone) private var onboardingDone = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Elevator-only routes", isOn: $elevatorOnly)
                        .accessibilityIdentifier("settings.elevatorOnly")
                } header: {
                    Text("Accessibility")
                } footer: {
                    Text("Routes never use stairs or stepped entrances, and use elevators to change floors. Indoor maps are still unverified, so check with the building if access matters.")
                }

                Section("Account") {
                    if let email = supabase.email { LabeledContent("Signed in as", value: email) }
                    Button("Show the privacy introduction again") { onboardingDone = false }
                    Button("Sign out", role: .destructive) { Task { await supabase.signOut() } }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
