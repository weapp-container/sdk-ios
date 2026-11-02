import Foundation
import UIKit
@preconcurrency import CoreLocation
@preconcurrency import Network
@preconcurrency import NetworkExtension

/// Explicit host opt-in. The OS still enforces the application's signed entitlements.
public struct WeappWifiConfiguration: Sendable {
    public let connectToNetworks: Bool
    public let readCurrentNetwork: Bool
    /// Enable the corresponding Hotspot Configuration and Access Wi-Fi Information
    /// capabilities in the host target before enabling these operations.
    public init(connectToNetworks: Bool, readCurrentNetwork: Bool) {
        self.connectToNetworks = connectToNetworks; self.readCurrentNetwork = readCurrentNetwork
    }
}

/// iOS has no general-purpose scan API. Only genuine public current-SSID and join-once operations are exposed.
@MainActor public final class WeappWifiApis: NSObject, CLLocationManagerDelegate {
    private weak var presenter: UIViewController?
    private weak var session: WeappContainerSession?
    private let configuration: WeappWifiConfiguration
    private let scopes = WeappManagedFileScopes()
    private lazy var consent = WeappAppPermissionConsent(presenter: { [weak self] in self?.presenter }, auxiliaryRoot: { [unowned self] in try self.scopes.auxiliaryRoot($0) })
    private let location = CLLocationManager()
    private var authorization: CheckedContinuation<Bool, Never>?
    private var started: WeappHostApiCall?
    private var starting: WeappHostApiCall?
    private var connecting: WeappHostApiCall?
    private var generation: UInt64 = 0
    private var visible = true
    private var monitor: NWPathMonitor?
    private var refreshTask: Task<Void, Never>?
    private var refreshPending = false
    private var applyTasks: [UUID: Task<Void, Error>] = [:]
    private var resetTask: Task<Void, Never>?
    private var ownedConfigurations: Set<String> = []
    private var lastSSID: String?
    private var subscriptions: [String: WeappHostApiCall] = [:]
    private var sequences: [String: UInt64] = [:]
    private var observers: [NSObjectProtocol] = []
    public static let potentialApis: Set<String> = ["wx.startWifi", "wx.stopWifi", "wx.connectWifi", "wx.getConnectedWifi", "wx.onWifiConnectedWithPartialInfo", "wx.offWifiConnectedWithPartialInfo"]
    public var supportedApis: Set<String> {
        guard configuration.readCurrentNetwork, Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") is String else { return [] }
        var result: Set<String> = ["wx.startWifi", "wx.stopWifi", "wx.getConnectedWifi", "wx.onWifiConnectedWithPartialInfo", "wx.offWifiConnectedWithPartialInfo"]
        if configuration.connectToNetworks { result.insert("wx.connectWifi") }; return result
    }
    public init(presenter: UIViewController, configuration: WeappWifiConfiguration) { self.presenter = presenter; self.configuration = configuration; super.init(); location.delegate = self }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    public func install(in target: WeappContainerSession) throws {
        guard session == nil else { throw failure("wx.startWifi", "adapter already installed", 12010) }; session = target; scopes.bind(target)
        try target.registerHostAsyncResourceCleanup("wifi-\(UUID().uuidString)") { await self.reset() }
        try target.registerHostVisibilityHandler("wifi-\(UUID().uuidString)") { [weak self] visible in self?.visible = visible; if visible { self?.queueRefresh() } else { self?.pause() } }
        observers = [NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.pause() } }, NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.queueRefresh() } }]
        for api in supportedApis.sorted() { try target.registerApiHandler(api) { [weak self] call in guard let self, call.context != .null, !call.cancellation.isCancelled else { throw CancellationError() }; return try await self.invoke(api, call) } }
    }
    private func failure(_ api: String, _ text: String, _ code: Int) -> WeappHostError { WeappHostError(code: code == 12001 ? .unsupported : code == 12007 ? .permissionDenied : .invalidRequest, message: text, details: ["errMsg": .string("\(api):fail \(text)"), "errCode": .number(Double(code))]) }
    private func ok(_ api: String, _ data: [String: WeappJSON] = [:]) -> WeappJSON { .object(data.merging(["errMsg": .string("\(api):ok"), "errCode": .number(0)]) { _, value in value }) }
    private var foreground: Bool { visible && UIApplication.shared.applicationState != .background && presenter?.viewIfLoaded?.window != nil }
    private var locationAvailable: Bool { CLLocationManager.locationServicesEnabled() && [.authorizedAlways, .authorizedWhenInUse].contains(location.authorizationStatus) && location.accuracyAuthorization == .fullAccuracy }
    private func ensure(_ call: WeappHostApiCall, _ accepted: UInt64) throws { guard generation == accepted, foreground, !call.cancellation.isCancelled, !Task.isCancelled else { throw CancellationError() } }
    private func invoke(_ api: String, _ call: WeappHostApiCall) async throws -> WeappJSON {
        let value = call.payload
        if api == "wx.offWifiConnectedWithPartialInfo" { if let id = value["subscriptionId"].string { remove(id) }; return ok(api) }
        if api == "wx.onWifiConnectedWithPartialInfo" {
            guard let id = value["subscriptionId"].string, subscriptions[id] == nil, subscriptions.count < 32 else { throw failure(api, "subscription identity or limit", 12010) }
            subscriptions[id] = call; sequences[id] = 0; call.cancellation.retainUntilCancelled(); call.cancellation.onCancel { [weak self] in self?.remove(id) }; return ok(api)
        }
        if api == "wx.stopWifi" { await reset(keepSubscriptions: true); return ok(api) }
        guard resetTask == nil else { throw failure(api, "Previous Wi-Fi resource retirement is still pending", 12004) }
        if api == "wx.startWifi" {
            guard starting == nil else { throw failure(api, "duplicate request", 12004) }
            guard foreground else { throw failure(api, "weapp in background", 12011) }
            starting = call; let accepted = generation
            defer { if starting?.id == call.id { starting = nil } }
            guard try await consent.request(call, "scope.userLocation") else { throw failure(api, "user denied", 12007) }
            try ensure(call, accepted)
            guard await authorizeLocation(call) else { throw failure(api, "precise location authorization required for current network information", 12007) }
            try ensure(call, accepted)
            if started == nil { started = call; let monitor = NWPathMonitor(requiredInterfaceType: .wifi); self.monitor = monitor; monitor.pathUpdateHandler = { [weak self] _ in MainActor.assumeIsolated { self?.queueRefresh() } }; monitor.start(queue: .main) }
            queueRefresh(); return ok(api)
        }
        guard started != nil else { throw failure(api, "not init", 12000) }
        guard foreground else { throw failure(api, "weapp in background", 12011) }
        guard locationAvailable else { throw failure(api, "precise location authorization required", 12007) }
        if api == "wx.getConnectedWifi" {
            guard value["partialInfo"].bool == true else { throw failure(api, "Public iOS current-network API supplies no valid frequency/signalStrength; request partialInfo:true", 12001) }
            let accepted = generation, network = await currentNetwork(); try ensure(call, accepted)
            guard let network else { throw failure(api, "No current network information; Access Wi-Fi Information entitlement and OS eligibility are required", 12007) }
            return ok(api, ["wifi": .object(["SSID": .string(network.ssid)])])
        }
        return try await connect(api, call)
    }
    private func authorizeLocation(_ call: WeappHostApiCall) async -> Bool {
        guard CLLocationManager.locationServicesEnabled() else { return false }
        if location.authorizationStatus != .notDetermined { return locationAvailable }
        let id = call.id
        return await withCheckedContinuation { continuation in
            authorization = continuation
            call.cancellation.onCancel { [weak self] in guard self?.starting?.id == id else { return }; self?.authorization?.resume(returning: false); self?.authorization = nil }
            location.requestWhenInUseAuthorization()
        }
    }
    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { Task { @MainActor [weak self] in guard let self, manager === self.location, manager.authorizationStatus != .notDetermined else { return }; let pending = self.authorization; self.authorization = nil; pending?.resume(returning: self.locationAvailable); if !self.locationAvailable { self.pause() } else { self.queueRefresh() } } }
    private func currentNetwork() async -> NEHotspotNetwork? { await withCheckedContinuation { continuation in NEHotspotNetwork.fetchCurrent { continuation.resume(returning: $0) } } }
    private func configuredSSIDs() async -> [String] { await withCheckedContinuation { continuation in NEHotspotConfigurationManager.shared.getConfiguredSSIDs { continuation.resume(returning: $0) } } }
    private func connect(_ api: String, _ call: WeappHostApiCall) async throws -> WeappJSON {
        guard configuration.connectToNetworks else { throw failure(api, "Host must enable Hotspot Configuration capability", 12001) }
        guard connecting == nil, applyTasks.isEmpty, ownedConfigurations.isEmpty else { throw failure(api, "duplicate request; stopWifi retires the prior join-once configuration", 12004) }
        let value = call.payload
        guard let ssid = value["SSID"].string, (1...32).contains(ssid.utf8.count), !ssid.contains("\0"), let password = value["password"].string else { throw failure(api, "invalid SSID or password", 12008) }
        guard value["maunal"] == .null || value["maunal"].bool == false, value["BSSID"] == .null || value["BSSID"].string == "" else { throw failure(api, "Public iOS API cannot open Wi-Fi settings or pin a BSSID", 12001) }
        guard password.isEmpty || (8...63).contains(password.utf8.count) && password.utf8.allSatisfy({ (32...126).contains($0) }) else { throw failure(api, "Only open or WPA/WPA2 ASCII passphrases are supported", 12014) }
        connecting = call; let accepted = generation
        var succeeded = false
        defer { if connecting?.id == call.id { connecting = nil }; if !succeeded, ownedConfigurations.remove(ssid) != nil { NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid) } }
        if let current = await currentNetwork(), current.ssid == ssid { try ensure(call, accepted); return ok(api) }
        let existing = await configuredSSIDs(); try ensure(call, accepted)
        guard !existing.contains(ssid) else { throw failure(api, "SSID already has a host-owned app configuration; adapter will not replace it", 12009) }
        guard try await confirmNetwork(call, ssid) else { throw failure(api, "user denied", 12007) }; try ensure(call, accepted)
        let native = password.isEmpty ? NEHotspotConfiguration(ssid: ssid) : NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: false)
        native.joinOnce = true
        let token = UUID()
        let task = Task { @MainActor [self] in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NEHotspotConfigurationManager.shared.apply(native) { error in Task { @MainActor in
                    if let error { continuation.resume(throwing: error) }
                    else { if self.generation != accepted || call.cancellation.isCancelled || !self.foreground { NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid) } else { self.ownedConfigurations.insert(ssid) }; continuation.resume() }
                } }
            }
        }
        applyTasks[token] = task; defer { applyTasks.removeValue(forKey: token) }
        do { try await task.value }
        catch {
            try ensure(call, accepted)
            let native = error as NSError
            if native.domain == NEHotspotConfigurationErrorDomain, native.code == NEHotspotConfigurationError.alreadyAssociated.rawValue { /* Verify actual association below. */ }
            else { let code = native.domain == NEHotspotConfigurationErrorDomain && native.code == NEHotspotConfigurationError.userDenied.rawValue ? 12007 : 12009; throw failure(api, "System Wi-Fi configuration failed: \(error.localizedDescription)", code) }
        }
        try ensure(call, accepted)
        var associated = false
        for _ in 0..<20 {
            let current = await currentNetwork(); try ensure(call, accepted)
            if current?.ssid == ssid { associated = true; break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        guard associated else { throw failure(api, "Configuration completed but actual SSID association was not confirmed; no success claim", 12010) }
        succeeded = true
        queueRefresh(); return ok(api)
    }
    private func confirmNetwork(_ call: WeappHostApiCall, _ ssid: String) async throws -> Bool {
        guard let presenter, foreground, presenter.presentedViewController == nil else { throw failure("wx.connectWifi", "Visible idle presenter required", 12011) }
        return try await withCheckedThrowingContinuation { continuation in
            let alert = UIAlertController(title: "连接 Wi-Fi", message: "小程序 \(call.context["application"]["appId"].string ?? "") 请求临时连接 \(ssid)。这可能改变设备当前的网络；系统仍会要求必要的授权。", preferredStyle: .alert)
            var settled = false
            let finish: (Result<Bool, Error>) -> Void = { [weak alert] result in guard !settled else { return }; settled = true; alert?.dismiss(animated: false); continuation.resume(with: result) }
            alert.addAction(UIAlertAction(title: "继续连接", style: .default) { _ in finish(.success(true)) })
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in finish(.success(false)) })
            call.cancellation.onCancel { finish(.failure(CancellationError())) }; presenter.present(alert, animated: true)
        }
    }
    private func queueRefresh() {
        guard started != nil, foreground, locationAvailable else { return }
        refreshPending = true; guard refreshTask == nil else { return }
        let accepted = generation
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.refreshPending = false; let current = await self.currentNetwork()
                guard self.generation == accepted, self.foreground, !Task.isCancelled else { break }
                if let current, let owner = self.started, self.lastSSID != current.ssid { self.lastSSID = current.ssid; self.emit(owner, current.ssid) }
                else if current == nil { self.lastSSID = nil }
            } while self.refreshPending
            self.refreshTask = nil
            if self.refreshPending, self.foreground { self.queueRefresh() }
        }
    }
    private func emit(_ owner: WeappHostApiCall, _ ssid: String) {
        for (id, call) in Array(subscriptions) where !call.cancellation.isCancelled && call.context["sessionId"] == owner.context["sessionId"] && call.context["application"] == owner.context["application"] && call.context["account"] == owner.context["account"] {
            let next = (sequences[id] ?? 0) + 1; guard next <= 9007199254740991 else { remove(id); continue }; sequences[id] = next
            do { _ = try session?.emitHostApiEvent(["sessionId": call.context["sessionId"], "accountEpoch": call.context["account"]["epoch"], "subscriptionId": .string(id), "sequence": .string(String(next)), "value": .object(["wifi": .object(["SSID": .string(ssid)])])]) }
            catch { refreshPending = false; session?.report(error); return }
        }
    }
    private func remove(_ id: String) { subscriptions.removeValue(forKey: id); sequences.removeValue(forKey: id) }
    private func pause() { generation += 1; starting?.cancellation.cancel(); connecting?.cancellation.cancel(); authorization?.resume(returning: false); authorization = nil; refreshTask?.cancel(); refreshPending = false; lastSSID = nil; consent.reset() }
    private func reset(keepSubscriptions: Bool = false) async {
        if let resetTask { await resetTask.value; if !keepSubscriptions { subscriptions.removeAll(); sequences.removeAll() }; return }
        let task = Task { @MainActor in await self.resetResources() }; resetTask = task
        await task.value; resetTask = nil
        if !keepSubscriptions { subscriptions.removeAll(); sequences.removeAll() }
    }
    private func resetResources() async {
        pause(); monitor?.cancel(); monitor = nil; started = nil
        let pending = Array(applyTasks.values); for task in pending { _ = await task.result }
        for ssid in ownedConfigurations { NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid) }; ownedConfigurations.removeAll()
        if let refreshTask { await refreshTask.value }; self.refreshTask = nil
        starting = nil; connecting = nil
    }
    public func close() async { await reset(); for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers.removeAll(); session = nil }
}
