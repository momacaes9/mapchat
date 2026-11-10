import CoreLocation
import SwiftUI

/// State for the map screen: my position, friends, and the current route.
@MainActor
final class MapModel: ObservableObject {
    @Published private(set) var friends: [Friend] = []
    @Published private(set) var route: RouteResponse?
    @Published private(set) var routeCoordinates: [CLLocationCoordinate2D] = []
    @Published var profile: RouteProfile = .avoidStairs
    @Published var error: String?
    @Published var isRouting = false

    private(set) var reporter: LocationReporter?
    private var supabase: SupabaseService?
    private var routeClient: RouteClient?
    private var pollTask: Task<Void, Never>?

    func start(supabase: SupabaseService) async {
        guard self.supabase == nil else { return }
        self.supabase = supabase
        routeClient = RouteClient(baseURL: supabase.config.routingURL) { try await supabase.accessToken() }

        let reporter = LocationReporter { loc, relAlt, pressure in
            let floor = loc.floor?.level
            try? await supabase.upload(
                lat: loc.coordinate.latitude, lng: loc.coordinate.longitude,
                accuracy: loc.horizontalAccuracy, appleFloor: floor,
                relAltitude: relAlt, pressureKPa: pressure, at: loc.timestamp
            )
        }
        self.reporter = reporter
        reporter.requestPermission()

        await refreshFriends()
        // Live: a private Realtime ping tells us a friend moved; we refetch
        // through visible_friends() so precision rules always apply.
        await supabase.startFriendUpdates { [weak self] in
            Task { await self?.refreshFriends() }
        }
        // Safety net in case the socket drops: refresh every 60 s.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.refreshFriends()
            }
        }
    }

    func refreshFriends() async {
        guard let supabase else { return }
        do {
            friends = try await supabase.friends()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active: reporter?.configureForeground(); Task { await refreshFriends() }
        case .background: reporter?.configureBackground()
        default: break
        }
    }

    var people: [MapPerson] {
        var list = friends.map { f in
            MapPerson(
                id: f.userId, name: f.displayName,
                coordinate: CLLocationCoordinate2D(latitude: f.lat, longitude: f.lng),
                isMe: false, isApproximate: f.sharePrecision == "building",
                subtitle: Self.subtitle(for: f)
            )
        }
        if let me = reporter?.lastLocation {
            list.append(MapPerson(id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, name: "Me",
                                  coordinate: me.coordinate, isMe: true, isApproximate: false, subtitle: nil))
        }
        return list
    }

    static func subtitle(for f: Friend) -> String {
        var parts: [String] = []
        if let place = f.placeName { parts.append(place) }
        if let floor = f.floor { parts.append("floor \(floor)") }
        let mins = Int(Date().timeIntervalSince(f.recordedAt) / 60)
        parts.append(mins < 1 ? "just now" : "\(mins) min ago")
        return parts.joined(separator: " · ")
    }

    func routeTo(_ friend: Friend) async {
        guard let routeClient else { return }
        isRouting = true
        defer { isRouting = false }
        do {
            let r = try await routeClient.route(to: friend.userId, profile: profile, from: reporter?.lastLocation?.coordinate)
            route = r
            routeCoordinates = Polyline.decode(r.route.shape)
            error = nil
        } catch {
            route = nil
            routeCoordinates = []
            self.error = error.localizedDescription
        }
    }

    func clearRoute() {
        route = nil
        routeCoordinates = []
    }
}
