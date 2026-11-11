import SwiftUI

struct MapScreen: View {
    @ObservedObject var model: MapModel
    @EnvironmentObject var supabase: SupabaseService
    @AppStorage(Prefs.elevatorOnly) private var elevatorOnly = false
    @State private var selected: Friend?

    var body: some View {
        ZStack(alignment: .top) {
            ActiveMapView(
                people: model.people,
                route: model.routeCoordinates,
                focus: selected.map { .init(latitude: $0.lat, longitude: $0.lng) }
            )
            .ignoresSafeArea(edges: .top)

            SharingIndicator(state: supabase.sharingState)
                .padding(.top, 8)

            VStack(spacing: 10) {
                Spacer()
                if let error = model.routeError {
                    Banner(text: error, systemImage: "exclamationmark.triangle", tint: .red)
                        .accessibilityIdentifier("map.routeError")
                }
                if let r = model.route {
                    RouteCard(route: r) { model.clearRoute() }
                }
                bottomPanel
            }
            .padding()
        }
        .onChange(of: supabase.sharingState) { model.syncPause() }
    }

    @ViewBuilder private var bottomPanel: some View {
        switch model.friendsState {
        case .loading where model.friends.isEmpty:
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading who's sharing with you…")
            }
            .font(.footnote)
            .panel()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("map.loading")

        case let .failed(message) where model.friends.isEmpty:
            VStack(spacing: 8) {
                Label(message, systemImage: "wifi.exclamationmark").font(.footnote)
                Button("Try again") { Task { await model.refreshFriends() } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("map.retry")
            }
            .panel()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("map.error")

        default:
            if model.friends.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "person.2.slash").font(.title2).accessibilityHidden(true)
                    Text("Nobody is sharing with you yet.").font(.headline)
                    Text("Invite your roommate in the Sharing tab. They have to accept before you can see them.")
                        .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
                }
                .panel()
                .accessibilityElement(children: .contain)
            .accessibilityIdentifier("map.empty")
            } else {
                friendList
            }
        }
    }

    private var friendList: some View {
        VStack(spacing: 8) {
            if elevatorOnly {
                Label("Elevator-only routes are on", systemImage: "figure.roll")
                    .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("map.elevatorOnly")
            } else {
                Picker("Route", selection: $model.profile) {
                    ForEach(RouteProfile.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            ForEach(model.friends) { friend in
                HStack {
                    VStack(alignment: .leading) {
                        Text(friend.displayName).font(.headline)
                        Text(MapModel.subtitle(for: friend)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        selected = friend
                        Task { await model.routeTo(friend) }
                    } label: {
                        if model.routingTo == friend.userId {
                            ProgressView().padding(10)
                        } else {
                            Image(systemName: "figure.walk").padding(10)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.routingTo != nil)
                    .accessibilityLabel("Route to \(friend.displayName)")
                    .accessibilityIdentifier("map.route.\(friend.displayName)")
                }
            }
        }
        .panel()
    }
}

/// Always-visible pill: is my location being shared right now?
struct SharingIndicator: View {
    let state: SharingState

    var body: some View {
        Label(state.label, systemImage: state.isSharing ? "location.fill" : "location.slash")
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(state.isSharing ? .white : .primary)
            .background(state.isSharing ? Color.green : Color(.systemGray5), in: Capsule())
            .accessibilityIdentifier("sharing.indicator")
            .accessibilityLabel(state.label)
    }
}

struct Banner: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }
}

extension View {
    func panel() -> some View {
        padding()
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct RouteCard: View {
    let route: RouteResponse
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(max(1, route.route.durationS / 60)) min · \(route.route.distanceM) m")
                    .font(.headline)
                if route.route.profile == RouteProfile.avoidStairs.rawValue {
                    Label("No stairs", systemImage: "figure.roll").font(.caption)
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                    .accessibilityLabel("Close route")
            }
            if route.to.precision == "building" {
                Text("\(route.to.displayName) shares building-level location only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let indoor = route.route.indoor, !indoor.verified {
                Text("Indoor directions are unverified estimates.")
                    .font(.caption).foregroundStyle(.orange)
            }
            ForEach(Array(route.route.steps.suffix(4).enumerated()), id: \.offset) { _, step in
                Text("• \(step)").font(.caption)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("map.routeCard")
    }
}
