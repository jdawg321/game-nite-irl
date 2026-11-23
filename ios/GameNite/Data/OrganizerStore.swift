import Foundation
import Observation
import Supabase

/// Organizer-only state and actions. Every change is a database function that
/// re-checks that the caller is this game's organizer.
@MainActor @Observable
final class OrganizerStore {
    var games: [Game] = []
    var selected: Game?
    var roster: [Player] = []
    /// Roles the organizer may see. Empty while the organizer is playing a started game.
    var roles: [UUID: PlayerRole] = [:]
    var audit: [AuditEntry] = []
    var busy = false
    /// Debug-only demo data with no network calls.
    var demo = false

    /// Set by AppState so errors show in the app's alert.
    var report: (Error) -> Void = { _ in }
    /// Set by AppState after joining, so the player side refreshes.
    var didJoin: () async -> Void = {}

    private var channel: RealtimeChannelV2?
    private var tasks: [Task<Void, Never>] = []

    var joined: [Player] { roster.filter { $0.status == .joined } }

    func reset() {
        games = []; selected = nil; roster = []; roles = [:]; audit = []
        Task { await stopListening() }
    }

    // MARK: Loading

    func loadGames(organizerId: UUID) async {
        if demo { return }
        do {
            games = try await supabase.from("games").select()
                .eq("organizer_id", value: organizerId)
                .order("created_at", ascending: false)
                .execute().value
            if let sel = selected { selected = games.first { $0.id == sel.id } }
        } catch { report(error) }
    }

    func open(_ game: Game) async {
        if demo { selected = game; return }
        if selected?.id != game.id { await stopListening() }
        selected = game
        await loadDetail()
        await listen(game.id)
    }

    func close() async {
        if demo { return }
        await stopListening()
        selected = nil; roster = []; roles = [:]; audit = []
    }

    func loadDetail() async {
        guard let game = selected, !demo else { return }
        do {
            async let g: Game = supabase.from("games").select().eq("id", value: game.id).single().execute().value
            async let r: [Player] = supabase.from("game_players")
                .select("game_id, user_id, status, ready, volunteer, joined_at, profile:profiles(display_name)")
                .eq("game_id", value: game.id).order("joined_at", ascending: true).execute().value
            async let ro: [RoleRow] = supabase.from("game_roles").select().eq("game_id", value: game.id).execute().value
            async let a: [AuditEntry] = supabase.from("audit_log").select("id, action, detail, at")
                .eq("game_id", value: game.id).order("at", ascending: false).limit(50).execute().value
            let (fresh, players, roleRows, log) = try await (g, r, ro, a)
            selected = fresh
            if let i = games.firstIndex(where: { $0.id == fresh.id }) { games[i] = fresh }
            roster = players
            roles = Dictionary(uniqueKeysWithValues: roleRows.map { ($0.userId, $0.role) })
            audit = log
        } catch { report(error) }
    }

    /// True when you've joined this game as a player. Once it starts, roles
    /// (and in Stage 2, locations) are hidden from your organizer view.
    func isPlaying(_ userId: UUID?) -> Bool {
        guard let userId else { return false }
        return joined.contains { $0.userId == userId }
    }

    // MARK: Actions

    struct CreateParams: Encodable {
        let p_title: String
        let p_kind: String
        let p_starts_at: Date?
        let p_location: String
        let p_config: GameConfig
    }

    func create(title: String, kind: String, startsAt: Date?, location: String, config: GameConfig, organizerId: UUID) async -> Bool {
        await run {
            let id: UUID = try await supabase.rpc("create_game", params: CreateParams(
                p_title: title, p_kind: kind, p_starts_at: startsAt, p_location: location, p_config: config)).execute().value
            await self.loadGames(organizerId: organizerId)
            if let g = self.games.first(where: { $0.id == id }) { await self.open(g) }
        }
    }

    struct ConfigParams: Encodable { let gid: UUID; let p_config: GameConfig }
    struct GameParam: Encodable { let gid: UUID }
    struct ReasonParams: Encodable { let gid: UUID; let reason: String }
    struct PlayerReasonParams: Encodable { let gid: UUID; let uid: UUID; let reason: String }
    struct RoleParams: Encodable { let gid: UUID; let uid: UUID; let p_role: PlayerRole }

    func saveConfig(_ config: GameConfig) async -> Bool {
        guard let g = selected else { return false }
        return await run { try await supabase.rpc("update_game_config", params: ConfigParams(gid: g.id, p_config: config)).execute() }
    }

    func openLobby() async -> Bool {
        guard let g = selected else { return false }
        return await run { try await supabase.rpc("open_lobby", params: GameParam(gid: g.id)).execute() }
    }

    func start() async -> Bool {
        guard let g = selected else { return false }
        return await run { try await supabase.rpc("start_game", params: GameParam(gid: g.id)).execute() }
    }

    func terminate(reason: String) async -> Bool {
        guard let g = selected else { return false }
        return await run { try await supabase.rpc("terminate_game", params: ReasonParams(gid: g.id, reason: reason)).execute() }
    }

    func remove(_ player: Player, reason: String) async -> Bool {
        guard let g = selected else { return false }
        return await run {
            try await supabase.rpc("remove_player", params: PlayerReasonParams(gid: g.id, uid: player.userId, reason: reason)).execute()
        }
    }

    func setHider(_ player: Player, _ on: Bool) async -> Bool {
        guard let g = selected else { return false }
        return await run {
            try await supabase.rpc("set_player_role", params: RoleParams(gid: g.id, uid: player.userId, p_role: on ? .hider : .pending)).execute()
        }
    }

    func joinAsPlayer() async -> Bool {
        guard let g = selected else { return false }
        return await run {
            let _: UUID = try await supabase.rpc("join_game", params: ["code": g.joinCode]).execute().value
            await self.didJoin()
        }
    }

    /// Runs an action, then reloads the game so the screen matches the server.
    @discardableResult
    private func run(_ body: @escaping () async throws -> Void) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            try await body()
            await loadDetail()
            return true
        } catch {
            report(error)
            await loadDetail()
            return false
        }
    }

    // MARK: Live updates

    private func listen(_ gameId: UUID) async {
        guard channel == nil else { return }
        let id = gameId.uuidString.lowercased()
        let ch = supabase.channel("org-\(id)")
        let streams = [
            ch.postgresChange(AnyAction.self, table: "games", filter: .eq("id", value: id)),
            ch.postgresChange(AnyAction.self, table: "game_players", filter: .eq("game_id", value: id)),
            ch.postgresChange(AnyAction.self, table: "game_roles", filter: .eq("game_id", value: id)),
        ]
        do { try await ch.subscribeWithError() } catch { report(error) }
        channel = ch
        tasks = streams.map { stream in
            Task { [weak self] in
                for await _ in stream { await self?.loadDetail() }
            }
        }
    }

    private func stopListening() async {
        tasks.forEach { $0.cancel() }
        tasks = []
        if let channel { await supabase.removeChannel(channel) }
        channel = nil
    }
}
