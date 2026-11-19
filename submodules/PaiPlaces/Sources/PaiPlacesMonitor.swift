import Combine
import CoreLocation
import Foundation
import NetworkExtension
import os
import UIKit

/// Tells pai when the phone arrives at or leaves a saved place: one Core Location geofence per place (the nearest
/// twenty), never continuous GPS, plus the Wi-Fi the phone is on when it enters a fence or the app comes back.
/// Off until the user turns on Place reminders; turning it off stops every fence. The manager is made at launch, so a
/// relaunch in the background for a region event (`launchOptions[.location]`) hands the event to it.
public final class PaiPlacesMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    public static let shared = PaiPlacesMonitor()

    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published public private(set) var monitoredCount = 0
    @Published public private(set) var lastError: String?

    private static let syncInterval: TimeInterval = 3 * 3600
    private let defaults = UserDefaults.standard
    private let enabledKey = "pai.places.enabled"
    private let askedKey = "pai.places.askedAlways"
    private let syncedAtKey = "pai.places.syncedAt"
    private let log = Logger(subsystem: "Paigram", category: "Places")

    private var manager: CLLocationManager?
    private var transport: PaiPlacesTransport?
    private var syncing = false
    /// Fences just started: when Core Location first says the phone is inside one, that counts as arriving.
    private var awaitingFirstState = Set<String>()
    private var foregroundObserver: NSObjectProtocol?

    private override init() {
        isEnabled = UserDefaults.standard.bool(forKey: "pai.places.enabled")
        super.init()
    }

    /// From `application(_:didFinishLaunchingWithOptions:)`, on the main thread.
    public func start(transport: @escaping PaiPlacesTransport) {
        self.transport = transport
        if manager == nil {
            let manager = CLLocationManager()
            manager.delegate = self
            self.manager = manager
            authorization = manager.authorizationStatus
        }
        if foregroundObserver == nil {
            foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                self?.wake()
            }
        }
        if !isEnabled {
            stopAll()
        } else if UIApplication.shared.applicationState != .background {
            wake()
        }
        refreshCount()
    }

    /// The toggle. On asks for Always once (the system shows When In Use first, then offers Always later);
    /// off stops every fence.
    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: enabledKey)
        guard let manager else { return }
        if enabled {
            let status = manager.authorizationStatus
            if status == .notDetermined || (status == .authorizedWhenInUse && !defaults.bool(forKey: askedKey)) {
                defaults.set(true, forKey: askedKey)
                manager.requestAlwaysAuthorization()
            }
            sync(force: true)
            reportWifi()
        } else {
            defaults.removeObject(forKey: syncedAtKey)
            stopAll()
        }
    }

    private func wake() {
        guard isEnabled else { return }
        sync(force: false)
        reportWifi()
    }

    private var isAuthorized: Bool { authorization == .authorizedAlways || authorization == .authorizedWhenInUse }

    // MARK: Fences

    /// Reads `/places` and moves the fences to match, unless it did so in the last few hours.
    public func sync(force: Bool) {
        guard isEnabled, isAuthorized, let transport, !syncing else { return }
        if !force, let at = defaults.object(forKey: syncedAtKey) as? Date, Date().timeIntervalSince(at) < Self.syncInterval { return }
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            lastError = "This device cannot monitor regions"
            return
        }
        syncing = true
        Task { @MainActor in
            defer { self.syncing = false }
            do {
                let data = try await transport(.places)
                let places = try JSONDecoder().decode(PaiPlacesResponse.self, from: data).places
                self.apply(places)
                self.defaults.set(Date(), forKey: self.syncedAtKey)
                self.lastError = nil
            } catch {
                self.log.error("places sync failed: \(String(describing: error), privacy: .public)")
                self.lastError = "Couldn't load places"
            }
        }
    }

    private func apply(_ places: [PaiPlace]) {
        guard let manager, isEnabled else { return }
        let monitored = manager.monitoredRegions.compactMap { region -> PaiPlaceRegion? in
            guard let circle = region as? CLCircularRegion else {
                return PaiPlaceRegion(identifier: region.identifier, lat: 0, lon: 0, radius: 0)
            }
            return PaiPlaceRegion(identifier: circle.identifier, lat: circle.center.latitude, lon: circle.center.longitude, radius: circle.radius)
        }
        let location = manager.location.map { (lat: $0.coordinate.latitude, lon: $0.coordinate.longitude) }
        let diff = PaiPlacesSync.diff(places: places, monitored: monitored, location: location, maximumRadius: manager.maximumRegionMonitoringDistance)
        for region in manager.monitoredRegions where diff.remove.contains(region.identifier) {
            manager.stopMonitoring(for: region)
        }
        for fence in diff.add {
            let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: fence.lat, longitude: fence.lon), radius: fence.radius, identifier: fence.identifier)
            region.notifyOnEntry = true
            region.notifyOnExit = true
            awaitingFirstState.insert(fence.identifier)
            manager.startMonitoring(for: region)
        }
        log.info("places: \(places.count) saved, +\(diff.add.count) -\(diff.remove.count) fences")
        refreshCount()
    }

    private func stopAll() {
        guard let manager else { return }
        for region in manager.monitoredRegions where PaiPlaceRegion.placeId(region.identifier) != nil {
            manager.stopMonitoring(for: region)
        }
        awaitingFirstState.removeAll()
        refreshCount()
    }

    private func refreshCount() {
        monitoredCount = manager?.monitoredRegions.filter { $0.identifier.hasPrefix(PaiPlaceRegion.prefix) }.count ?? 0
    }

    // MARK: Events

    private func moved(_ region: CLRegion, arrived: Bool) {
        guard isEnabled, let place = PaiPlaceRegion.placeId(region.identifier) else { return }
        let request: PaiPlacesRequest = arrived ? .arrived(place: place, at: Date()) : .left(place: place, at: Date())
        send(request) { [weak self] status in
            // The place was deleted on the box: drop its fence with the next list.
            if status == 404 { self?.sync(force: true) }
        }
        if arrived { reportWifi() }
    }

    /// What Wi-Fi the phone is on (needs location access and the Wi-Fi information entitlement); none sends an empty report.
    public func reportWifi() {
        guard isEnabled, isAuthorized else { return }
        NEHotspotNetwork.fetchCurrent { [weak self] network in
            DispatchQueue.main.async {
                self?.send(.wifi(ssid: network?.ssid, bssid: network?.bssid))
            }
        }
    }

    /// Sends in a background task, so a region event that relaunched the app finishes its call before iOS suspends it.
    private func send(_ request: PaiPlacesRequest, failed: ((Int?) -> Void)? = nil) {
        guard let transport else { return }
        let application = UIApplication.shared
        var task = UIBackgroundTaskIdentifier.invalid
        task = application.beginBackgroundTask(withName: "pai.places") {
            application.endBackgroundTask(task)
            task = .invalid
        }
        Task { @MainActor in
            do {
                _ = try await transport(request)
                self.log.info("\(request.method, privacy: .public) \(request.path, privacy: .public) sent")
            } catch {
                self.log.error("\(request.path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                failed?((error as? PaiPlacesHTTPError)?.status)
            }
            if task != .invalid { application.endBackgroundTask(task) }
            task = .invalid
        }
    }

    // MARK: CLLocationManagerDelegate

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if isEnabled, isAuthorized, monitoredCount == 0 { sync(force: true) }
    }

    public func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        awaitingFirstState.remove(region.identifier)
        moved(region, arrived: true)
    }

    public func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        awaitingFirstState.remove(region.identifier)
        moved(region, arrived: false)
    }

    public func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        if awaitingFirstState.contains(region.identifier) { manager.requestState(for: region) }
    }

    public func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard awaitingFirstState.remove(region.identifier) != nil else { return }
        if state == .inside { moved(region, arrived: true) }
    }

    public func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        log.error("fence \(region?.identifier ?? "?", privacy: .public) failed: \(String(describing: error), privacy: .public)")
        if let region { awaitingFirstState.remove(region.identifier) }
        refreshCount()
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        log.error("location failed: \(String(describing: error), privacy: .public)")
    }
}
