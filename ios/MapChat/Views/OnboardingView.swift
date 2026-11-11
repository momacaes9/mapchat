import SwiftUI

/// First-run explanation of privacy and consent. Finishing it requires an
/// explicit "I understand" so nobody starts sharing without knowing how it works.
struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var page = 0
    @State private var understood = false

    private struct Page {
        let icon: String
        let title: String
        let body: [String]
    }

    private let pages: [Page] = [
        Page(icon: "map", title: "Find your roommate, stair-free",
             body: ["MapChat shows you and the people who chose to share with you on one map.",
                    "It can draw a walking route that avoids stairs, including which elevator and floor."]),
        Page(icon: "hand.raised", title: "Nobody sees you unless you say so",
             body: ["You decide who can see you, one person at a time.",
                    "Choose exact location or building only, and whether to show your floor.",
                    "Pause or stop sharing at any time. It takes effect immediately."]),
        Page(icon: "lock.shield", title: "What we keep, and for how long",
             body: ["Your location history is deleted after 7 days.",
                    "If someone sets an arrival alert about you, you can see it and delete it.",
                    "MapChat never reads Find My or your messages."]),
        Page(icon: "location", title: "Permissions",
             body: ["Location: to show you on the map and, only if you share, to keep your position fresh for the people you approved.",
                    "Motion & Fitness: the barometer estimates your floor inside buildings.",
                    "You can change both any time in iOS Settings."]),
    ]

    var body: some View {
        VStack(spacing: 24) {
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { i in
                    VStack(spacing: 18) {
                        Image(systemName: pages[i].icon)
                            .font(.system(size: 56))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text(pages[i].title)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(pages[i].body, id: \.self) { line in
                                Label(line, systemImage: "checkmark.circle")
                                    .labelStyle(.titleAndIcon)
                            }
                        }
                        .font(.body)
                    }
                    .padding(.horizontal, 28)
                    .tag(i)
                    .accessibilityIdentifier("onboarding.page.\(i)")
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            if page == pages.count - 1 {
                Toggle("I understand how sharing works and that I can stop it at any time.", isOn: $understood)
                    .padding(.horizontal, 28)
                    .accessibilityIdentifier("onboarding.consent")
                Button("Get started", action: onFinish)
                    .buttonStyle(.borderedProminent)
                    .disabled(!understood)
                    .accessibilityIdentifier("onboarding.finish")
            } else {
                Button("Continue") { withAnimation { page += 1 } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("onboarding.next")
            }
        }
        .padding(.bottom, 32)
    }
}
