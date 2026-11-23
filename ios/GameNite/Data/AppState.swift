import Foundation
import Observation
import Supabase

let supabase = SupabaseClient(
    supabaseURL: AppConfig.supabaseURL,
    supabaseKey: AppConfig.supabasePublishableKey
)

/// Single source of app state. The server owns every game decision; this only
/// reads rows, calls database functions and listens for live changes.
@MainActor @Observable
final class AppState {
    enum Phase: Equatable { case loading, signedOut, needsProfile, ready }

    var phase: Phase = .loading
    var profile: Profile?
    var games: [Game] = []
    var current: Game?
    var roster: [Player] = []
    /// Your own role in the current game (roles are private to each player).
    var myRole: PlayerRole?
    var errorMessage: String?
    /// A code from a QR scan or a gamenite:// link, waiting to be shown.
    var pendingCode: String?
    var selectedTab: Tab = .events
    /// Organizer tools; only used when the profile is an organizer.
    let organizer = OrganizerStore()

    enum Tab: Hashable { case events, game, organize, profile }

    var isOrganizer: Bool { profile?.isOrganizer == true }
    var myUserId: UUID? { userId }

    private var userId: UUID?
    private var gameChannel: RealtimeChannelV2?
    private var listChannel: RealtimeChannelV2?
    private var gameTasks: [Task<Void, Never>] = []
    private var listTask: Task<Void, Never>?

    init() {
        organizer.report = { [weak self] error in self?.report(error) }
        organizer.didJoin = { [weak self] in
            await self?.loadGames()
            await self?.loadCurrent()
        }
    }

    var me: Player? { roster.first { $0.userId == userId } }
    var joinedRoster: [Player] { roster.filter { $0.status == .joined } }

    // MARK: Auth

    func start() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-demoOrganizer") { loadDemo(); return }
        #endif
        guard AppConfig.isConfigured else { phase = .signedOut; return }
        for await (event, session) in supabase.auth.authStateChanges {
            switch event {
            case .initialSession, .signedIn, .tokenRefreshed, .userUpdated:
                if let session, !session.isExpired {
                    if userId != session.user.id { await signedIn(session.user.id) }
                } else if event == .initialSession {
                    signedOutCleanup()
                }
            case .signedOut, .userDeleted:
                signedOutCleanup()
            default:
                break
            }
        }
    }

    private func signedIn(_ id: UUID) async {
        userId = id
        await loadProfile()
        if phase == .ready { await refreshAll() }
    }

    private func signedOutCleanup() {
        userId = nil
        profile = nil
        games = []
        current = nil
        roster = []
        myRole = nil
        organizer.reset()
        phase = .signedOut
        Task { await stopListening() }
    }

    func signOut() async {
        try? await supabase.auth.signOut()
    }

    // MARK: Profile

    func loadProfile() async {
        guard let userId else { return }
        do {
            let p: Profile = try await supabase.from("profiles").select().eq("id", value: userId).single().execute().value
            profile = p
            phase = p.isComplete ? .ready : .needsProfile
        } catch {
            report(error)
            phase = .needsProfile
        }
    }

    struct ProfileUpdate: Encodable {
        let display_name: String
        let is_adult: Bool
        let rules_ack_at: Date
        let replay_consent: Bool
    }

    func saveProfile(name: String, isAdult: Bool, replayConsent: Bool) async -> Bool {
        guard let userId else { return false }
        do {
            try await supabase.from("profiles")
                .update(ProfileUpdate(display_name: name, is_adult: isAdult,
                                      rules_ack_at: profile?.rulesAckAt ?? Date(), replay_consent: replayConsent))
                .eq("id", value: userId).execute()
            await loadProfile()
            if phase == .ready { await refreshAll() }
            return true
        } catch {
            report(error)
            return false
        }
    }

    func setReplayConsent(_ on: Bool) async {
        guard let userId else { return }
        do {
            try await supabase.from("profiles").update(["replay_consent": on]).eq("id", value: userId).execute()
            profile?.replayConsent = on
        } catch { report(error) }
    }

    // MARK: Games

    func refreshAll() async {
        await loadGames()
        await loadCurrent()
        await listenToList()
    }

    func loadGames() async {
        do {
            let rows: [Game] = try await supabase.from("games").select()
                .not("status", operator: .in, value: "(FINISHED,TERMINATED)")
                .order("starts_at", ascending: true, nullsFirst: false)
                .execute().value
            games = rows
        } catch { report(error) }
    }

    /// The most recent game you've joined that hasn't been over for more than 12 hours.
    func loadCurrent() async {
        guard let userId else { return }
        do {
            let rows: [Membership] = try await supabase.from("game_players")
                .select("game_id, status, joined_at, game:games(*)")
                .eq("user_id", value: userId)
                .eq("status", value: "joined")
                .order("joined_at", ascending: false)
                .limit(5)
                .execute().value
            let cutoff = Date().addingTimeInterval(-12 * 3600)
            let pick = rows.first { !$0.game.status.isOver || ($0.game.endedAt ?? .distantPast) > cutoff }
            if pick?.game.id != current?.id { await stopGameListening() }
            current = pick?.game
            if let game = current {
                await loadRoster(game.id)
                await listen(to: game.id)
            } else {
                roster = []
                myRole = nil
            }
        } catch { report(error) }
    }

    func loadRoster(_ gameId: UUID) async {
        do {
            roster = try await supabase.from("game_players")
                .select("game_id, user_id, status, ready, volunteer, joined_at, profile:profiles(display_name)")
                .eq("game_id", value: gameId)
                .order("joined_at", ascending: true)
                .execute().value
        } catch { report(error) }
        await loadMyRole(gameId)
    }

    func loadMyRole(_ gameId: UUID) async {
        guard let userId else { return }
        do {
            let rows: [RoleRow] = try await supabase.from("game_roles").select()
                .eq("game_id", value: gameId).eq("user_id", value: userId).limit(1).execute().value
            myRole = rows.first?.role
        } catch { report(error) }
    }

    func game(withCode code: String) async -> Game? {
        do {
            let rows: [Game] = try await supabase.from("games").select()
                .eq("join_code", value: Self.normalize(code)).limit(1).execute().value
            return rows.first
        } catch {
            report(error)
            return nil
        }
    }

    func join(code: String) async -> Bool {
        do {
            let _: UUID = try await supabase.rpc("join_game", params: ["code": Self.normalize(code)]).execute().value
            await loadCurrent()
            selectedTab = .game
            return true
        } catch {
            report(error)
            return false
        }
    }

    func leave() async {
        guard let game = current else { return }
        await call("leave_game", ["gid": game.id.uuidString])
        await stopGameListening()
        current = nil
        roster = []
        await loadGames()
    }

    func setReady(_ ready: Bool) async {
        guard let game = current else { return }
        await call("set_ready", GameFlag(gid: game.id, is_ready: ready))
    }

    func setVolunteer(_ on: Bool) async {
        guard let game = current else { return }
        await call("set_volunteer", GameFlag(gid: game.id, is_volunteer: on))
    }

    private struct GameFlag: Encodable {
        let gid: UUID
        var is_ready: Bool? = nil
        var is_volunteer: Bool? = nil
    }

    private func call(_ fn: String, _ params: some Encodable) async {
        do {
            try await supabase.rpc(fn, params: params).execute()
        } catch { report(error) }
    }

    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let url = URL(string: raw), url.scheme == "gamenite" {
            s = url.lastPathComponent.uppercased()
        }
        if !s.hasPrefix("GN-"), s.count == 4 { s = "GN-" + s }
        return s
    }

    // MARK: Live updates

    private func listen(to gameId: UUID) async {
        guard gameChannel == nil else { return }
        let channel = supabase.channel("game-\(gameId.uuidString.lowercased())")
        let gameChanges = channel.postgresChange(AnyAction.self, table: "games",
                                                 filter: .eq("id", value: gameId.uuidString.lowercased()))
        let playerChanges = channel.postgresChange(AnyAction.self, table: "game_players",
                                                   filter: .eq("game_id", value: gameId.uuidString.lowercased()))
        let roleChanges = channel.postgresChange(AnyAction.self, table: "game_roles",
                                                 filter: .eq("game_id", value: gameId.uuidString.lowercased()))
        do { try await channel.subscribeWithError() } catch { report(error) }
        gameChannel = channel

        gameTasks = [
            Task { [weak self] in
                for await _ in gameChanges { await self?.reloadCurrentGame(gameId) }
            },
            Task { [weak self] in
                for await _ in playerChanges { await self?.loadRoster(gameId) }
            },
            Task { [weak self] in
                for await _ in roleChanges { await self?.loadMyRole(gameId) }
            },
        ]
    }

    private func reloadCurrentGame(_ gameId: UUID) async {
        do {
            let g: Game = try await supabase.from("games").select().eq("id", value: gameId).single().execute().value
            if current?.id == gameId { current = g }
            if let i = games.firstIndex(where: { $0.id == gameId }) { games[i] = g }
        } catch { report(error) }
    }

    private func listenToList() async {
        guard listChannel == nil else { return }
        let channel = supabase.channel("games-list")
        let changes = channel.postgresChange(AnyAction.self, table: "games")
        do { try await channel.subscribeWithError() } catch { report(error) }
        listChannel = channel
        listTask = Task { [weak self] in
            for await _ in changes { await self?.loadGames() }
        }
    }

    private func stopGameListening() async {
        gameTasks.forEach { $0.cancel() }
        gameTasks = []
        if let gameChannel { await supabase.removeChannel(gameChannel) }
        gameChannel = nil
    }

    private func stopListening() async {
        await stopGameListening()
        listTask?.cancel()
        listTask = nil
        if let listChannel { await supabase.removeChannel(listChannel) }
        listChannel = nil
    }

    /// Catch up after the app returns to the foreground (sockets may have dropped).
    func resume() async {
        guard phase == .ready, !organizer.demo else { return }
        await loadGames()
        if let game = current { await reloadCurrentGame(game.id); await loadRoster(game.id) }
    }

    // MARK: Errors

    func report(_ error: Error) {
        if error is CancellationError { return }
        if let pg = error as? PostgrestError {
            errorMessage = pg.message
        } else if let auth = error as? AuthError {
            errorMessage = auth.message
        } else {
            errorMessage = error.localizedDescription
        }
    }

    #if DEBUG
    /// Simulator-only demo: an organizer with one lobby, no network.
    private func loadDemo() {
        let me = UUID()
        userId = me
        profile = Profile(id: me, displayName: "Jordan", isAdult: true, rulesAckAt: .now, replayConsent: true, isOrganizer: true)
        var cfg = GameConfig()
        cfg.minPlayers = 4
        let game = Game(id: UUID(), title: "Friday Night Sardines", kind: "scheduled",
                        startsAt: .now.addingTimeInterval(86400), locationName: "Downtown Provo",
                        joinCode: "GN-7K4Q", status: .lobby, config: cfg, configVersion: 2)
        let names: [(String, Bool)] = [("Lucas", true), ("Maya", true), ("Theo", false), ("Ava", true), ("Sam", false)]
        var players = names.map { Player(gameId: game.id, userId: UUID(), status: .joined, ready: $0.1, volunteer: false,
                                         joinedAt: .now, profile: PlayerName(displayName: $0.0)) }
        players.insert(Player(gameId: game.id, userId: me, status: .joined, ready: true, volunteer: false,
                              joinedAt: .now, profile: PlayerName(displayName: "Jordan")), at: 0)
        organizer.demo = true
        organizer.games = [game]
        organizer.roster = players
        organizer.audit = [AuditEntry(id: 2, action: "open_lobby", detail: nil, at: .now),
                           AuditEntry(id: 1, action: "create_game", detail: nil, at: .now.addingTimeInterval(-600))]
        games = [game]
        current = game
        roster = players
        phase = .ready
        selectedTab = .organize
    }
    #endif
}
