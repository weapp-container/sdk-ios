import Foundation
import UIKit
@preconcurrency import CoreLocation
@preconcurrency import CoreBluetooth

private struct BeaconReading: Sendable {
    let uuid: String; let major: Int; let minor: Int; let proximity: Int; let accuracy: Double; let rssi: Int
    var key: String { "\(uuid)/\(major)/\(minor)" }
    var json: WeappJSON { .object(["uuid": .string(uuid), "major": .number(Double(major)), "minor": .number(Double(minor)), "proximity": .number(Double(proximity)), "accuracy": .number(accuracy), "rssi": .number(Double(rssi))]) }
}
private final class BeaconIngress: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: [String: [BeaconReading]] = [:]
    private var failed = false
    private var scheduled = false
    func offer(_ uuid: String, _ values: [BeaconReading], failed: Bool = false) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if latest[uuid] != nil || latest.count < 20 { latest[uuid] = Array(values.prefix(64)) }
        self.failed = self.failed || failed
        if scheduled { return false }; scheduled = true; return true
    }
    func take() -> ([String: [BeaconReading]], Bool) { lock.lock(); defer { lock.unlock() }; let result = (latest, failed); latest.removeAll(); failed = false; scheduled = false; return result }
}

/// A fresh native manager per run makes callbacks from a stopped generation distinguishable.
@MainActor private final class BeaconRangingRun: NSObject, CLLocationManagerDelegate {
    let id = UUID()
    let manager = CLLocationManager()
    let constraints: [CLBeaconIdentityConstraint]
    private nonisolated let ingress = BeaconIngress()
    var receive: ((UUID, [String: [BeaconReading]], Bool) -> Void)?
    init(_ uuids: [UUID]) { constraints = uuids.map { CLBeaconIdentityConstraint(uuid: $0) }; super.init(); manager.delegate = self }
    func start() { for constraint in constraints { manager.startRangingBeacons(satisfying: constraint) } }
    func stop() { for constraint in constraints { manager.stopRangingBeacons(satisfying: constraint) }; receive = nil; manager.delegate = nil }
    nonisolated func locationManager(_ manager: CLLocationManager, didRange beacons: [CLBeacon], satisfying beaconConstraint: CLBeaconIdentityConstraint) {
        let readings = beacons.prefix(64).map { BeaconReading(uuid: $0.uuid.uuidString.lowercased(), major: $0.major.intValue, minor: $0.minor.intValue, proximity: $0.proximity.rawValue, accuracy: $0.proximity == .unknown ? -1 : $0.accuracy, rssi: $0.rssi) }
        if ingress.offer(beaconConstraint.uuid.uuidString.lowercased(), readings) { Task { @MainActor [weak self] in self?.drain() } }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailRangingFor beaconConstraint: CLBeaconIdentityConstraint, error: Error) { if ingress.offer(beaconConstraint.uuid.uuidString.lowercased(), [], failed: true) { Task { @MainActor [weak self] in self?.drain() } } }
    private func drain() { let (values, failed) = ingress.take(); receive?(id, values, failed) }
}

/// Foreground-only CoreLocation iBeacon ranging, with separate app and OS consent.
@MainActor public final class WeappBeaconApis: NSObject, CLLocationManagerDelegate, CBCentralManagerDelegate {
    private weak var presenter: UIViewController?
    private weak var session: WeappContainerSession?
    private let scopes = WeappManagedFileScopes()
    private lazy var consent = WeappAppPermissionConsent(presenter: { [weak self] in self?.presenter }, auxiliaryRoot: { [unowned self] in try self.scopes.auxiliaryRoot($0) })
    private let authorization = CLLocationManager()
    private var authorizationWaiter: CheckedContinuation<Bool, Never>?
    private var radio: CBCentralManager?
    private var radioWaiter: CheckedContinuation<CBManagerState, Never>?
    private var owner: WeappHostApiCall?
    private var pending: WeappHostApiCall?
    private var generation: UInt64 = 0
    private var uuids: [UUID] = []
    private var ignoreBluetoothAvailable = false
    private var visible = true
    private var run: BeaconRangingRun?
    private var values: [String: [BeaconReading]] = [:]
    private var subscriptions: [String: WeappHostApiCall] = [:]
    private var sequences: [String: UInt64] = [:]
    private var observers: [NSObjectProtocol] = []
    public static let potentialApis: Set<String> = ["wx.startBeaconDiscovery", "wx.stopBeaconDiscovery", "wx.getBeacons", "wx.onBeaconUpdate", "wx.offBeaconUpdate", "wx.onBeaconServiceChange", "wx.offBeaconServiceChange"]
    public var supportedApis: Set<String> { CLLocationManager.isRangingAvailable() && Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") is String && Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") is String ? Self.potentialApis : [] }
    public init(presenter: UIViewController) { self.presenter = presenter; super.init(); authorization.delegate = self }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    public func install(in target: WeappContainerSession) throws {
        guard session == nil else { throw failure("wx.startBeaconDiscovery", "adapter already installed", 11005) }; session = target; scopes.bind(target)
        try target.registerHostResourceCleanup("beacon-\(UUID().uuidString)") { self.reset() }
        try target.registerHostVisibilityHandler("beacon-\(UUID().uuidString)") { [weak self] visible in self?.visible = visible; if visible { self?.reconcile() } else { self?.pause() } }
        observers = [NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.pause() } }, NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.reconcile() } }]
        for api in supportedApis.sorted() { try target.registerApiHandler(api) { [weak self] call in guard let self, call.context != .null, !call.cancellation.isCancelled else { throw CancellationError() }; return try await self.invoke(api, call) } }
    }
    private func failure(_ api: String, _ text: String, _ code: Int) -> WeappHostError { WeappHostError(code: code == 11000 ? .unsupported : .invalidRequest, message: text, details: ["errMsg": .string("\(api):fail \(text)"), "errCode": .number(Double(code))]) }
    private func ok(_ api: String, _ data: [String: WeappJSON] = [:]) -> WeappJSON { .object(data.merging(["errMsg": .string("\(api):ok"), "errCode": .number(0)]) { _, value in value }) }
    private var foreground: Bool { visible && UIApplication.shared.applicationState != .background && presenter?.viewIfLoaded?.window != nil }
    private var locationAvailable: Bool { CLLocationManager.locationServicesEnabled() && [.authorizedAlways, .authorizedWhenInUse].contains(authorization.authorizationStatus) && authorization.accuracyAuthorization == .fullAccuracy }
    private var available: Bool { locationAvailable && CBCentralManager.authorization == .allowedAlways && (radio?.state == .poweredOn || ignoreBluetoothAvailable && radio?.state == .poweredOff) }
    private var service: [String: WeappJSON] { ["available": .bool(available), "discovering": .bool(run != nil)] }
    private var snapshot: WeappJSON { .array(values.keys.sorted().flatMap { values[$0] ?? [] }.prefix(64).map(\.json)) }
    private func invoke(_ api: String, _ call: WeappHostApiCall) async throws -> WeappJSON {
        let value = call.payload
        if api.hasPrefix("wx.off") { if let id = value["subscriptionId"].string { remove(id) }; return ok(api) }
        if api.hasPrefix("wx.on") {
            guard let id = value["subscriptionId"].string, subscriptions[id] == nil, subscriptions.count < 32 else { throw failure(api, "subscription limit or invalid identity", 11006) }
            subscriptions[id] = call; sequences[id] = 0; call.cancellation.retainUntilCancelled(); call.cancellation.onCancel { [weak self] in self?.remove(id) }; return ok(api)
        }
        if api == "wx.getBeacons" { guard owner != nil else { throw failure(api, "not startBeaconDiscovery", 11004) }; return ok(api, ["beacons": snapshot]) }
        if api == "wx.stopBeaconDiscovery" { guard owner != nil || pending != nil else { throw failure(api, "not startBeaconDiscovery", 11004) }; let previous = owner; stop(); if let previous { emit("wx.onBeaconServiceChange", previous, service) }; return ok(api) }
        guard owner == nil, pending == nil else { throw failure(api, "already start", 11003) }
        guard foreground, let list = value["uuids"].array, (1...20).contains(list.count), list.allSatisfy({ $0.string.flatMap(UUID.init(uuidString:)) != nil }) else { throw failure(api, "1...20 valid UUIDs and foreground host required", 11006) }
        let requested = Array(Set(list.compactMap { $0.string.flatMap(UUID.init(uuidString:)) }))
        if value["ignoreBluetoothAvailable"] != .null && value["ignoreBluetoothAvailable"].bool == nil { throw failure(api, "ignoreBluetoothAvailable must be boolean", 11006) }
        pending = call; let accepted = generation
        defer { if pending?.id == call.id { pending = nil } }
        call.cancellation.onCancel { [weak self] in guard self?.pending?.id == call.id else { return }; self?.authorizationWaiter?.resume(returning: false); self?.authorizationWaiter = nil; self?.radioWaiter?.resume(returning: .unknown); self?.radioWaiter = nil }
        guard try await consent.request(call, "scope.userLocation"), try await consent.request(call, "scope.bluetooth") else { throw failure(api, "app authorization denied", 11002) }
        guard pending?.id == call.id, accepted == generation, foreground, !call.cancellation.isCancelled else { throw CancellationError() }
        guard await authorizeLocation() else { throw failure(api, "location service unavailable", 11002) }
        guard pending?.id == call.id, accepted == generation, foreground, !call.cancellation.isCancelled else { throw CancellationError() }
        let state = await authorizeBluetooth()
        try Task.checkCancellation()
        guard pending?.id == call.id, accepted == generation, foreground, !call.cancellation.isCancelled else { throw CancellationError() }
        guard CBCentralManager.authorization == .allowedAlways, state == .poweredOn || value["ignoreBluetoothAvailable"].bool == true && state == .poweredOff else { throw failure(api, "bluetooth service unavailable", 11001) }
        owner = call; uuids = requested; ignoreBluetoothAvailable = value["ignoreBluetoothAvailable"].bool == true; values.removeAll(); reconcile(); return ok(api)
    }
    private func authorizeLocation() async -> Bool {
        guard CLLocationManager.locationServicesEnabled() else { return false }
        if authorization.authorizationStatus != .notDetermined { return locationAvailable }
        return await withCheckedContinuation { authorizationWaiter = $0; authorization.requestWhenInUseAuthorization() }
    }
    private func authorizeBluetooth() async -> CBManagerState {
        if let radio, radio.state != .unknown && radio.state != .resetting { return radio.state }
        return await withCheckedContinuation { radioWaiter = $0; if radio == nil { radio = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false]) } }
    }
    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { Task { @MainActor [weak self] in guard let self, manager === self.authorization else { return }; if manager.authorizationStatus != .notDetermined { let waiter = self.authorizationWaiter; self.authorizationWaiter = nil; waiter?.resume(returning: self.locationAvailable) }; self.reconcile() } }
    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) { Task { @MainActor [weak self] in guard let self, central === self.radio else { return }; if central.state != .unknown && central.state != .resetting { let waiter = self.radioWaiter; self.radioWaiter = nil; waiter?.resume(returning: central.state) }; self.reconcile() } }
    private func reconcile() {
        guard let owner else { return }
        if available && foreground && !owner.cancellation.isCancelled {
            if run == nil {
                let active = BeaconRangingRun(uuids); run = active
                active.receive = { [weak self] id, readings, failed in
                    guard let self, self.run?.id == id, self.foreground, self.owner?.id == owner.id else { return }
                    if failed { self.run?.stop(); self.run = nil; self.emit("wx.onBeaconServiceChange", owner, self.service); return }
                    for (uuid, value) in readings { self.values[uuid] = value }
                    self.emit("wx.onBeaconUpdate", owner, ["beacons": self.snapshot])
                }
                active.start()
            }
        } else { run?.stop(); run = nil }
        emit("wx.onBeaconServiceChange", owner, service)
    }
    private func pause() {
        generation += 1; let previous = pending; pending = nil; previous?.cancellation.cancel()
        authorizationWaiter?.resume(returning: false); authorizationWaiter = nil; radioWaiter?.resume(returning: .unknown); radioWaiter = nil
        run?.stop(); run = nil; if let owner { emit("wx.onBeaconServiceChange", owner, service) }
    }
    private func stop() { pause(); owner = nil; uuids.removeAll(); values.removeAll() }
    private func remove(_ id: String) { subscriptions.removeValue(forKey: id); sequences.removeValue(forKey: id) }
    private func emit(_ method: String, _ owner: WeappHostApiCall, _ value: [String: WeappJSON]) {
        for (id, call) in Array(subscriptions) where call.method == method && !call.cancellation.isCancelled && call.context["sessionId"] == owner.context["sessionId"] && call.context["application"] == owner.context["application"] && call.context["account"] == owner.context["account"] {
            let next = (sequences[id] ?? 0) + 1; guard next <= 9007199254740991 else { remove(id); continue }; sequences[id] = next
            do { _ = try session?.emitHostApiEvent(["sessionId": call.context["sessionId"], "accountEpoch": call.context["account"]["epoch"], "subscriptionId": .string(id), "sequence": .string(String(next)), "value": .object(value)]) }
            catch { run?.stop(); run = nil; session?.report(error); return }
        }
    }
    private func reset() { stop(); subscriptions.removeAll(); sequences.removeAll(); consent.reset(); radio?.delegate = nil; radio = nil }
    public func close() { reset(); for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers.removeAll(); session = nil }
}
