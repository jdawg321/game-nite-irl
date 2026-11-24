import SwiftUI
import UIKit

/// Field test for the biggest Stage 2 risk: does background GPS keep a steady
/// ~25 s rhythm with usable accuracy, and what does it cost in battery?
/// Nothing leaves the phone; you can share the log as CSV.
struct GPSTestView: View {
    @Environment(AppState.self) private var app
    private var log: GPSTestLog { app.gpsTest }

    private var location: LocationService { app.location }
    private var gameRunning: Bool { app.current.map { [.preparing, .active, .paused].contains($0.status) } ?? false }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Walk around with the phone locked or in another app. Game Nite records a GPS reading about every \(Int(LocationService.sampleInterval)) seconds, the same way it will during a game.")
                    .font(.subheadline).foregroundStyle(Theme.muted)

                if location.isDenied {
                    Label("Location is off for Game Nite. Turn it on in Settings → Game Nite → Location.", systemImage: "location.slash")
                        .font(.footnote).foregroundStyle(Theme.warn).panel()
                } else if gameRunning {
                    Label("You're in a live game, so the test is unavailable.", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(Theme.warn).panel()
                }

                if log.running {
                    Button("Stop test") { stop() }.buttonStyle(SecondaryButtonStyle(tint: Theme.crit))
                } else {
                    Button(log.samples.isEmpty ? "Start test" : "Start a new test") { start() }
                        .buttonStyle(.cta)
                        .disabled(location.isDenied || gameRunning)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    stat("\(log.samples.count)", "readings")
                    stat(log.elapsedText, "running")
                    stat(log.medianAccuracyText, "median accuracy")
                    stat(log.withinLimitText, "within 20 m")
                    stat(log.maxGapText, "longest gap")
                    stat(log.batteryText, "battery used")
                }

                if !log.samples.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Latest readings").font(.headline).padding(.bottom, 6)
                        ForEach(log.samples.suffix(12).reversed(), id: \.sample.recordedAt) { row in
                            HStack {
                                Text(row.sample.recordedAt.formatted(date: .omitted, time: .standard))
                                Spacer()
                                Text("±\(Int(row.sample.accuracy.rounded())) m")
                                    .foregroundStyle(row.sample.accuracy <= 20 ? Theme.ok : Theme.warn)
                                Text(row.gap.map { "+\(Int($0.rounded())) s" } ?? "start")
                                    .foregroundStyle(row.gap.map { $0 > 60 ? Theme.crit : Theme.muted } ?? Theme.muted)
                                    .frame(width: 64, alignment: .trailing)
                            }
                            .font(.system(.footnote, design: .monospaced))
                            .padding(.vertical, 5)
                            Divider().overlay(Theme.surface2)
                        }
                    }
                    .panel()

                    ShareLink(item: log.csv, preview: SharePreview("Game Nite GPS test")) {
                        Label("Share results (CSV)", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.secondary)
                }
            }
            .padding(20)
        }
        .background(Theme.bg)
        .navigationTitle("GPS test")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { if !log.running { location.onSample = nil } }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .black, design: .rounded)).foregroundStyle(Theme.neon)
            Text(label).font(.footnote).foregroundStyle(Theme.muted)
        }
        .panel()
    }

    private func start() {
        if !location.canTrack {
            location.requestPermission()
            return
        }
        log.begin()
        location.onSample = { sample in log.add(sample) }
        location.start()
    }

    private func stop() {
        location.stop()
        location.onSample = nil
        log.end()
    }
}

@Observable
final class GPSTestLog {
    struct Row { let sample: LocationSample; let gap: TimeInterval?; let battery: Float }

    var samples: [Row] = []
    var running = false
    var startedAt: Date?
    var endedAt: Date?
    private var startBattery: Float = -1

    func begin() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        samples = []
        running = true
        startedAt = .now
        endedAt = nil
        startBattery = UIDevice.current.batteryLevel
    }

    func end() {
        running = false
        endedAt = .now
    }

    func add(_ sample: LocationSample) {
        let gap = samples.last.map { sample.recordedAt.timeIntervalSince($0.sample.recordedAt) }
        samples.append(Row(sample: sample, gap: gap, battery: UIDevice.current.batteryLevel))
    }

    var elapsedText: String {
        guard let startedAt else { return "–" }
        let secs = Int((endedAt ?? .now).timeIntervalSince(startedAt))
        return "\(secs / 60)m \(secs % 60)s"
    }

    var medianAccuracyText: String {
        let acc = samples.map(\.sample.accuracy).sorted()
        guard !acc.isEmpty else { return "–" }
        return "±\(Int(acc[acc.count / 2].rounded())) m"
    }

    var withinLimitText: String {
        guard !samples.isEmpty else { return "–" }
        let ok = samples.filter { $0.sample.accuracy <= 20 }.count
        return "\(ok * 100 / samples.count)%"
    }

    var maxGapText: String {
        guard let gap = samples.compactMap(\.gap).max() else { return "–" }
        return "\(Int(gap.rounded())) s"
    }

    var batteryText: String {
        guard startBattery >= 0, let last = samples.last?.battery, last >= 0 else { return "–" }
        return "\(Int(((startBattery - last) * 100).rounded()))%"
    }

    var csv: String {
        let f = ISO8601DateFormatter()
        var out = "recorded_at,latitude,longitude,accuracy_m,gap_s,battery_pct\n"
        for r in samples {
            out += "\(f.string(from: r.sample.recordedAt)),\(r.sample.latitude),\(r.sample.longitude),"
            out += "\(Int(r.sample.accuracy.rounded())),\(r.gap.map { String(Int($0.rounded())) } ?? ""),"
            out += "\(r.battery >= 0 ? String(Int((r.battery * 100).rounded())) : "")\n"
        }
        return out
    }
}
