import Foundation

/// Runtime configuration read from Info.plist (populated from Config/*.xcconfig).
struct AppConfig {
    let supabaseURL: URL
    let supabaseAnonKey: String
    let routingURL: URL

    static let shared = AppConfig(bundle: .main)

    init(bundle: Bundle) {
        func value(_ key: String, fallback: String) -> String {
            let v = (bundle.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            return v.isEmpty || v.hasPrefix("$(") ? fallback : v
        }
        supabaseURL = URL(string: value("SUPABASE_URL", fallback: "http://127.0.0.1:54321"))!
        supabaseAnonKey = value("SUPABASE_ANON_KEY", fallback: "")
        routingURL = URL(string: value("ROUTING_URL", fallback: "http://127.0.0.1:8787"))!
    }

    var isConfigured: Bool { !supabaseAnonKey.isEmpty }
}
