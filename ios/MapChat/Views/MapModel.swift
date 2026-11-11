import CoreLocation
import SwiftUI

/// State for the map screen: my position, friends, and the current route.
@MainActor
final class MapModel: ObservableObject {
    enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var friends: [Friend] = []
    @Published private(set) var friendsState: LoadState = .loading
    @Published private(set) var route: RouteResponse?
    @Published private(set) var routeCoordinates: [CLLocationCoordinate2D] = []
    @Published var profile: RouteProfile = .avoidStairs
    @Published var routeError: String?
    @Published private(set) var routingTo: UUID?

    private(set) var reporter: LocationReporter?
    private var supabase: SupabaseService?
    private var pollTask: Task<Void, Never>?

    /// Accessibility preference: when on, every route is stair-free.
    var elevatorOnly: Bool { UserDefaults.standard.bool(forKey: Prefs.elevatorOnly) }
    var effectiveProfile: RouteProfile { elevatorOnly ? .avoidStairs : profile }

    func start(supabase: SupabaseService) async {
        guard self.supabase == nil else { return }
        self.supabase = supabase

        let reporter = LocationReporter { loc, relAlt, pressure in
            try? await supabase.upload(
                lat: loc.coordinate.latitude, lng: loc.coordinate.longitude,
                accuracy: loc.horizontalAccuracy, appleFloor: loc.floor?.level,
                relAltitude: relAlt, pressureKPa: pressure, at: loc.timestamp
            )
        }
        self.reporter = reporter
        // The mock backend (UI tests/demos) never triggers system permission prompts.
        if !LaunchArgs.mockBackend { reporter.requestPermission() }

        await refreshFriends()
        try? await supabase.refreshSharingState()
        reporter.isSharingPaused = supabase.sharingState.globallyPaused

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
        if friends.isEmpty { friendsState = .loading }
        do {
            friends = try await supabase.friends()
            friendsState = .loaded
        } catch {
            friendsState = .failed(Self.friendly(error))
        }
    }

    func syncPause() {
        reporter?.isSharingPaused = supabase?.sharingState.globallyPaused ?? false
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

    static func subtitle(for f: Friend, now: Date = Date()) -> String {
        var parts: [String] = []
        if let place = f.placeName { parts.append(place) }
        if let floor = f.floor { parts.append("floor \(floor)") }
        let mins = Int(now.timeIntervalSince(f.recordedAt) / 60)
        parts.append(mins < 1 ? "just now" : "\(mins) min ago")
        return parts.joined(separator: " · ")
    }

    nonisolated static func friendly(_ error: Error) -> String {
        if let e = error as? RouteError { return e.errorDescription ?? "Something went wrong." }
        if (error as? URLError)?.code == .notConnectedToInternet || (error as? URLError)?.code == .cannotConnectToHost {
            return "Can't reach MapChat. Check your connection."
        }
        return "Something went wrong. Pull to retry."
    }

    func routeTo(_ friend: Friend) async {
        guard let supabase else { return }
        routingTo = friend.userId
        defer { routingTo = nil }
        do {
            let from = reporter?.lastLocation?.coordinate
            let r = try await supabase.route(to: friend.userId, profile: effectiveProfile, from: from)
            route = r
            routeCoordinates = Polyline.decode(r.route.shape)
            routeError = nil
        } catch {
            route = nil
            routeCoordinates = []
            routeError = Self.friendly(error)
        }
    }

    func clearRoute() {
        route = nil
        routeCoordinates = []
    }
}
