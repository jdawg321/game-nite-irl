import MapKit
import SwiftUI

/// The in-game screen: phase + timer, a map showing only what your role may see,
/// your clue, and the find flow (seekers) or find confirmations (hiding group).
struct LiveGameView: View {
    let game: Game
    @Environment(AppState.self) private var app
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    private var live: LiveGameStore { app.live }
    private var clue: Clue? { live.clue }
    private var hiding: Bool { clue?.mode == "hiding" || (clue == nil && app.myRole == .hider) }
    private var paused: Bool { game.status == .paused }

    var body: some View {
        ZStack {
            map
                .ignoresSafeArea(edges: .top)
            VStack(spacing: 10) {
                PhaseHeader(game: game, hiding: hiding)
                if !app.location.canTrack { LocationNeededCard() }
                if live.outOfBounds && !paused {
                    Banner(icon: "exclamationmark.triangle.fill", text: "You're outside the game area. Head back toward the start.", tint: Theme.warn)
                }
                Spacer()
                bottomPanel
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            if paused { PausedOverlay(game: game) }
        }
        .background(Theme.bg)
    }

    // MARK: Map

    private var map: some View {
        Map(position: $camera) {
            if let lat = game.startLat, let lng = game.startLng {
                let start = CLLocationCoordinate2D(latitude: lat, longitude: lng)
                MapCircle(center: start, radius: CLLocationDistance(game.boundaryM ?? 600))
                    .foregroundStyle(Theme.neon.opacity(0.05))
                    .stroke(Theme.neon.opacity(0.7), lineWidth: 2)
                Annotation("Start", coordinate: start) {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.ctaInk)
                        .padding(6)
                        .background(Theme.neon, in: Circle())
                }
            }
            if let c = clue, c.mode == "area", let lat = c.lat, let lng = c.lng {
                MapCircle(center: .init(latitude: lat, longitude: lng), radius: c.radiusM ?? 60)
                    .foregroundStyle(Color.white.opacity(0.16))
                    .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            }
            ForEach(live.positions.filter { $0.grp != "me" }) { p in
                Annotation(p.displayName ?? "", coordinate: .init(latitude: p.lat, longitude: p.lng)) {
                    PlayerDot(group: p.grp, stale: p.stale)
                }
            }
            UserAnnotation()
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls { MapUserLocationButton(); MapCompass() }
    }

    // MARK: Bottom panel

    @ViewBuilder
    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hiding {
                hidingPanel
            } else {
                seekerPanel
            }
            if let last = live.lastReportAt {
                Text("Location shared \(last.formatted(.relative(presentation: .numeric)))")
                    .font(.caption2).foregroundStyle(Theme.muted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }

    @ViewBuilder
    private var hidingPanel: some View {
        if live.toConfirm.isEmpty {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.myRole == .hider ? "You're hiding" : "You're in the hiding group")
                        .font(.headline)
                    Text("Stay together and keep quiet. When a seeker reaches you, they tap \u{201C}I found them\u{201D} and you confirm here.")
                        .font(.footnote).foregroundStyle(Theme.muted)
                }
            } icon: {
                Image(systemName: "fish.fill").foregroundStyle(Theme.neon)
            }
        }
        ForEach(live.toConfirm) { f in
            VStack(alignment: .leading, spacing: 10) {
                Text("\(f.seekerName) says they found you.")
                    .font(.headline)
                Text("Are they here with the group?")
                    .font(.footnote).foregroundStyle(Theme.muted)
                HStack(spacing: 10) {
                    Button("Not here") { Task { await live.confirm(f, here: false) } }
                        .buttonStyle(.secondary)
                    Button("Yes, they're here") { Task { await live.confirm(f, here: true) } }
                        .buttonStyle(.cta)
                }
            }
        }
    }

    @ViewBuilder
    private var seekerPanel: some View {
        let seeking = ["proximity", "area", "periodic_hidden", "no_signal"].contains(clue?.mode ?? "")
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: "Your clue")
            Text(clueText).font(.headline)
        }
        if let find = live.myFind, find.status == .confirming || find.status == .review {
            Label(find.status == .confirming ? "Waiting for the hiding group to confirm…" : "The organizer is checking your find.",
                  systemImage: "hourglass")
                .font(.footnote).foregroundStyle(Theme.neon)
        } else if let msg = live.findMessage {
            Text(msg).font(.footnote).foregroundStyle(Theme.muted)
        }
        Button(live.findBusy ? "Checking…" : "I found them") { Task { await live.requestFind() } }
            .buttonStyle(.cta)
            .disabled(!seeking || live.findBusy || [.confirming, .review].contains(live.myFind?.status ?? .verified))
    }

    private var clueText: String {
        guard let c = clue else { return "Loading…" }
        switch c.mode {
        case "countdown": return "Get ready. The game is about to start."
        case "head_start": return "Head start. Wait at the start point until seeking begins."
        case "proximity": return c.bandText
        case "area": return "The hiding group is somewhere in the shaded circle."
        case "periodic_hidden": return "Hiding area shows again in \(c.nextInS ?? 0) s."
        case "no_signal": return "No recent location from the hiding group yet."
        default: return "…"
        }
    }
}

// MARK: - Pieces

struct PhaseHeader: View {
    let game: Game
    let hiding: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let (label, target) = phase(at: ctx.date)
            HStack(spacing: 10) {
                Pill(text: hiding ? "Hiding" : "Seeking", tint: hiding ? Theme.cta : Theme.neon, filled: true)
                Text(label).font(.subheadline.weight(.semibold))
                Spacer()
                if let target {
                    Text(Self.clock(target.timeIntervalSince(ctx.date)))
                        .font(.system(size: 20, weight: .black, design: .monospaced))
                        .foregroundStyle(Theme.neon)
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
        }
    }

    private func phase(at now: Date) -> (String, Date?) {
        switch game.status {
        case .preparing: return ("Starting…", game.seekStartsAt.map { _ in (game.startedAt ?? now).addingTimeInterval(10) })
        case .paused: return ("Paused", nil)
        case .active:
            if let s = game.seekStartsAt, now < s { return (hiding ? "Hide! Seekers leave in" : "Head start", s) }
            return ("Time left", game.endsAt)
        default: return ("", nil)
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct PlayerDot: View {
    let group: String
    let stale: Bool

    var body: some View {
        Circle()
            .fill(stale ? Theme.muted : (group == "hiding" ? Theme.cta : Theme.neon))
            .frame(width: 16, height: 16)
            .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 3))
            .shadow(color: (group == "hiding" ? Color.white : Theme.neon).opacity(stale ? 0 : 0.7), radius: 6)
            .opacity(stale ? 0.6 : 1)
            .accessibilityLabel(stale ? "Old location" : (group == "hiding" ? "Hiding group" : "Seeker"))
    }
}

struct Banner: View {
    let icon: String
    let text: String
    var tint: Color = Theme.warn

    var body: some View {
        Label(text, systemImage: icon)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(tint)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(0.6), lineWidth: 1))
    }
}

struct LocationNeededCard: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Location is off", systemImage: "location.slash").font(.headline)
            Text("Game Nite needs your location during the game to check finds and keep you inside the game area.")
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
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct PausedOverlay: View {
    let game: Game

    var body: some View {
        let emergency = game.emergency == true
        VStack(spacing: 14) {
            Image(systemName: emergency ? "exclamationmark.octagon.fill" : "pause.circle.fill")
                .font(.system(size: 52))
            Text(emergency ? "Emergency pause" : "Game paused")
                .font(.system(size: 30, weight: .black).width(.expanded))
            Text(emergency
                 ? "Stop where you are. Stay off the street and wait for the organizer's instructions."
                 : "Hold your position. The clock is stopped and player locations are hidden.")
                .multilineTextAlignment(.center)
            if let reason = game.pauseReason, !reason.isEmpty {
                Text(reason).font(.footnote).opacity(0.85).multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(emergency ? Color.white : Theme.ink)
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(emergency ? Theme.crit : Theme.bg.opacity(0.94))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Results

struct ResultsView: View {
    let game: Game
    @Environment(AppState.self) private var app

    private var rows: [ResultRow] { app.live.results }
    private var mine: ResultRow? { rows.first { $0.userId == app.myUserId } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: game.status == .terminated ? "Game stopped" : "Game over")
                    Text(game.title).font(.system(size: 26, weight: .black).width(.expanded))
                    if let reason = game.endReason { Text(reason).font(.subheadline).foregroundStyle(Theme.muted) }
                }
                .padding(.top, 8)

                if let mine { yourResult(mine) }

                let hiders = rows.filter { $0.category == "hider" && $0.place == nil }
                if !hiders.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "Hiders")
                        ForEach(hiders) { r in row(r) }
                    }
                    .panel()
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Standings")
                    if rows.isEmpty {
                        Text("Results aren't available for this game.").font(.subheadline).foregroundStyle(Theme.muted)
                    }
                    ForEach(rows.filter { $0.place != nil }) { r in row(r) }
                }
                .panel()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .refreshable { await app.live.loadResults(game.id) }
    }

    private func yourResult(_ r: ResultRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "You")
            Text(r.place.map { (r.shared ? "Tied " : "") + Ordinal.string($0) } ?? "Hider")
                .font(.system(size: 44, weight: .black).width(.expanded))
                .foregroundStyle(Theme.neon)
            Text(detail(r)).font(.subheadline).foregroundStyle(Theme.muted)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glowCard()
    }

    private func row(_ r: ResultRow) -> some View {
        HStack(spacing: 10) {
            Text(r.placeText)
                .font(.system(.subheadline, design: .monospaced).weight(.bold))
                .frame(width: 38, alignment: .leading)
                .foregroundStyle(Theme.neon)
            Avatar(name: r.name, highlighted: r.userId == app.myUserId)
            Text(r.name).font(.subheadline)
            Spacer()
            Text(detail(r)).font(.caption).foregroundStyle(Theme.muted)
        }
    }

    private func detail(_ r: ResultRow) -> String {
        switch r.category {
        case "hider": return "Initial hider"
        case "found": return r.foundAt.map { "Found at \($0.formatted(date: .omitted, time: .shortened))" } ?? "Found"
        default: return r.bestDistanceM.map { "Closest: \(Int($0.rounded())) m" } ?? "No valid distance"
        }
    }
}
