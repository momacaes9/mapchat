import Foundation
import Supabase

/// All Supabase access for the app. Everything runs as the signed-in user, so
/// Row Level Security decides what is visible. Other people's locations are
/// only read through the `visible_friends()` RPC.
@MainActor
final class SupabaseService: ObservableObject {
    static let shared = SupabaseService(config: .shared)

    let client: SupabaseClient
    let config: AppConfig

    @Published private(set) var userId: UUID?
    @Published private(set) var email: String?

    private var friendChannel: RealtimeChannelV2?

    init(config: AppConfig) {
        self.config = config
        client = SupabaseClient(supabaseURL: config.supabaseURL, supabaseKey: config.supabaseAnonKey)
        Task { await self.observeAuth() }
    }

    // MARK: Auth (email one-time code / magic link)

    private func observeAuth() async {
        for await (_, session) in client.auth.authStateChanges {
            userId = session?.user.id
            email = session?.user.email
        }
    }

    /// Sends an email with a 6-digit code and a magic link. Locally, read it at
    /// http://127.0.0.1:54324 (Mailpit).
    func sendCode(email: String) async throws {
        try await client.auth.signInWithOTP(
            email: email,
            redirectTo: URL(string: "mapchat://login-callback"),
            shouldCreateUser: true
        )
    }

    func verify(email: String, code: String) async throws {
        try await client.auth.verifyOTP(email: email, token: code, type: .email)
    }

    /// Handles mapchat://login-callback magic links.
    func handle(url: URL) async {
        _ = try? await client.auth.session(from: url)
    }

    func signOut() async {
        await stopFriendUpdates()
        try? await client.auth.signOut()
    }

    func accessToken() async throws -> String {
        try await client.auth.session.accessToken
    }

    func setDisplayName(_ name: String) async throws {
        guard let userId else { return }
        try await client.from("profiles").update(["display_name": name]).eq("id", value: userId).execute()
    }

    // MARK: Locations

    func friends() async throws -> [Friend] {
        let data = try await client.rpc("visible_friends").execute().data
        return try JSONCoding.decoder.decode([Friend].self, from: data)
    }

    func myLocation() async throws -> MyLocation? {
        let data = try await client.rpc("my_latest_location").execute().data
        return try JSONCoding.decoder.decode([MyLocation].self, from: data).first
    }

    struct LocationUpload: Encodable {
        let user_id: UUID
        let geog: String
        let accuracy_m: Double?
        let floor_apple: Int?
        let rel_altitude_m: Double?
        let pressure_kpa: Double?
        let recorded_at: Date
    }

    func upload(lat: Double, lng: Double, accuracy: Double?, appleFloor: Int?,
                relAltitude: Double?, pressureKPa: Double?, at date: Date) async throws {
        guard let userId else { return }
        let row = LocationUpload(
            user_id: userId,
            geog: String(format: "SRID=4326;POINT(%.7f %.7f)", lng, lat),
            accuracy_m: accuracy, floor_apple: appleFloor,
            rel_altitude_m: relAltitude, pressure_kpa: pressureKPa, recorded_at: date
        )
        try await client.from("locations").insert(row).execute()
    }

    // MARK: Sharing

    func grants() async throws -> [ShareGrant] {
        let data = try await client.from("share_grants")
            .select("id, owner_id, viewer_id, status, precision, allow_floor, " +
                    "owner:profiles!share_grants_owner_id_fkey(display_name), " +
                    "viewer:profiles!share_grants_viewer_id_fkey(display_name)")
            .order("created_at", ascending: false)
            .execute().data
        return try JSONCoding.decoder.decode([ShareGrant].self, from: data)
    }

    /// Ask someone (phone or email) to share their location with me.
    func requestShare(contact: String) async throws -> Bool {
        let data = try await client.rpc("request_share", params: ["contact": contact]).execute().data
        return String(data: data, encoding: .utf8) != "null"
    }

    /// Share my location with someone (phone or email), active immediately.
    func shareWith(contact: String, precision: String) async throws -> Bool {
        let data = try await client.rpc("share_with", params: ["contact": contact, "share_precision": precision])
            .execute().data
        return String(data: data, encoding: .utf8) != "null"
    }

    /// Owner-only changes (RLS rejects them for viewers).
    func updateGrant(_ id: UUID, status: String? = nil, precision: String? = nil, allowFloor: Bool? = nil) async throws {
        struct Patch: Encodable {
            let status: String?
            let precision: String?
            let allow_floor: Bool?
        }
        try await client.from("share_grants")
            .update(Patch(status: status, precision: precision, allow_floor: allowFloor))
            .eq("id", value: id).execute()
    }

    func deleteGrant(_ id: UUID) async throws {
        try await client.from("share_grants").delete().eq("id", value: id).execute()
    }

    func setGlobalPause(_ paused: Bool) async throws {
        guard let userId else { return }
        try await client.from("profiles").update(["sharing_paused": paused]).eq("id", value: userId).execute()
    }

    // MARK: Realtime

    /// Subscribes to the private topic `friends:<my id>`. The database sends a
    /// coordinate-free ping whenever a friend moves; `onPing` should refetch
    /// visible_friends().
    func startFriendUpdates(onPing: @escaping @MainActor () -> Void) async {
        guard let userId, friendChannel == nil else { return }
        let channel = client.channel("friends:\(userId.uuidString.lowercased())") {
            $0.isPrivate = true
        }
        friendChannel = channel
        let pings = channel.broadcastStream(event: "friend_moved")
        await channel.subscribe()
        Task { @MainActor in
            for await _ in pings { onPing() }
        }
    }

    func stopFriendUpdates() async {
        if let friendChannel { await client.removeChannel(friendChannel) }
        friendChannel = nil
    }
}
