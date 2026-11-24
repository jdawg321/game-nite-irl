import CoreLocation
import Foundation
import Testing
@testable import GameNite

// MARK: - Join codes

@MainActor
struct JoinCodeTests {
    @Test("Codes are normalized however players type or scan them",
          arguments: [
            ("GN-7K4Q", "GN-7K4Q"),
            ("gn-7k4q", "GN-7K4Q"),
            ("  GN-7K4Q \n", "GN-7K4Q"),
            ("7k4q", "GN-7K4Q"),
            ("gamenite://join/GN-7K4Q", "GN-7K4Q"),
          ])
    func normalize(input: String, expected: String) {
        #expect(AppState.normalize(input) == expected)
    }
}

// MARK: - Rules

struct GameConfigTests {
    @Test func missingKeysFallBackToDefaults() throws {
        let json = #"{"hiders": 2, "method": "volunteer"}"#.data(using: .utf8)!
        let c = try JSONDecoder().decode(GameConfig.self, from: json)
        #expect(c.hiders == 2)
        #expect(c.method == "volunteer")
        #expect(c.durationMin == 20)
        #expect(c.threshold == 15)
        #expect(c.distRef == "origin")
        #expect(c.hiderRank == "separate")
    }

    @Test func wrongTypesDontBreakDecoding() throws {
        let json = #"{"hiders": "lots", "capacity": 30}"#.data(using: .utf8)!
        let c = try JSONDecoder().decode(GameConfig.self, from: json)
        #expect(c.hiders == 1)
        #expect(c.capacity == 30)
    }

    @Test func roundTripsThroughJSON() throws {
        var c = GameConfig()
        c.reveal = "periodic"
        c.revealEveryMin = 4
        c.seekersSeeSeekers = true
        let back = try JSONDecoder().decode(GameConfig.self, from: JSONEncoder().encode(c))
        #expect(back == c)
    }

    @Test func plainLanguageText() {
        var c = GameConfig()
        #expect(c.hiderMethodText == "chosen at random")
        c.reveal = "periodic"; c.revealEveryMin = 3
        #expect(c.revealText.contains("every 3 min"))
    }
}

// MARK: - Server rows

struct DecodingTests {
    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    @Test func decodesAGameRow() throws {
        let json = """
        {"id":"8b0b1f2e-6c55-4c8e-9d7e-1b1d2c3d4e5f","title":"Friday Night Sardines","kind":"scheduled",
         "starts_at":"2026-11-27T03:00:00Z","location_name":"Downtown Provo","join_code":"GN-7K4Q",
         "status":"LOBBY","config":{"minPlayers":6},"config_version":3,"start_lat":40.2338,"start_lng":-111.6585,
         "boundary_m":500,"seek_starts_at":null,"ends_at":null,"emergency":false}
        """.data(using: .utf8)!
        let g = try decoder.decode(Game.self, from: json)
        #expect(g.status == .lobby)
        #expect(g.status.isJoinable)
        #expect(g.config.minPlayers == 6)
        #expect(g.configVersion == 3)
        #expect(g.boundaryM == 500)
    }

    @Test func profileCompleteness() {
        var p = Profile(id: UUID(), displayName: "Jordan", isAdult: true, rulesAckAt: .now, replayConsent: false, isOrganizer: false)
        #expect(p.isComplete)
        p.isAdult = false
        #expect(!p.isComplete)
        p.isAdult = true; p.displayName = ""
        #expect(!p.isComplete)
    }

    @Test func auditReasonIsReadable() throws {
        let json = #"{"id":4,"action":"remove_player","detail":{"reason":"Left the area","user":"x"},"at":"2026-11-23T20:00:00Z"}"#
        let e = try decoder.decode(AuditEntry.self, from: json.data(using: .utf8)!)
        #expect(e.title == "Remove Player")
        #expect(e.reason == "Left the area")
    }

    @Test func clueBands() {
        #expect(Clue(mode: "proximity", band: "very_close").bandText.hasPrefix("Very close"))
        #expect(Clue(mode: "proximity", band: "far").bandText.hasPrefix("Far"))
        #expect(Clue(mode: "proximity", band: nil).bandText == "Waiting for your GPS")
    }

    @Test func resultPlaces() {
        let shared = ResultRow(userId: UUID(), displayName: "A", category: "unfinished", place: 4, shared: true, foundAt: nil, bestDistanceM: 31)
        let solo = ResultRow(userId: UUID(), displayName: "B", category: "found", place: 2, shared: false, foundAt: .now, bestDistanceM: nil)
        let hider = ResultRow(userId: UUID(), displayName: nil, category: "hider", place: nil, shared: false, foundAt: nil, bestDistanceM: nil)
        #expect(shared.placeText == "T-4")
        #expect(solo.placeText == "2")
        #expect(hider.placeText == "–")
        #expect(hider.name == "Player")
    }

    @Test(arguments: [(1, "1st"), (2, "2nd"), (3, "3rd"), (4, "4th"), (11, "11th"), (12, "12th"), (13, "13th"), (21, "21st"), (22, "22nd"), (101, "101st")])
    func ordinals(n: Int, expected: String) {
        #expect(Ordinal.string(n) == expected)
    }
}

// MARK: - Location

struct LocationTests {
    @Test func distanceMatchesKnownValue() {
        // Two points in downtown Provo, about one city block (~ 200 m) apart east–west.
        let a = CLLocationCoordinate2D(latitude: 40.2338, longitude: -111.6585)
        let b = CLLocationCoordinate2D(latitude: 40.2338, longitude: -111.6561)
        let d = Geo.distance(a, b)
        #expect(abs(d - 204) < 3)
        #expect(Geo.distance(a, a) == 0)
    }

    @Test func freshnessWindowIs90Seconds() {
        let now = Date()
        let fresh = LocationSample(latitude: 0, longitude: 0, accuracy: 5, recordedAt: now.addingTimeInterval(-60))
        let stale = LocationSample(latitude: 0, longitude: 0, accuracy: 5, recordedAt: now.addingTimeInterval(-120))
        #expect(fresh.isFresh(now: now))
        #expect(!stale.isFresh(now: now))
    }

    @Test(arguments: [(0.0, "0:00"), (9.2, "0:10"), (65, "1:05"), (600, "10:00"), (-5, "0:00")])
    func timerFormatting(seconds: Double, expected: String) {
        #expect(PhaseHeader.clock(seconds) == expected)
    }
}

// MARK: - GPS test stats

struct GPSTestLogTests {
    private func sample(_ secs: Double, acc: Double) -> LocationSample {
        LocationSample(latitude: 40.23, longitude: -111.65, accuracy: acc,
                       recordedAt: Date(timeIntervalSince1970: 1_800_000_000 + secs))
    }

    @Test func statsSummarizeTheWalk() {
        let log = GPSTestLog()
        log.begin()
        log.add(sample(0, acc: 5))
        log.add(sample(25, acc: 10))
        log.add(sample(50, acc: 40))
        log.add(sample(140, acc: 8))
        #expect(log.samples.count == 4)
        #expect(log.medianAccuracyText == "±10 m")
        #expect(log.withinLimitText == "75%")
        #expect(log.maxGapText == "90 s")
        let lines = log.csv.split(separator: "\n")
        #expect(lines.first == "recorded_at,latitude,longitude,accuracy_m,gap_s,battery_pct")
        #expect(lines.count == 5)
    }

    @Test func emptyLogShowsDashes() {
        let log = GPSTestLog()
        #expect(log.medianAccuracyText == "–")
        #expect(log.maxGapText == "–")
        #expect(log.withinLimitText == "–")
    }
}
