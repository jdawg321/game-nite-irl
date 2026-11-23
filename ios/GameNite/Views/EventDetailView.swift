import SwiftUI

struct EventDetailView: View {
    let game: Game
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false

    private var alreadyIn: Bool { app.current?.id == game.id }
    private var inOtherGame: Bool { app.current != nil && !alreadyIn && !(app.current?.status.isOver ?? true) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SardineBanner()
                        .frame(height: 110)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                    VStack(alignment: .leading, spacing: 6) {
                        Pill(text: game.status.label, tint: game.status == .lobby ? Theme.ok : Theme.muted)
                        Text(game.title)
                            .font(.system(size: 28, weight: .black).width(.expanded))
                        Label(game.whenText, systemImage: "calendar")
                        Label(game.locationName.isEmpty ? "Location TBA" : game.locationName, systemImage: "mappin.and.ellipse")
                        Label("Code \(game.joinCode)", systemImage: "number")
                            .font(.system(.subheadline, design: .monospaced))
                    }
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("How this game works").font(.headline)
                        RulesSummary(config: game.config)
                    }
                    .panel()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Safety rules").font(.headline)
                        ForEach(SafetyRules.all, id: \.self) { rule in
                            Label(rule, systemImage: "checkmark.shield")
                                .font(.subheadline)
                                .labelStyle(RuleLabelStyle())
                        }
                    }
                    .panel()
                }
                .padding(20)
            }
            .background(Theme.bg)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if alreadyIn {
                        Button("Go to game") { app.selectedTab = .game; dismiss() }
                            .buttonStyle(.cta)
                    } else if inOtherGame {
                        Text("Leave your current game before joining another.")
                            .font(.footnote).foregroundStyle(Theme.muted)
                    } else if game.status.isJoinable {
                        Button(busy ? "Joining…" : "Join game") {
                            Task {
                                busy = true
                                if await app.join(code: game.joinCode) { dismiss() }
                                busy = false
                            }
                        }
                        .buttonStyle(.cta)
                        .disabled(busy)
                    } else {
                        Text("This game has already started.")
                            .font(.footnote).foregroundStyle(Theme.muted)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
    }
}

struct RulesSummary: View {
    let config: GameConfig

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
            row("Hiders", "\(config.hiders) · \(config.hiderMethodText)")
            row("Head start", config.headStart ? "\(config.headStartMin) min" : "None")
            row("Game ends", "Everyone finds the group, or \(config.durationMin) min")
            row("Clues", config.revealText)
            row("A find counts", "GPS within \(config.threshold) m + a hider confirms")
            row("Players", "\(config.minPlayers)–\(config.capacity)")
        }
        .font(.subheadline)
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(Theme.muted)
            Text(v).foregroundStyle(Theme.ink)
        }
    }
}
