import SwiftUI

/// Launch arguments used by UI tests and demos:
///   -mockBackend        in-memory backend, signed in, roommate "Ana" sharing
///   -resetOnboarding    show the privacy onboarding again
///   -skipOnboarding     mark onboarding as done
///   -mockFriendsError   make the mock friends request fail
///   -resetPrefs         clear device preferences (e.g. elevator-only)
enum LaunchArgs {
    static let args = ProcessInfo.processInfo.arguments
    static var mockBackend: Bool { args.contains("-mockBackend") }
}

@main
struct MapChatApp: App {
    @StateObject private var supabase: SupabaseService

    init() {
        if LaunchArgs.args.contains("-resetOnboarding") {
            UserDefaults.standard.set(false, forKey: Prefs.onboardingDone)
        }
        if LaunchArgs.args.contains("-resetPrefs") {
            UserDefaults.standard.removeObject(forKey: Prefs.elevatorOnly)
        }
        if LaunchArgs.args.contains("-skipOnboarding") {
            UserDefaults.standard.set(true, forKey: Prefs.onboardingDone)
        }
        _supabase = StateObject(wrappedValue: LaunchArgs.mockBackend ? MockSupabaseService() : SupabaseService.shared)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(supabase)
                .onOpenURL { url in Task { await supabase.handle(url: url) } }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var supabase: SupabaseService
    @AppStorage(Prefs.onboardingDone) private var onboardingDone = false

    var body: some View {
        if !onboardingDone {
            OnboardingView { onboardingDone = true }
        } else if !AppConfig.shared.isConfigured && !LaunchArgs.mockBackend {
            ContentUnavailableView(
                "Not configured",
                systemImage: "gearshape",
                description: Text("Copy ios/Config/Secrets.example.xcconfig to Secrets.xcconfig and set SUPABASE_ANON_KEY (from `supabase status`).")
            )
        } else if supabase.userId == nil {
            SignInView()
        } else {
            MainTabs()
        }
    }
}

struct MainTabs: View {
    @EnvironmentObject var supabase: SupabaseService
    @StateObject private var model = MapModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            MapScreen(model: model)
                .tabItem { Label("Map", systemImage: "map") }
            SharingView()
                .tabItem { Label("Sharing", systemImage: "person.2") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .task { await model.start(supabase: supabase) }
        .onChange(of: scenePhase) {
            model.scenePhaseChanged(scenePhase)
        }
    }
}
