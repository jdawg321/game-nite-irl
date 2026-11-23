import Foundation

enum GameStatus: String, Codable, CaseIterable {
    case draft = "DRAFT", lobby = "LOBBY", preparing = "PREPARING", active = "ACTIVE"
    case paused = "PAUSED", finished = "FINISHED", terminated = "TERMINATED"

    var label: String {
        switch self {
        case .draft: "Upcoming"
        case .lobby: "Lobby open"
        case .preparing: "Starting"
        case .active: "Live now"
        case .paused: "Paused"
        case .finished: "Finished"
        case .terminated: "Stopped"
        }
    }

    var isJoinable: Bool { self == .draft || self == .lobby }
    var isOver: Bool { self == .finished || self == .terminated }
}

enum PlayerRole: String, Codable { case pending, seeker, hider }
enum PlayerStatus: String, Codable { case joined, left, removed }

struct Profile: Codable, Equatable {
    let id: UUID
    var displayName: String?
    var isAdult: Bool
    var rulesAckAt: Date?
    var replayConsent: Bool
    var isOrganizer: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case isAdult = "is_adult"
        case rulesAckAt = "rules_ack_at"
        case replayConsent = "replay_consent"
        case isOrganizer = "is_organizer"
    }

    var isComplete: Bool { isAdult && rulesAckAt != nil && !(displayName ?? "").isEmpty }
}

/// Organizer-set rules (PRD §5). Unknown or missing keys fall back to defaults.
struct GameConfig: Codable, Equatable {
    var hiders = 1
    var method = "random"
    var headStart = true
    var headStartMin = 3
    var durationMin = 20
    var reveal = "proximity"
    var revealEveryMin = 2
    var threshold = 15
    var accuracyMax = 20
    var capacity = 50
    var minPlayers = 4
    var startMode = "manual"
    var seekersSeeSeekers = false
    var hidersSeeSeekers = true
    var distRef = "origin"
    var hiderRank = "separate"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GameConfig()
        hiders = (try? c.decode(Int.self, forKey: .hiders)) ?? d.hiders
        method = (try? c.decode(String.self, forKey: .method)) ?? d.method
        headStart = (try? c.decode(Bool.self, forKey: .headStart)) ?? d.headStart
        headStartMin = (try? c.decode(Int.self, forKey: .headStartMin)) ?? d.headStartMin
        durationMin = (try? c.decode(Int.self, forKey: .durationMin)) ?? d.durationMin
        reveal = (try? c.decode(String.self, forKey: .reveal)) ?? d.reveal
        revealEveryMin = (try? c.decode(Int.self, forKey: .revealEveryMin)) ?? d.revealEveryMin
        threshold = (try? c.decode(Int.self, forKey: .threshold)) ?? d.threshold
        accuracyMax = (try? c.decode(Int.self, forKey: .accuracyMax)) ?? d.accuracyMax
        capacity = (try? c.decode(Int.self, forKey: .capacity)) ?? d.capacity
        minPlayers = (try? c.decode(Int.self, forKey: .minPlayers)) ?? d.minPlayers
        startMode = (try? c.decode(String.self, forKey: .startMode)) ?? d.startMode
        seekersSeeSeekers = (try? c.decode(Bool.self, forKey: .seekersSeeSeekers)) ?? d.seekersSeeSeekers
        hidersSeeSeekers = (try? c.decode(Bool.self, forKey: .hidersSeeSeekers)) ?? d.hidersSeeSeekers
        distRef = (try? c.decode(String.self, forKey: .distRef)) ?? d.distRef
        hiderRank = (try? c.decode(String.self, forKey: .hiderRank)) ?? d.hiderRank
    }

    var hiderMethodText: String {
        switch method {
        case "manual": "picked by the organizer"
        case "volunteer": "volunteers, approved by the organizer"
        default: "chosen at random"
        }
    }

    var revealText: String {
        switch reveal {
        case "continuous": "Shaded hiding area, updates every 30 s"
        case "periodic": "Hiding area shown for 45 s every \(revealEveryMin) min"
        default: "Distance clues (no map pin)"
        }
    }
}

struct Game: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var kind: String
    var startsAt: Date?
    var locationName: String
    var joinCode: String
    var status: GameStatus
    var config: GameConfig
    var startedAt: Date?
    var endedAt: Date?
    var endReason: String?
    var configVersion: Int?

    enum CodingKeys: String, CodingKey {
        case id, title, kind, status, config
        case configVersion = "config_version"
        case startsAt = "starts_at"
        case locationName = "location_name"
        case joinCode = "join_code"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case endReason = "end_reason"
    }

    var whenText: String {
        if kind == "instant" { return "Instant game · now" }
        guard let startsAt else { return "Time to be announced" }
        return startsAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }
}

struct PlayerName: Codable, Equatable {
    var displayName: String?
    enum CodingKeys: String, CodingKey { case displayName = "display_name" }
}

struct Player: Codable, Identifiable, Equatable {
    let gameId: UUID
    let userId: UUID
    var status: PlayerStatus
    var ready: Bool
    var volunteer: Bool
    var joinedAt: Date
    var profile: PlayerName?

    var id: UUID { userId }
    var name: String { profile?.displayName ?? "Player" }

    enum CodingKeys: String, CodingKey {
        case status, ready, volunteer, profile
        case gameId = "game_id"
        case userId = "user_id"
        case joinedAt = "joined_at"
    }
}

/// A membership row with its game embedded, used to find the game you're currently in.
struct Membership: Codable {
    let gameId: UUID
    let status: PlayerStatus
    let joinedAt: Date
    let game: Game

    enum CodingKeys: String, CodingKey {
        case status, game
        case gameId = "game_id"
        case joinedAt = "joined_at"
    }
}

struct RoleRow: Codable, Equatable {
    let gameId: UUID
    let userId: UUID
    var role: PlayerRole
    enum CodingKeys: String, CodingKey {
        case role
        case gameId = "game_id"
        case userId = "user_id"
    }
}

struct AuditEntry: Codable, Identifiable, Equatable {
    let id: Int
    let action: String
    let detail: [String: AnyJSONValue]?
    let at: Date

    var title: String { action.replacingOccurrences(of: "_", with: " ").capitalized }
    var reason: String? {
        if case .string(let r)? = detail?["reason"] { return r }
        return nil
    }
}

/// Minimal JSON value for reading audit details.
enum AnyJSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), other

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else { self = .other }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .other: try c.encodeNil()
        }
    }
}
