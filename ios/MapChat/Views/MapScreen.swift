import SwiftUI

struct MapScreen: View {
    @ObservedObject var model: MapModel
    @State private var selected: Friend?

    var body: some View {
        ZStack(alignment: .bottom) {
            ActiveMapView(
                people: model.people,
                route: model.routeCoordinates,
                focus: selected.map { .init(latitude: $0.lat, longitude: $0.lng) }
            )
            .ignoresSafeArea(edges: .top)

            VStack(spacing: 10) {
                if let error = model.error {
                    Text(error)
                        .font(.footnote)
                        .padding(8)
                        .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                }
                if let r = model.route {
                    RouteCard(route: r) { model.clearRoute() }
                }
                friendBar
            }
            .padding()
        }
    }

    @ViewBuilder private var friendBar: some View {
        if model.friends.isEmpty {
            Text("Nobody is sharing with you yet. Invite your roommate in the Sharing tab.")
                .font(.footnote)
                .padding()
                .frame(maxWidth: .infinity)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        } else {
            VStack(spacing: 8) {
                Picker("Route", selection: $model.profile) {
                    ForEach(RouteProfile.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

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
                            Label("Route to \(friend.displayName)", systemImage: "figure.walk")
                                .labelStyle(.iconOnly)
                                .padding(10)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isRouting)
                        .accessibilityLabel("Route to \(friend.displayName)")
                    }
                }
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

struct RouteCard: View {
    let route: RouteResponse
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(route.route.durationS / 60) min · \(route.route.distanceM) m")
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
    }
}
