import CoreLocation
import Foundation

/// In-memory backend for UI tests and offline demos (launch argument
/// `-mockBackend`). Signed in as "You", with a roommate "Ana" sharing her
/// location from Davis Library. Never touches the network.
@MainActor
final class MockSupabaseService: SupabaseService {
    private let me = UUID(uuidString: "00000000-0000-0000-0000-0000000000b2")!
    private let ana = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
    private var mockGrants: [ShareGrant] = []
    private var paused = false
    /// UI tests can force failures with `-mockFriendsError`.
    private let failFriends = ProcessInfo.processInfo.arguments.contains("-mockFriendsError")

    init() {
        super.init(config: .shared, observeAuth: false)
        userId = me
        email = "you@unc.edu"
        mockGrants = [
            // Ana shares with me (exact).
            ShareGrant(id: UUID(), ownerId: ana, viewerId: me, status: "active", precision: "exact",
                       allowFloor: true, owner: .init(displayName: "Ana"), viewer: .init(displayName: "You")),
            // I share with Ana (exact).
            ShareGrant(id: UUID(), ownerId: me, viewerId: ana, status: "active", precision: "exact",
                       allowFloor: true, owner: .init(displayName: "You"), viewer: .init(displayName: "Ana")),
        ]
    }

    override func sendCode(email: String) async throws {}
    override func verify(email: String, code: String) async throws { userId = me }
    override func handle(url: URL) async {}
    override func signOut() async { userId = nil }
    override func accessToken() async throws -> String { "mock-token" }
    override func setDisplayName(_ name: String) async throws {}

    override func friends() async throws -> [Friend] {
        try await Task.sleep(for: .milliseconds(300)) // visible loading state
        if failFriends { throw URLError(.notConnectedToInternet) }
        let anaShares = mockGrants.contains { $0.ownerId == ana && $0.status == "active" }
        guard anaShares else { return [] }
        return [Friend(userId: ana, displayName: "Ana", lat: 35.91105, lng: -79.04795, accuracyM: 5, floor: 3,
                       placeSlug: "davis-library", placeName: "Davis Library", sharePrecision: "exact",
                       recordedAt: Date().addingTimeInterval(-60))]
    }

    override func myLocation() async throws -> MyLocation? {
        MyLocation(lat: 35.90227, lng: -79.04327, floor: nil, placeSlug: "hinton-james")
    }

    override func upload(lat: Double, lng: Double, accuracy: Double?, appleFloor: Int?,
                         relAltitude: Double?, pressureKPa: Double?, at date: Date) async throws {}

    override func grants() async throws -> [ShareGrant] { mockGrants }

    override func requestShare(contact: String) async throws -> Bool { true }
    override func shareWith(contact: String, precision: String) async throws -> Bool { true }

    override func updateGrant(_ id: UUID, status: String? = nil, precision: String? = nil, allowFloor: Bool? = nil) async throws {
        guard let i = mockGrants.firstIndex(where: { $0.id == id }) else { return }
        if let status { mockGrants[i].status = status }
        if let precision { mockGrants[i].precision = precision }
        if let allowFloor { mockGrants[i].allowFloor = allowFloor }
    }

    override func deleteGrant(_ id: UUID) async throws { mockGrants.removeAll { $0.id == id } }

    override func setGlobalPause(_ paused: Bool) async throws {
        self.paused = paused
        sharingState.globallyPaused = paused
    }

    override func myProfile() async throws -> MyProfile? {
        MyProfile(display_name: "You", sharing_paused: paused)
    }

    override func route(to userId: UUID, profile: RouteProfile, from: CLLocationCoordinate2D?) async throws -> RouteResponse {
        try await Task.sleep(for: .milliseconds(400))
        let json = """
        {"to":{"user_id":"\(ana.uuidString)","display_name":"Ana","lat":35.91105,"lng":-79.04795,"floor":3,
               "place_name":"Davis Library","precision":"exact"},
         "route":{"profile":"\(profile.rawValue)","durationS":1140,"distanceM":1477,
                  "shape":"{rhncAjklwuCsiDbkBozD~{BcnDbuA",
                  "steps":["Walk north on the path.","Enter Davis Library by the main entrance (floor 1)",
                           "Take elevator A to floor 3","Arrive on floor 3"],
                  "entrance":{"id":"ent-main","label":"main entrance","lat":35.9108025,"lng":-79.0483783},
                  "indoor":{"building":"davis-library","targetFloor":3,"verified":false}}}
        """
        return try JSONCoding.decoder.decode(RouteResponse.self, from: Data(json.utf8))
    }

    override func startFriendUpdates(onPing: @escaping @MainActor () -> Void) async {}
    override func stopFriendUpdates() async {}
}
