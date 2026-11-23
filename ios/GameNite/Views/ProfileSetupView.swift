import SwiftUI

struct ProfileSetupView: View {
    @Environment(AppState.self) private var app
    @State private var name = ""
    @State private var isAdult = false
    @State private var agreed = false
    @State private var replay = false
    @State private var busy = false
    @FocusState private var nameFocused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var canSave: Bool { (2...24).contains(trimmed.count) && isAdult && agreed && !busy }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Almost there")
                    Text("Set up your player")
                        .font(.system(size: 30, weight: .black).width(.expanded))
                        .foregroundStyle(Theme.ink)
                }
                .padding(.top, 24)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Display name").font(.subheadline.weight(.semibold))
                    TextField("", text: $name, prompt: Text("What other players see").foregroundStyle(Theme.muted))
                        .textContentType(.nickname)
                        .focused($nameFocused)
                        .fieldStyle(focused: nameFocused)
                    Text("2–24 characters. Shown in lobbies and results.")
                        .font(.footnote).foregroundStyle(Theme.muted)
                }

                Toggle(isOn: $isAdult) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("I'm 18 or older").font(.body.weight(.semibold))
                        Text("Game Nite events are for adults only.").font(.footnote).foregroundStyle(Theme.muted)
                    }
                }
                .tint(Theme.neon)
                .panel()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Safety rules").font(.headline)
                    ForEach(SafetyRules.all, id: \.self) { rule in
                        Label(rule, systemImage: "checkmark.shield")
                            .font(.subheadline)
                            .foregroundStyle(Theme.ink)
                            .labelStyle(RuleLabelStyle())
                    }
                    Toggle("I agree to follow these rules", isOn: $agreed)
                        .font(.body.weight(.semibold))
                        .tint(Theme.neon)
                        .padding(.top, 4)
                }
                .panel()

                Toggle(isOn: $replay) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Include me in replays").font(.body.weight(.semibold))
                        Text("Optional. Organizers can replay your path after a game. Replays are deleted after 7 days. You can change this any time.")
                            .font(.footnote).foregroundStyle(Theme.muted)
                    }
                }
                .tint(Theme.neon)
                .panel()

                Button(busy ? "Saving…" : "Continue") {
                    Task {
                        busy = true
                        _ = await app.saveProfile(name: trimmed, isAdult: isAdult, replayConsent: replay)
                        busy = false
                    }
                }
                .buttonStyle(.cta)
                .disabled(!canSave)

                Button("Sign out") { Task { await app.signOut() } }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.bg)
        .onAppear {
            if let p = app.profile {
                name = p.displayName ?? ""
                isAdult = p.isAdult
                agreed = p.rulesAckAt != nil
                replay = p.replayConsent
            }
        }
    }
}

enum SafetyRules {
    static let all = [
        "Stay on public property inside the game boundary.",
        "Never enter roads, private yards or closed buildings to hide or seek.",
        "Walk, don't run, near traffic. Obey every crossing signal.",
        "Stop immediately if the organizer pauses or ends the game.",
        "Report anything unsafe with the in-app incident button.",
    ]
}

struct RuleLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.foregroundStyle(Theme.neon)
            configuration.title
        }
    }
}
