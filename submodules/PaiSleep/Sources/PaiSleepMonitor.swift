import Combine
import Foundation
import HealthKit
import os
import UIKit

/// Posts a JSON body to pai (`POST <path>`) with the app's pai auth; throws for a non-2xx answer.
public typealias PaiSleepTransport = (_ path: String, _ body: [String: Any]) async throws -> Data

/// Sends each night's sleep from Health to pai (`POST /activity/sleep`), which puts it on the Balance calendar.
/// On by default; asks for Health read access once, on the first launch signed in to pai or when the toggle is turned
/// on. Uploads when the app becomes active and when HealthKit wakes it for new sleep data (observer query with
/// background delivery, registered at launch so a background relaunch reaches it). Keeps the end of the last night
/// sent; the first run backfills 14 days.
public final class PaiSleepMonitor: NSObject, ObservableObject {
    public static let shared = PaiSleepMonitor()

    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var lastNight: Date?
    @Published public private(set) var lastError: String?

    private let defaults = UserDefaults.standard
    private let enabledKey = "pai.sleep.enabled"
    private let askedKey = "pai.sleep.asked"
    private let anchorKey = "pai.sleep.anchor"
    private let lastNightKey = "pai.sleep.lastNight"
    private let log = Logger(subsystem: "Paigram", category: "Sleep")

    private let store: HKHealthStore? = HKHealthStore.isHealthDataAvailable() ? HKHealthStore() : nil
    private let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
    private var transport: PaiSleepTransport?
    private var isSignedIn: () -> Bool = { false }
    private var observer: HKObserverQuery?
    private var activeObserver: NSObjectProtocol?
    private var uploading = false

    public var isAvailable: Bool { store != nil }

    private override init() {
        isEnabled = UserDefaults.standard.object(forKey: "pai.sleep.enabled") as? Bool ?? true
        lastNight = UserDefaults.standard.object(forKey: "pai.sleep.lastNight") as? Date
        super.init()
    }

    /// From `application(_:didFinishLaunchingWithOptions:)`, on the main thread.
    public func start(transport: @escaping PaiSleepTransport, isSignedIn: @escaping () -> Bool) {
        self.transport = transport
        self.isSignedIn = isSignedIn
        guard store != nil else { return }
        if activeObserver == nil {
            activeObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.wake()
            }
        }
        if isEnabled { observe() }
    }

    /// The toggle: on asks for access (once) and uploads; off stops background delivery.
    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: enabledKey)
        if enabled {
            defaults.set(false, forKey: askedKey)
            observe()
            wake()
        } else {
            stopObserving()
        }
    }

    /// App active: the first time signed in, the access prompt; then whatever nights are new.
    private func wake() {
        guard isEnabled, isSignedIn() else { return }
        Task { @MainActor in
            await self.requestAccessIfNeeded()
            await self.upload()
        }
    }

    @MainActor
    private func requestAccessIfNeeded() async {
        guard let store, !defaults.bool(forKey: askedKey) else { return }
        let read: Set<HKObjectType> = [sleepType]
        do {
            let status: HKAuthorizationRequestStatus = try await withCheckedThrowingContinuation { continuation in
                store.getRequestStatusForAuthorization(toShare: [], read: read) { status, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: status) }
                }
            }
            if status == .shouldRequest {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    store.requestAuthorization(toShare: [], read: read) { _, error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                }
            }
            defaults.set(true, forKey: askedKey)
        } catch {
            log.error("health access failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Background delivery

    private func observe() {
        guard let store, observer == nil else { return }
        let query = HKObserverQuery(sampleType: sleepType, predicate: nil) { [weak self] _, completion, error in
            guard let self, error == nil else {
                completion()
                return
            }
            Task { @MainActor in
                await self.uploadInBackgroundTask()
                completion()
            }
        }
        observer = query
        store.execute(query)
        store.enableBackgroundDelivery(for: sleepType, frequency: .hourly) { [weak self] ok, error in
            if !ok { self?.log.error("background delivery: \(String(describing: error), privacy: .public)") }
        }
    }

    private func stopObserving() {
        guard let store else { return }
        if let observer { store.stop(observer) }
        observer = nil
        store.disableBackgroundDelivery(for: sleepType) { _, _ in }
    }

    @MainActor
    private func uploadInBackgroundTask() async {
        // Before the access prompt Health answers nothing useful; the first wake asks, then uploads.
        guard isEnabled, isSignedIn(), defaults.bool(forKey: askedKey) else { return }
        let application = UIApplication.shared
        var task = UIBackgroundTaskIdentifier.invalid
        task = application.beginBackgroundTask(withName: "pai.sleep") {
            application.endBackgroundTask(task)
            task = .invalid
        }
        await upload()
        if task != .invalid { application.endBackgroundTask(task) }
    }

    // MARK: Upload

    /// Reads sleep since the last night sent (14 days back on the first run) and posts each settled night, oldest
    /// first, moving the anchor after each one so a failure retries from there next time.
    @MainActor
    private func upload() async {
        guard isEnabled, let store, let transport, !uploading else { return }
        uploading = true
        defer { uploading = false }
        let now = Date()
        let (anchor, from) = PaiSleepNights.queryStart(anchor: defaults.object(forKey: anchorKey) as? Date, now: now)
        do {
            let samples = try await self.samples(store: store, from: from, to: now)
            let nights = PaiSleepNights.toUpload(PaiSleepNights.sessions(samples), anchor: anchor, now: now)
            for night in nights {
                _ = try await transport("/activity/sleep", night.body)
                defaults.set(night.end, forKey: anchorKey)
                defaults.set(night.start, forKey: lastNightKey)
                lastNight = night.start
            }
            if !nights.isEmpty { log.info("sleep: sent \(nights.count) night(s)") }
            lastError = nil
        } catch {
            log.error("sleep upload failed: \(String(describing: error), privacy: .public)")
            // Health is unreadable while the phone is locked; the next unlock or wake retries quietly.
            if let code = (error as? HKError)?.code, [HKError.Code.errorDatabaseInaccessible, .errorAuthorizationNotDetermined].contains(code) { return }
            lastError = "Couldn't send sleep"
        }
    }

    private func samples(store: HKHealthStore, from: Date, to: Date) async throws -> [PaiSleepSample] {
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let samples = (results as? [HKCategorySample] ?? []).compactMap { sample -> PaiSleepSample? in
                    guard let stage = PaiSleepSample.Stage(rawValue: sample.value) else { return nil }
                    let source = sample.device?.name ?? sample.sourceRevision.source.name
                    return PaiSleepSample(start: sample.startDate, end: sample.endDate, stage: stage, source: source)
                }
                continuation.resume(returning: samples)
            }
            store.execute(query)
        }
    }
}
