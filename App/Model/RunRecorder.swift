import CoreLocation
import Foundation
import Observation
import TagwerkCore

struct RoutePoint: Codable, Hashable {
    var lat: Double
    var lon: Double
    var alt: Double?
    var t: TimeInterval
}

/// Recorded routes stay on the phone (the vault gets them as GPX).
enum RouteStore {
    static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("routes", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func save(_ points: [RoutePoint], id: String) {
        guard let data = try? JSONEncoder().encode(points) else { return }
        try? data.write(to: dir.appendingPathComponent("\(id).json"), options: .atomic)
    }

    static func load(_ id: String) -> [RoutePoint] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("\(id).json")) else { return [] }
        return (try? JSONDecoder().decode([RoutePoint].self, from: data)) ?? []
    }

    static func delete(_ id: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).json"))
    }
}

enum GPX {
    static func make(_ points: [RoutePoint], name: String) -> String {
        let iso = ISO8601DateFormatter()
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gpx version=\"1.1\" creator=\"Tagwerk\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n"
        if let first = points.first { out += "  <metadata><time>\(iso.string(from: Date(timeIntervalSince1970: first.t)))</time></metadata>\n" }
        out += "  <trk><name>\(esc(name))</name><type>running</type><trkseg>\n"
        for p in points {
            out += String(format: "    <trkpt lat=\"%.6f\" lon=\"%.6f\">", p.lat, p.lon)
            if let a = p.alt { out += String(format: "<ele>%.1f</ele>", a) }
            out += "<time>\(iso.string(from: Date(timeIntervalSince1970: p.t)))</time></trkpt>\n"
        }
        out += "  </trkseg></trk>\n</gpx>\n"
        return out
    }
}

/// What an unfinished recording leaves on disk, so a run survives the app being terminated.
struct RecordingSnapshot: Codable {
    var start: Date
    var pausedTotal: TimeInterval
    var pauseStart: Date?
    var distance: Double
    var points: [RoutePoint]
    var savedAt: Date

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("run-recording.json")
    }

    static func load() -> RecordingSnapshot? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RecordingSnapshot.self, from: d)
    }

    static func clear() { try? FileManager.default.removeItem(at: url) }

    var elapsed: TimeInterval {
        let end = pauseStart ?? savedAt
        return max(0, end.timeIntervalSince(start) - pausedTotal)
    }
}

/// GPS run recording with Core Location. Works with the screen locked ("When in use" plus the
/// background location mode); distance only counts fixes better than 25 m.
@MainActor
@Observable
final class RunRecorder: NSObject, CLLocationManagerDelegate {
    enum Phase: Equatable { case idle, locating, running, paused }

    var phase: Phase = .idle
    var distance: Double = 0
    var accuracy: Double?
    var authorization: CLAuthorizationStatus = .notDetermined
    var points: [RoutePoint] = []
    var start: Date?
    var pausedTotal: TimeInterval = 0
    var pauseStart: Date?
    var lastError: String?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var last: CLLocation?
    @ObservationIgnored private var session: CLBackgroundActivitySession?
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var recent: [(t: Date, d: Double)] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 3
        manager.pausesLocationUpdatesAutomatically = false
        authorization = manager.authorizationStatus
    }

    func elapsed(at now: Date = Date()) -> TimeInterval {
        guard let start else { return 0 }
        let end = pauseStart ?? now
        return max(0, end.timeIntervalSince(start) - pausedTotal)
    }

    /// Minutes per km over the last half minute of movement.
    var currentPace: Double? {
        guard let a = recent.first, let b = recent.last, b.t.timeIntervalSince(a.t) >= 10 else { return nil }
        let d = b.d - a.d
        guard d > 15 else { return nil }
        return b.t.timeIntervalSince(a.t) / 60 / (d / 1000)
    }

    var averagePace: Double? {
        let km = distance / 1000
        guard km > 0.05 else { return nil }
        return elapsed() / 60 / km
    }

    func prepare() {
        authorization = manager.authorizationStatus
        if authorization == .notDetermined { manager.requestWhenInUseAuthorization() }
        phase = .locating
        manager.startUpdatingLocation()
    }

    func begin() {
        guard authorization == .authorizedWhenInUse || authorization == .authorizedAlways else {
            lastError = "Ohne Standortfreigabe kann Tagwerk den Lauf nicht messen. Einstellungen > Datenschutz > Ortungsdienste > Tagwerk."
            return
        }
        start = Date()
        distance = 0
        points = []
        pausedTotal = 0
        pauseStart = nil
        last = nil
        recent = []
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        session = CLBackgroundActivitySession()
        manager.startUpdatingLocation()
        phase = .running
        persist(force: true)
    }

    /// Continue a recording that was interrupted (app terminated by the system).
    func resume(_ snap: RecordingSnapshot) {
        start = snap.start
        pausedTotal = snap.pausedTotal + Date().timeIntervalSince(snap.savedAt)
        pauseStart = nil
        distance = snap.distance
        points = snap.points
        last = nil
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        session = CLBackgroundActivitySession()
        manager.startUpdatingLocation()
        phase = .running
    }

    func pause() {
        guard phase == .running else { return }
        pauseStart = Date()
        phase = .paused
        last = nil
        recent = []
        persist(force: true)
    }

    func resumeFromPause() {
        guard phase == .paused, let p = pauseStart else { return }
        pausedTotal += Date().timeIntervalSince(p)
        pauseStart = nil
        phase = .running
        persist(force: true)
    }

    /// Stops and returns the result; the caller stores it.
    func finish() -> (date: String, km: Double, seconds: Int, points: [RoutePoint])? {
        if phase == .paused, let p = pauseStart { pausedTotal += Date().timeIntervalSince(p); pauseStart = nil }
        guard let start else {
            stop()
            return nil
        }
        let result = (date: DayKey.key(for: start), km: distance / 1000, seconds: Int(elapsed().rounded()), points: points)
        stop()
        return result
    }

    func discard() { stop() }

    private func stop() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        session?.invalidate()
        session = nil
        phase = .idle
        start = nil
        RecordingSnapshot.clear()
    }

    private func persist(force: Bool = false) {
        guard let start, force || Date().timeIntervalSince(lastSave) > 20 else { return }
        lastSave = Date()
        let snap = RecordingSnapshot(start: start, pausedTotal: pausedTotal, pauseStart: pauseStart, distance: distance, points: points, savedAt: Date())
        if let data = try? JSONEncoder().encode(snap) { try? data.write(to: RecordingSnapshot.url, options: .atomic) }
    }

    private func handle(_ locations: [CLLocation]) {
        for loc in locations {
            accuracy = loc.horizontalAccuracy
            guard phase == .running else { continue }
            guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= 25, abs(loc.timestamp.timeIntervalSinceNow) < 15 else { continue }
            if let prev = last {
                let d = loc.distance(from: prev)
                let dt = loc.timestamp.timeIntervalSince(prev.timestamp)
                // Jumps faster than 9 m/s are GPS noise, not running.
                if dt > 0, d / dt > 9 { continue }
                if d < 2 { continue }
                distance += d
            }
            last = loc
            let alt = loc.verticalAccuracy >= 0 ? loc.altitude : nil
            if let lp = points.last {
                let lastLoc = CLLocation(latitude: lp.lat, longitude: lp.lon)
                if loc.distance(from: lastLoc) >= 5 || loc.timestamp.timeIntervalSince1970 - lp.t >= 10 {
                    points.append(RoutePoint(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude, alt: alt, t: loc.timestamp.timeIntervalSince1970))
                }
            } else {
                points.append(RoutePoint(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude, alt: alt, t: loc.timestamp.timeIntervalSince1970))
            }
            recent.append((loc.timestamp, distance))
            recent.removeAll { loc.timestamp.timeIntervalSince($0.t) > 30 }
        }
        persist()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated { self.handle(locations) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            self.authorization = status
            if status == .denied || status == .restricted {
                self.lastError = "Standortzugriff ist ausgeschaltet. Einstellungen > Datenschutz > Ortungsdienste > Tagwerk: Beim Verwenden der App."
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated { self.lastError = message }
    }
}
