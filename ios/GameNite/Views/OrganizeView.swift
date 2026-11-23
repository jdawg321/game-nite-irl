import SwiftUI

/// Organizer tab: your games → a game's control screen (layout A:
/// glowing game card, Players / Rules / Log sections, fixed action bar).
struct OrganizeView: View {
    @Environment(AppState.self) private var app
    @State private var path: [UUID] = []
    @State private var creating = false

    private var store: OrganizerStore { app.organizer }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel(text: "Organizer")
                        Text("Your games")
                            .font(.system(size: 30, weight: .black).width(.expanded))
                    }
                    .padding(.top, 8)

                    Button { creating = true } label: { Label("New game", systemImage: "plus") }
                        .buttonStyle(.cta)

                    if store.games.isEmpty {
                        Text("No games yet. Create one to get a join code and QR.")
                            .font(.subheadline).foregroundStyle(Theme.muted)
                            .panel()
                    }
                    ForEach(store.games) { game in
                        NavigationLink(value: game.id) { OrganizerGameRow(game: game) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .background(Theme.bg)
            .refreshable { await reload() }
            .navigationDestination(for: UUID.self) { id in
                OrganizerGameView(gameId: id)
            }
            .sheet(isPresented: $creating) {
                NewGameView { newId in
                    creating = false
                    path = [newId]
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .task { await reload() }
    }

    private func reload() async {
        if let id = app.myUserId { await store.loadGames(organizerId: id) }
    }
}

struct OrganizerGameRow: View {
    let game: Game

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(game.title).font(.headline).foregroundStyle(Theme.ink)
                Text("\(game.joinCode) · \(game.whenText)")
                    .font(.system(.footnote, design: .monospaced)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Pill(text: game.status.label, tint: game.status.tint)
            Image(systemName: "chevron.right").font(.footnote.weight(.bold)).foregroundStyle(Theme.muted)
        }
        .panel()
    }
}

extension GameStatus {
    var tint: Color {
        switch self {
        case .lobby: Theme.ok
        case .preparing, .paused: Theme.warn
        case .active: Theme.neon
        case .terminated: Theme.crit
        default: Theme.muted
        }
    }
}

// MARK: - Game control screen (layout A)

struct OrganizerGameView: View {
    let gameId: UUID
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var section: Section = .players
    @State private var draft = GameConfig()
    @State private var showQR = false
    @State private var confirmStart = false
    @State private var terminating = false
    @State private var terminateReason = ""
    @State private var removing: Player?
    @State private var removeReason = ""

    enum Section: Hashable { case players, rules, log }

    private var store: OrganizerStore { app.organizer }
    private var game: Game? { store.selected?.id == gameId ? store.selected : nil }
    private var playing: Bool { store.isPlaying(app.myUserId) }
    private var started: Bool { !(game?.status.isJoinable ?? true) }
    /// Fair play: once a game you're playing has started, roles stay hidden here.
    private var rolesHidden: Bool { playing && started }

    var body: some View {
        Group {
            if let game {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            gameCard(game)
                            if playing { fairPlayNote }
                            Picker("Section", selection: $section) {
                                Text("Players \(store.joined.count)").tag(Section.players)
                                Text("Rules").tag(Section.rules)
                                Text("Log").tag(Section.log)
                            }
                            .pickerStyle(.segmented)

                            switch section {
                            case .players: playersSection(game)
                            case .rules: rulesSection(game)
                            case .log: logSection
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                    }
                    .refreshable { await store.loadDetail() }
                    actionBar(game)
                }
            } else {
                ProgressView().tint(Theme.neon).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.bg)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let g = store.games.first(where: { $0.id == gameId }) { await store.open(g) }
            if let g = game { draft = g.config }
        }
        .onChange(of: game?.config) { _, new in if let new { draft = new } }
        .onDisappear { Task { await store.close() } }
        .sheet(isPresented: $showQR) { if let game { InviteSheet(game: game) } }
        .confirmationDialog("Start the game now?", isPresented: $confirmStart, titleVisibility: .visible) {
            Button("Start game") { Task { await store.start() } }
        } message: {
            Text("Rules lock and roles are assigned. Players see their role right away.")
        }
        .alert("Terminate this game?", isPresented: $terminating) {
            TextField("Reason (required, logged)", text: $terminateReason)
            Button("Terminate", role: .destructive) {
                let r = terminateReason.trimmingCharacters(in: .whitespaces)
                terminateReason = ""
                if !r.isEmpty { Task { await store.terminate(reason: r) } }
            }
            Button("Cancel", role: .cancel) { terminateReason = "" }
        } message: {
            Text("Everyone's game ends immediately.")
        }
        .alert("Remove \(removing?.name ?? "player")?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            TextField("Reason (required, logged)", text: $removeReason)
            Button("Remove", role: .destructive) {
                let r = removeReason.trimmingCharacters(in: .whitespaces)
                let p = removing
                removeReason = ""
                if let p, !r.isEmpty { Task { await store.remove(p, reason: r) } }
            }
            Button("Cancel", role: .cancel) { removeReason = "" }
        } message: {
            Text("They can't rejoin this game.")
        }
    }

    // MARK: Card

    private func gameCard(_ game: Game) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Pill(text: game.status.label, tint: game.status.tint)
                    Text(game.title)
                        .font(.system(size: 22, weight: .black))
                        .foregroundStyle(Theme.ink)
                    Text("\(game.whenText)\(game.locationName.isEmpty ? "" : " · \(game.locationName)")")
                        .font(.footnote).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("CODE").font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(Theme.muted)
                    Text(game.joinCode)
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.neon)
                    Button("Show QR") { showQR = true }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.neon)
                }
            }
            StateStrip(status: game.status)
            if !playing && game.status.isJoinable {
                Button {
                    Task { await store.joinAsPlayer() }
                } label: {
                    Label("Join as player", systemImage: "figure.walk")
                }
                .buttonStyle(.secondary)
                .disabled(store.busy)
            }
        }
        .padding(14)
        .glowCard()
    }

    private var fairPlayNote: some View {
        Label {
            Text(started
                 ? "You're playing this game, so roles are hidden here. Safety controls still work."
                 : "You're playing this game. Once it starts, roles and locations are hidden here so it stays fair.")
        } icon: {
            Image(systemName: "eye.slash").foregroundStyle(Theme.neon)
        }
        .font(.footnote)
        .foregroundStyle(Theme.ink)
        .panel()
    }

    // MARK: Players

    private func playersSection(_ game: Game) -> some View {
        let ready = store.joined.filter(\.ready).count
        let manualPicking = game.config.method == "manual" && game.status.isJoinable
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(ready) ready · need \(game.config.minPlayers)")
                Spacer()
                Text("\(store.joined.count)/\(game.config.capacity)").font(.system(.footnote, design: .monospaced))
            }
            .font(.footnote).foregroundStyle(Theme.muted)
            .padding(.bottom, 6)

            if store.roster.isEmpty {
                Text("Nobody has joined yet. Show the QR at the start point or share the code.")
                    .font(.subheadline).foregroundStyle(Theme.muted)
                    .padding(.vertical, 12)
            }
            ForEach(store.roster) { p in
                HStack(spacing: 10) {
                    Avatar(name: p.name, highlighted: p.userId == app.myUserId)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.userId == app.myUserId ? "\(p.name) (you)" : p.name).font(.subheadline)
                        if p.status != .joined {
                            Text(p.status == .removed ? "Removed" : "Left").font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                    Spacer()
                    if p.volunteer && game.config.method == "volunteer" { Pill(text: "Volunteer", tint: Theme.neon) }
                    if p.status == .joined { roleBadge(for: p, manualPicking: manualPicking) }
                    Circle().fill(p.ready ? Theme.ok : Theme.line).frame(width: 9, height: 9)
                        .accessibilityLabel(p.ready ? "Ready" : "Not ready")
                    if p.status == .joined && !game.status.isOver {
                        Menu {
                            Button("Remove from game", role: .destructive) { removing = p }
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 32, height: 32)
                                .foregroundStyle(Theme.muted)
                        }
                        .accessibilityLabel("More for \(p.name)")
                    }
                }
                .padding(.vertical, 8)
                .opacity(p.status == .joined ? 1 : 0.5)
                Divider().overlay(Theme.surface2)
            }
        }
    }

    @ViewBuilder
    private func roleBadge(for p: Player, manualPicking: Bool) -> some View {
        let role = store.roles[p.userId]
        if manualPicking {
            Button(role == .hider ? "Hider ✓" : "Make hider") {
                Task { await store.setHider(p, role != .hider) }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(role == .hider ? Theme.ctaInk : Theme.neon)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(role == .hider ? Theme.neon : Theme.neonSoft, in: Capsule())
            .disabled(store.busy)
        } else if rolesHidden {
            Pill(text: "Hidden")
        } else if let role, role != .pending {
            Pill(text: role.rawValue, tint: role == .hider ? Theme.neon : Theme.muted)
        }
    }

    // MARK: Rules

    private func rulesSection(_ game: Game) -> some View {
        let locked = !game.status.isJoinable
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(locked ? "Locked when the game started" : "Editable until the game starts")
                    .font(.footnote).foregroundStyle(Theme.muted)
                Spacer()
                Pill(text: "v\(game.configVersion ?? 1)", tint: locked ? Theme.warn : Theme.muted)
            }
            RulesEditor(config: $draft).disabled(locked)
            if !locked {
                Button("Save rules") { Task { await store.saveConfig(draft) } }
                    .buttonStyle(.secondary)
                    .disabled(draft == game.config || store.busy)
            }
        }
    }

    // MARK: Log

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.audit.isEmpty {
                Text("No actions yet.").font(.subheadline).foregroundStyle(Theme.muted).padding(.vertical, 12)
            }
            ForEach(store.audit) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(entry.title).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(entry.at.formatted(date: .omitted, time: .shortened))
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                    if let reason = entry.reason {
                        Text(reason).font(.footnote).foregroundStyle(Theme.muted)
                    }
                }
                .padding(.vertical, 8)
                Divider().overlay(Theme.surface2)
            }
        }
    }

    // MARK: Action bar

    @ViewBuilder
    private func actionBar(_ game: Game) -> some View {
        if !game.status.isOver {
            HStack(spacing: 10) {
                Button("Terminate") { terminating = true }
                    .buttonStyle(SecondaryButtonStyle(fullWidth: false, tint: Theme.crit))
                switch game.status {
                case .draft:
                    Button("Open lobby") { Task { await store.openLobby() } }
                        .buttonStyle(.cta).disabled(store.busy)
                case .lobby:
                    Button(store.joined.count >= game.config.minPlayers
                           ? "Start game"
                           : "Need \(game.config.minPlayers - store.joined.count) more") { confirmStart = true }
                        .buttonStyle(.cta)
                        .disabled(store.busy || store.joined.count < game.config.minPlayers)
                default:
                    Button("Live controls arrive in Stage 2") {}
                        .buttonStyle(.cta).disabled(true)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 12)
            .background(Theme.surface)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
    }
}

struct StateStrip: View {
    let status: GameStatus
    private let shown: [GameStatus] = [.draft, .lobby, .preparing, .active, .paused, .finished]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(shown + (status == .terminated ? [.terminated] : []), id: \.self) { s in
                Text(s.rawValue)
                    .font(.system(size: 9, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .foregroundStyle(s == status ? (s == .terminated ? Color.white : Theme.ctaInk) : Theme.muted)
                    .background(s == status ? (s == .terminated ? Theme.crit : Theme.neon) : Theme.surface2,
                                in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Game state: \(status.label)")
    }
}

// MARK: - New game

struct NewGameView: View {
    let onCreated: (UUID) -> Void
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var title = "Friday Night Sardines"
    @State private var kind = "scheduled"
    @State private var startsAt = Calendar.current.date(bySettingHour: 20, minute: 0, second: 0, of: .now.addingTimeInterval(86400)) ?? .now
    @State private var location = ""
    @State private var config = GameConfig()

    private var valid: Bool { (3...60).contains(title.trimmingCharacters(in: .whitespaces).count) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Game") {
                    TextField("Title", text: $title)
                    Picker("Type", selection: $kind) {
                        Text("Scheduled").tag("scheduled")
                        Text("Instant").tag("instant")
                    }
                    if kind == "scheduled" {
                        DatePicker("Starts", selection: $startsAt, in: Date()...)
                    }
                    TextField("Location (e.g. Downtown Provo)", text: $location)
                }
                RulesEditor(config: $config)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("New game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(!valid || app.organizer.busy)
                }
            }
        }
    }

    private func create() async {
        guard let me = app.myUserId else { return }
        let ok = await app.organizer.create(
            title: title.trimmingCharacters(in: .whitespaces), kind: kind,
            startsAt: kind == "scheduled" ? startsAt : nil,
            location: location.trimmingCharacters(in: .whitespaces), config: config, organizerId: me)
        if ok, let id = app.organizer.selected?.id { onCreated(id) }
    }
}

// MARK: - Rules editor (PRD §5)

struct RulesEditor: View {
    @Binding var config: GameConfig

    var body: some View {
        Group {
            Section {
                Stepper("Initial hiders: \(config.hiders)", value: $config.hiders, in: 1...5)
                LabeledPicker("Chosen by", selection: $config.method) {
                    Text("Random").tag("random")
                    Text("Organizer picks").tag("manual")
                    Text("Volunteers").tag("volunteer")
                }
                Toggle("Head start", isOn: $config.headStart)
                if config.headStart {
                    Stepper("Head start: \(config.headStartMin) min", value: $config.headStartMin, in: 1...15)
                }
            } header: {
                SectionLabel(text: "Hiders")
            }
            Section {
                Stepper("Game length: \(config.durationMin) min", value: $config.durationMin, in: 5...120, step: 5)
                LabeledPicker("Clues", selection: $config.reveal) {
                    Text("Distance clues").tag("proximity")
                    Text("Shaded area (live)").tag("continuous")
                    Text("Shaded area (periodic)").tag("periodic")
                }
                if config.reveal == "periodic" {
                    Stepper("Reveal every \(config.revealEveryMin) min", value: $config.revealEveryMin, in: 1...10)
                }
            } header: {
                SectionLabel(text: "Timing & clues")
            }
            Section {
                Stepper("Find radius: \(config.threshold) m", value: $config.threshold, in: 5...50)
                Stepper("Worst GPS accuracy: \(config.accuracyMax) m", value: $config.accuracyMax, in: 5...50)
            } header: {
                SectionLabel(text: "Finds")
            }
            Section {
                Stepper("Capacity: \(config.capacity)", value: $config.capacity, in: 4...50)
                Stepper("Minimum players: \(config.minPlayers)", value: $config.minPlayers, in: 2...config.capacity)
                Toggle("Seekers see other seekers", isOn: $config.seekersSeeSeekers)
                Toggle("Hiding group sees seekers", isOn: $config.hidersSeeSeekers)
            } header: {
                SectionLabel(text: "Players & visibility")
            }
            Section {
                LabeledPicker("Unfinished seekers measured to", selection: $config.distRef) {
                    Text("Original hiding spot").tag("origin")
                    Text("Nearest hiding-group member").tag("nearest")
                }
                LabeledPicker("Initial hiders ranked", selection: $config.hiderRank) {
                    Text("Listed separately").tag("separate")
                    Text("Shared 1st place").tag("first")
                }
            } header: {
                SectionLabel(text: "Scoring (pilot settings)")
            }
        }
        .tint(Theme.neon)
    }
}

/// A menu picker with its label on the left, so it reads correctly inside or outside a Form.
struct LabeledPicker<Content: View>: View {
    let title: String
    @Binding var selection: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, selection: Binding<String>, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self._selection = selection
        self.content = content
    }

    var body: some View {
        LabeledContent(title) {
            Picker(title, selection: $selection, content: content)
                .pickerStyle(.menu)
                .labelsHidden()
        }
    }
}
