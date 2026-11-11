import SwiftUI

/// Invite, accept, pause, stop, and precision controls.
struct SharingView: View {
    @EnvironmentObject var supabase: SupabaseService
    @State private var grants: [ShareGrant] = []
    @State private var loading = true
    @State private var loadError: String?
    @State private var contact = ""
    @State private var precision = "exact"
    @State private var message: String?
    @State private var busy = false

    private var myId: UUID? { supabase.userId }
    private var sharingWithOthers: [ShareGrant] { grants.filter { $0.ownerId == myId } }
    private var othersSharing: [ShareGrant] { grants.filter { $0.viewerId == myId } }

    private var globalPause: Binding<Bool> {
        Binding(
            get: { supabase.sharingState.globallyPaused },
            set: { newValue in
                Task {
                    busy = true
                    defer { busy = false }
                    do { try await supabase.setGlobalPause(newValue) } catch { message = MapModel.friendly(error) }
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    SharingIndicator(state: supabase.sharingState)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                    Toggle("Pause all sharing", isOn: globalPause)
                        .disabled(busy)
                        .accessibilityIdentifier("sharing.pauseAll")
                } footer: {
                    Text("While paused, nobody can see your location and the app stops uploading it.")
                }

                Section("Invite (phone +1… or email)") {
                    TextField("+19195551234 or roommate@unc.edu", text: $contact)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("sharing.contact")
                    Picker("When I share, show", selection: $precision) {
                        Text("Exact location").tag("exact")
                        Text("Building only").tag("building")
                    }
                    Button("Ask them to share with me") { Task { await invite(request: true) } }
                        .disabled(contact.count < 5 || busy)
                    Button("Share my location with them") { Task { await invite(request: false) } }
                        .disabled(contact.count < 5 || busy)
                }

                if loading && grants.isEmpty {
                    Section { HStack { ProgressView(); Text("Loading…") } }
                } else if let loadError, grants.isEmpty {
                    Section {
                        Label(loadError, systemImage: "wifi.exclamationmark")
                        Button("Try again") { Task { await load() } }
                    }
                    .accessibilityIdentifier("sharing.error")
                } else {
                    Section("People who can see me") {
                        if sharingWithOthers.isEmpty {
                            Text("Nobody. Your location is private.").foregroundStyle(.secondary)
                        }
                        ForEach(sharingWithOthers) { g in ownerRow(g) }
                    }

                    Section("People sharing with me") {
                        if othersSharing.isEmpty { Text("Nobody yet").foregroundStyle(.secondary) }
                        ForEach(othersSharing) { g in
                            HStack {
                                Text(g.owner?.displayName ?? "Someone")
                                Spacer()
                                Text(g.status == "pending" ? "Waiting for them" : g.status.capitalized)
                                    .foregroundStyle(.secondary)
                            }
                            .swipeActions {
                                Button("Remove", role: .destructive) { Task { await delete(g) } }
                            }
                        }
                    }
                }

                if let message {
                    Section { Text(message).font(.footnote) }
                }
            }
            .navigationTitle("Sharing")
            .refreshable { await load() }
            .task { await load() }
        }
    }

    /// Rows for grants where I am the owner: I decide everything here.
    @ViewBuilder private func ownerRow(_ g: ShareGrant) -> some View {
        let name = g.viewer?.displayName ?? "Someone"
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(name).font(.headline)
                Spacer()
                Text(g.status.capitalized)
                    .foregroundStyle(g.status == "active" ? .green : .secondary)
                    .accessibilityIdentifier("sharing.status.\(name)")
            }
            if g.status == "pending" {
                HStack {
                    Button("Accept") { Task { await update(g, status: "active") } }.buttonStyle(.borderedProminent)
                    Button("Decline", role: .destructive) { Task { await delete(g) } }
                }
            } else if g.status != "revoked" {
                Picker("Precision", selection: Binding(
                    get: { g.precision },
                    set: { p in Task { await update(g, precision: p) } }
                )) {
                    Text("Exact").tag("exact")
                    Text("Building").tag("building")
                }
                .pickerStyle(.segmented)
                Toggle("Show my floor", isOn: Binding(
                    get: { g.allowFloor },
                    set: { v in Task { await update(g, allowFloor: v) } }
                ))
                HStack {
                    Button(g.status == "paused" ? "Resume" : "Pause") {
                        Task { await update(g, status: g.status == "paused" ? "active" : "paused") }
                    }
                    .accessibilityIdentifier("sharing.pause.\(name)")
                    Spacer()
                    Button("Stop sharing", role: .destructive) { Task { await update(g, status: "revoked") } }
                        .accessibilityIdentifier("sharing.stop.\(name)")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            grants = try await supabase.refreshSharingState()
            loadError = nil
        } catch {
            loadError = MapModel.friendly(error)
        }
    }

    private func invite(request: Bool) async {
        busy = true
        defer { busy = false }
        let c = contact.trimmingCharacters(in: .whitespaces)
        do {
            _ = request
                ? try await supabase.requestShare(contact: c)
                : try await supabase.shareWith(contact: c, precision: precision)
            // Same message whether or not the contact has an account, so the
            // app can't be used to find out who uses MapChat.
            message = "Done. If they use MapChat, they'll see it in their Sharing tab."
            contact = ""
            await load()
        } catch {
            message = MapModel.friendly(error)
        }
    }

    private func update(_ g: ShareGrant, status: String? = nil, precision: String? = nil, allowFloor: Bool? = nil) async {
        do {
            try await supabase.updateGrant(g.id, status: status, precision: precision, allowFloor: allowFloor)
            await load()
        } catch {
            message = MapModel.friendly(error)
        }
    }

    private func delete(_ g: ShareGrant) async {
        try? await supabase.deleteGrant(g.id)
        await load()
    }
}
