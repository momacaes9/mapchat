import SwiftUI

@main
struct MapChatApp: App {
    @StateObject private var supabase = SupabaseService.shared
    @Environment(\.scenePhase) private var scenePhase

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

    var body: some View {
        if !AppConfig.shared.isConfigured {
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
        }
        .task { await model.start(supabase: supabase) }
        .onChange(of: scenePhase) {
            model.scenePhaseChanged(scenePhase)
        }
    }
}
