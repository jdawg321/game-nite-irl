import CoreLocation
import Foundation
import Observation
import UIKit

/// One GPS reading with the accuracy the phone reported.
struct LocationSample: Equatable, Codable {
    let latitude: Double
    let longitude: Double
    /// Horizontal accuracy in meters (smaller is better).
    let accuracy: Double
    let recordedAt: Date

    init(_ location: CLLocation) {
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        accuracy = location.horizontalAccuracy
        recordedAt = location.timestamp
    }

    init(latitude: Double, longitude: Double, accuracy: Double, recordedAt: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.recordedAt = recordedAt
    }

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }

    /// A fix older than this can't prove a find (PRD: fresh on-demand fix).
    static let freshness: TimeInterval = 90

    func isFresh(now: Date = .now) -> Bool { now.timeIntervalSince(recordedAt) <= Self.freshness }
}

enum Geo {
    /// Great-circle distance in meters.
    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let r = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let la1 = a.latitude * .pi / 180, la2 = b.latitude * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(la1) * cos(la2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}

/// Samples location every ~25 s while a game (or the GPS test) is running,
/// including in the background. Tracking only runs while `isTracking` is true.
@MainActor @Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let sampleInterval: TimeInterval = 25

    private(set) var authorization: CLAuthorizationStatus
    private(set) var isTracking = false
    private(set) var latest: LocationSample?

    /// Called once per sample interval with the newest fix.
    var onSample: ((LocationSample) -> Void)?

    private let manager = CLLocationManager()
    private var lastDelivered: Date = .distantPast
    private var oneShot: [CheckedContinuation<LocationSample?, Never>] = []

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
    }

    var canTrack: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }
    var isDenied: Bool { authorization == .denied || authorization == .restricted }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    /// Starts continuous tracking. Background updates stay on because the app
    /// started them in the foreground and shows the system location indicator.
    func start() {
        guard canTrack, !isTracking else { return }
        isTracking = true
        lastDelivered = .distantPast
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    func stop() {
        guard isTracking else { return }
        isTracking = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    /// A fresh fix right now, for proving a find. Returns nil if none arrives in 15 s.
    func freshFix() async -> LocationSample? {
        if let latest, Date().timeIntervalSince(latest.recordedAt) < 5, latest.accuracy >= 0 { return latest }
        return await withCheckedContinuation { cont in
            oneShot.append(cont)
            manager.requestLocation()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                self.finishOneShots(with: nil)
            }
        }
    }

    private func finishOneShots(with sample: LocationSample?) {
        let waiting = oneShot
        oneShot = []
        waiting.forEach { $0.resume(returning: sample) }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorization = status }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.horizontalAccuracy >= 0 else { return }
        let sample = LocationSample(loc)
        Task { @MainActor in self.receive(sample) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finishOneShots(with: nil) }
    }

    private func receive(_ sample: LocationSample) {
        latest = sample
        finishOneShots(with: sample)
        guard isTracking else { return }
        if sample.recordedAt.timeIntervalSince(lastDelivered) >= Self.sampleInterval {
            lastDelivered = sample.recordedAt
            onSample?(sample)
        }
    }
}
