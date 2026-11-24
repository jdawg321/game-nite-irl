import Foundation
import Observation
import Supabase

/// Runs the player side of a live game: GPS on/off with the game, location
/// reports, what you may see on the map, your clue, finds and results.
/// Every decision (phase, visibility, find checks, ranking) is made by the server.
@MainActor @Observable
final class LiveGameStore {
    var positions: [VisiblePosition] = []
    var clue: Clue?
    /// Finds waiting for the hiding group (shown to hiders and found players).
    var toConfirm: [Find] = []
    /// Your own latest find request, if any.
    var myFind: Find?
    var results: [ResultRow] = []
    var outOfBounds = false
    var lastReportAt: Date?
    var findBusy = false
    /// Short message after a find attempt ("Keep looking", "Waiting for…").
    var findMessage: String?

    var report: (Error) -> Void = { _ in }

    private let location: LocationService
    private var gameId: UUID?
    private var pollTask: Task<Void, Never>?
    private var channel: RealtimeChannelV2?
    private var channelTask: Task<Void, Never>?

    init(location: LocationService) {
        self.location = location
    }

    // MARK: Lifecycle

    /// Called whenever the current game or its status changes.
    func sync(game: Game?, isMember: Bool) async {
        guard let game, isMember else { await stop(); return }
        switch game.status {
        case .preparing, .active, .paused:
            if gameId != game.id { await stop(); gameId = game.id }
            startTracking(game.id)
            startPolling(game.id)
            await listen(game.id)
        case .finished, .terminated:
            stopTracking()
            pollTask?.cancel(); pollTask = nil
            gameId = game.id
            await refreshFinds(game.id)
            await loadResults(game.id)
        default:
            await stop()
        }
    }

    func stop() async {
        stopTracking()
        pollTask?.cancel(); pollTask = nil
        channelTask?.cancel(); channelTask = nil
        if let channel { await supabase.removeChannel(channel) }
        channel = nil
        gameId = nil
        positions = []; clue = nil; toConfirm = []; myFind = nil; results = []
        outOfBounds = false; findMessage = nil
    }

    private func startTracking(_ gid: UUID) {
        location.onSample = { [weak self] sample in
            Task { await self?.send(sample, gid: gid) }
        }
        location.start()
    }

    private func stopTracking() {
        location.stop()
        location.onSample = nil
    }

    private func startPolling(_ gid: UUID) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(gid)
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func listen(_ gid: UUID) async {
        guard channel == nil else { return }
        let ch = supabase.channel("live-\(gid.uuidString.lowercased())")
        let changes = ch.postgresChange(AnyAction.self, table: "finds",
                                        filter: .eq("game_id", value: gid.uuidString.lowercased()))
        do { try await ch.subscribeWithError() } catch { report(error) }
        channel = ch
        channelTask = Task { [weak self] in
            for await _ in changes { await self?.refreshFinds(gid) }
        }
    }

    // MARK: Server calls

    struct ReportParams: Encodable {
        let gid: UUID
        let lat: Double
        let lng: Double
        let accuracy_m: Double
        let recorded_at: Date
        var on_demand: Bool = false
    }

    struct ReportReply: Decodable { let tracking: Bool; let out_of_bounds: Bool? }

    private func send(_ sample: LocationSample, gid: UUID) async {
        do {
            let reply: ReportReply = try await supabase.rpc("report_location", params: ReportParams(
                gid: gid, lat: sample.latitude, lng: sample.longitude,
                accuracy_m: sample.accuracy, recorded_at: sample.recordedAt)).execute().value
            lastReportAt = .now
            outOfBounds = reply.out_of_bounds ?? false
        } catch { report(error) }
    }

    func refresh(_ gid: UUID) async {
        do {
            _ = try? await supabase.rpc("tick_game", params: ["gid": gid]).execute()
            async let p: [VisiblePosition] = supabase.rpc("visible_positions", params: ["gid": gid]).execute().value
            async let c: Clue? = supabase.rpc("my_clue", params: ["gid": gid]).execute().value
            let (pos, clue) = try await (p, c)
            positions = pos
            self.clue = clue
            if let me = pos.first(where: { $0.grp == "me" }) { outOfBounds = me.outOfBounds }
        } catch { report(error) }
        await refreshFinds(gid)
    }

    func refreshFinds(_ gid: UUID) async {
        do {
            let rows: [Find] = try await supabase.from("finds")
                .select("id, game_id, seeker_id, accuracy_m, distance_m, status, reason, created_at, seeker:profiles!finds_seeker_id_fkey(display_name)")
                .eq("game_id", value: gid)
                .order("created_at", ascending: false)
                .limit(30)
                .execute().value
            let me = try? await supabase.auth.session.user.id
            myFind = rows.first { $0.seekerId == me }
            toConfirm = rows.filter { $0.status == .confirming && $0.seekerId != me }
        } catch { report(error) }
    }

    func loadResults(_ gid: UUID) async {
        do {
            results = try await supabase.rpc("game_results", params: ["gid": gid]).execute().value
        } catch { report(error) }
    }

    struct FindParams: Encodable {
        let gid: UUID
        let lat: Double
        let lng: Double
        let accuracy_m: Double
        let recorded_at: Date
    }

    /// Takes a fresh GPS fix and asks the server to check the find.
    func requestFind() async {
        guard let gid = gameId else { return }
        findBusy = true
        findMessage = "Getting a fresh GPS fix…"
        defer { findBusy = false }
        guard let fix = await location.freshFix() else {
            findMessage = "Couldn't get a GPS fix. Step into the open and try again."
            return
        }
        do {
            let r: FindResult = try await supabase.rpc("request_find", params: FindParams(
                gid: gid, lat: fix.latitude, lng: fix.longitude,
                accuracy_m: fix.accuracy, recorded_at: fix.recordedAt)).execute().value
            switch r.result {
            case "confirming": findMessage = "Close enough! Waiting for the hiding group to confirm."
            case "review": findMessage = "Sent to the organizer to check (GPS wasn't precise enough)."
            default: findMessage = r.distanceBand == "close" ? "Not quite. You're close, keep looking." : "They're not here. Keep looking."
            }
            await refreshFinds(gid)
        } catch {
            findMessage = nil
            report(error)
        }
    }

    struct ConfirmParams: Encodable { let fid: UUID; let is_here: Bool }

    func confirm(_ find: Find, here: Bool) async {
        do {
            try await supabase.rpc("confirm_find", params: ConfirmParams(fid: find.id, is_here: here)).execute()
            toConfirm.removeAll { $0.id == find.id }
            if let gid = gameId { await refresh(gid) }
        } catch { report(error) }
    }
}
