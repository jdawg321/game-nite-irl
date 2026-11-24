import CoreImage.CIFilterBuiltins
import SwiftUI

struct GameView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Group {
            if let game = app.current {
                switch game.status {
                case .draft, .lobby: LobbyView(game: game)
                case .preparing, .active, .paused: LiveGameView(game: game)
                case .finished, .terminated: ResultsView(game: game)
                }
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "figure.walk.motion")
                        .font(.system(size: 44))
                        .foregroundStyle(Theme.neon)
                    Text("You're not in a game").font(.title3.weight(.bold))
                    Text("Pick a game night on Events, or enter the code from the organizer.")
                        .font(.subheadline).foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                    Button("Browse events") { app.selectedTab = .events }
                        .buttonStyle(.ctaCompact)
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.bg)
    }
}

struct LobbyView: View {
    let game: Game
    @Environment(AppState.self) private var app
    @State private var confirmLeave = false
    @State private var showQR = false

    private var me: Player? { app.me }
    private var players: [Player] { app.joinedRoster }
    private var readyCount: Int { players.filter(\.ready).count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Pill(text: game.status == .lobby ? "Lobby open" : "Registered", tint: game.status == .lobby ? Theme.ok : Theme.neon)
                    Text(game.title)
                        .font(.system(size: 28, weight: .black).width(.expanded))
                    Text(game.status == .lobby
                         ? "Waiting for the organizer to start. Stay near the start point."
                         : "You're on the list. The lobby opens before the game — we'll show it here.")
                        .font(.subheadline).foregroundStyle(Theme.muted)
                }
                .padding(.top, 8)

                HStack(spacing: 12) {
                    stat("\(players.count)", "joined")
                    stat("\(readyCount)", "ready")
                    stat("\(game.config.minPlayers)", "needed")
                }

                if !app.location.canTrack {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Allow location before the game starts", systemImage: "location")
                            .font(.headline)
                        Text("While a game is running, Game Nite shares your location with the game server about every 25 seconds. That's how it checks finds and keeps everyone inside the game area. It stops when the game ends.")
                            .font(.footnote).foregroundStyle(Theme.muted)
                        if app.location.isDenied {
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }
                            .buttonStyle(.secondary)
                        } else {
                            Button("Allow location") { app.location.requestPermission() }
                                .buttonStyle(.cta)
                        }
                    }
                    .panel()
                }

                if game.status == .lobby {
                    Toggle(isOn: Binding(get: { me?.ready ?? false },
                                         set: { v in Task { await app.setReady(v) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("I'm at the start point").font(.body.weight(.semibold))
                            Text("Lets the organizer know you're ready.").font(.footnote).foregroundStyle(Theme.muted)
                        }
                    }
                    .tint(Theme.neon)
                    .panel()
                }

                if game.config.method == "volunteer" {
                    Toggle(isOn: Binding(get: { me?.volunteer ?? false },
                                         set: { v in Task { await app.setVolunteer(v) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Volunteer to hide").font(.body.weight(.semibold))
                            Text("The organizer picks \(game.config.hiders) hider\(game.config.hiders == 1 ? "" : "s") from volunteers.")
                                .font(.footnote).foregroundStyle(Theme.muted)
                        }
                    }
                    .tint(Theme.neon)
                    .panel()
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Players").font(.headline)
                        Spacer()
                        Text("\(players.count)/\(game.config.capacity)")
                            .font(.system(.footnote, design: .monospaced)).foregroundStyle(Theme.muted)
                    }
                    ForEach(players) { p in
                        HStack(spacing: 10) {
                            Avatar(name: p.name, highlighted: p.userId == me?.userId)
                            Text(p.userId == me?.userId ? "\(p.name) (you)" : p.name)
                                .font(.subheadline.weight(p.userId == me?.userId ? .semibold : .regular))
                            Spacer()
                            if p.volunteer && game.config.method == "volunteer" {
                                Pill(text: "Volunteer", tint: Theme.neon)
                            }
                            Circle()
                                .fill(p.ready ? Theme.ok : Theme.line)
                                .frame(width: 9, height: 9)
                                .accessibilityLabel(p.ready ? "Ready" : "Not ready")
                        }
                    }
                }
                .panel()

                Button {
                    showQR = true
                } label: {
                    Label("Invite with code \(game.joinCode)", systemImage: "qrcode")
                }
                .buttonStyle(.secondary)

                Button("Leave game", role: .destructive) { confirmLeave = true }
                    .buttonStyle(SecondaryButtonStyle(tint: Theme.crit))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .refreshable { await app.loadCurrent() }
        .confirmationDialog("Leave \(game.title)?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave game", role: .destructive) { Task { await app.leave() } }
        }
        .sheet(isPresented: $showQR) { InviteSheet(game: game) }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 26, weight: .black, design: .rounded)).foregroundStyle(Theme.neon)
            Text(label).font(.footnote).foregroundStyle(Theme.muted)
        }
        .panel()
    }
}

struct Avatar: View {
    let name: String
    var highlighted = false

    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: 12, weight: .bold))
            .frame(width: 30, height: 30)
            .foregroundStyle(highlighted ? Theme.ctaInk : Theme.muted)
            .background(highlighted ? Theme.neon : Theme.surface2, in: Circle())
            .overlay(Circle().strokeBorder(highlighted ? Theme.neon : Theme.line, lineWidth: 1))
    }
}

struct InviteSheet: View {
    let game: Game
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let image = QRCode.image(for: "gamenite://join/\(game.joinCode)") {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(14)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                        .frame(maxWidth: 260)
                        .accessibilityLabel("QR code for game \(game.joinCode)")
                }
                Text(game.joinCode)
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.neon)
                Text("Friends can scan this or type the code on the Events tab.")
                    .font(.subheadline).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                ShareLink(item: "Join my Game Nite game with code \(game.joinCode)") {
                    Label("Share code", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.cta)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

enum QRCode {
    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
