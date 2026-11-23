import SwiftUI

struct ProfileView: View {
    @Environment(AppState.self) private var app
    @State private var confirmSignOut = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Text(String((app.profile?.displayName ?? "?").prefix(1)).uppercased())
                        .font(.system(size: 26, weight: .black))
                        .foregroundStyle(Theme.ctaInk)
                        .frame(width: 60, height: 60)
                        .background(Theme.neon, in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.profile?.displayName ?? "Player")
                            .font(.system(size: 24, weight: .black).width(.expanded))
                        HStack(spacing: 6) {
                            Pill(text: "18+ verified", tint: Theme.ok)
                            if app.profile?.isOrganizer == true { Pill(text: "Organizer", tint: Theme.neon) }
                        }
                    }
                }
                .padding(.top, 12)

                Toggle(isOn: Binding(get: { app.profile?.replayConsent ?? false },
                                     set: { v in Task { await app.setReplayConsent(v) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Include me in replays").font(.body.weight(.semibold))
                        Text("Organizers can replay your path for 7 days after a game.")
                            .font(.footnote).foregroundStyle(Theme.muted)
                    }
                }
                .tint(Theme.neon)
                .panel()

                if app.profile?.isOrganizer == true {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Organizer tools").font(.headline)
                        Text("Create games, open lobbies and run games from the organizer dashboard.")
                            .font(.subheadline).foregroundStyle(Theme.muted)
                        Link(destination: AppConfig.dashboardURL) {
                            Label("Open dashboard", systemImage: "arrow.up.right.square")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.neon)
                        }
                    }
                    .panel()
                }

                VStack(alignment: .leading, spacing: 10) {
                    Link("Privacy policy", destination: AppConfig.privacyURL)
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                        .font(.footnote).foregroundStyle(Theme.muted)
                }
                .font(.subheadline.weight(.semibold))
                .tint(Theme.neon)
                .panel()

                Button("Sign out") { confirmSignOut = true }
                    .buttonStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .background(Theme.bg)
        .confirmationDialog("Sign out of Game Nite?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task { await app.signOut() } }
        }
    }
}
