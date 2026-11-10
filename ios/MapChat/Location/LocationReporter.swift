import CoreLocation
import CoreMotion
import Foundation

/// Collects location + barometer readings and uploads them, with
/// battery-friendly settings:
///   * foreground: ~10 m accuracy, 25 m distance filter
///   * background: significant-change monitoring only (cell/Wi-Fi based,
///     very low power), plus automatic pausing when stationary
///   * uploads are throttled to at most one every 30 s unless the user moved
///     more than 50 m
@MainActor
final class LocationReporter: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var relativeAltitudeM: Double?
    @Published var isSharingPaused = false

    private let manager = CLLocationManager()
    private let altimeter = CMAltimeter()
    private var pressureKPa: Double?
    private var lastUpload: (date: Date, location: CLLocation)?
    private let upload: (CLLocation, Double?, Double?) async -> Void

    nonisolated static let minUploadInterval: TimeInterval = 30
    nonisolated static let minUploadDistance: CLLocationDistance = 50

    init(upload: @escaping (CLLocation, Double?, Double?) async -> Void) {
        self.upload = upload
        super.init()
        manager.delegate = self
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = true
        manager.showsBackgroundLocationIndicator = true
        authorization = manager.authorizationStatus
        configureForeground()
    }

    func requestPermission() {
        // Ask for "When In Use" first; iOS offers "Always" later in context.
        manager.requestWhenInUseAuthorization()
    }

    func requestAlwaysPermission() {
        manager.requestAlwaysAuthorization()
    }

    func start() {
        manager.startUpdatingLocation()
        startAltimeter()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        altimeter.stopRelativeAltitudeUpdates()
    }

    func configureForeground() {
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 25
        manager.stopMonitoringSignificantLocationChanges()
        if authorization == .authorizedWhenInUse || authorization == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func configureBackground() {
        manager.stopUpdatingLocation()
        if authorization == .authorizedAlways, !isSharingPaused {
            manager.allowsBackgroundLocationUpdates = true
            manager.startMonitoringSignificantLocationChanges()
        }
    }

    private func startAltimeter() {
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            Task { @MainActor in
                self?.relativeAltitudeM = data.relativeAltitude.doubleValue
                self?.pressureKPa = data.pressure.doubleValue
            }
        }
    }

    /// Decides whether a new fix is worth uploading (pure, unit-testable).
    nonisolated static func shouldUpload(new: CLLocation, last: (date: Date, location: CLLocation)?, now: Date = Date()) -> Bool {
        guard new.horizontalAccuracy >= 0, new.horizontalAccuracy <= 200 else { return false }
        guard let last else { return true }
        return now.timeIntervalSince(last.date) >= minUploadInterval
            || new.distance(from: last.location) >= minUploadDistance
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if status == .authorizedWhenInUse || status == .authorizedAlways { self.start() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.lastLocation = loc
            guard !self.isSharingPaused, Self.shouldUpload(new: loc, last: self.lastUpload) else { return }
            self.lastUpload = (Date(), loc)
            await self.upload(loc, self.relativeAltitudeM, self.pressureKPa)
        }
    }
}
