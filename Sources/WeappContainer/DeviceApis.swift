import Foundation
import UIKit
@preconcurrency import CoreLocation
@preconcurrency import CoreMotion
@preconcurrency import Network
@preconcurrency import AVFoundation
import AudioToolbox

/// Coalesce native location callbacks before scheduling work on the main actor.
private final class LocationCallbackIngress: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CLLocation]?
    private var error: Error?
    private var scheduled = false
    func offer(_ locations: [CLLocation]?, _ failure: Error?) -> Bool { lock.lock(); defer { lock.unlock() }; if let locations { values = locations.suffix(1).map { $0 } }; if let failure { error = failure }; if scheduled { return false }; scheduled = true; return true }
    func take() -> ([CLLocation]?, Error?) { lock.lock(); defer { lock.unlock() }; let result = (values, error); values = nil; error = nil; scheduled = false; return result }
    func clear() { lock.lock(); values = nil; error = nil; lock.unlock() }
}

/// Explicit native implementations. Install after trusted configuration and before load.
/// Keep this adapter alive and close it when the host feature/scene is retired.
@MainActor public final class WeappDeviceApis: NSObject, CLLocationManagerDelegate {
    private let scopes = WeappManagedFileScopes()
    private lazy var consent = WeappAppPermissionConsent(presenter: { [weak self] in self?.presenter }, auxiliaryRoot: { [unowned self] in try self.scopes.auxiliaryRoot($0) })
    private weak var presenter: UIViewController?
    private weak var session: WeappContainerSession?
    private let location = CLLocationManager()
    private let motion = CMMotionManager()
    private var resources: [String: () -> Void] = [:]
    private var subscriptions: [String: WeappHostApiCall] = [:]
    private var sequences: [String: UInt64] = [:]
    private var locations: [String: (Bool, CheckedContinuation<WeappJSON, Error>)] = [:]
    private var locationAuthorization: [String: CheckedContinuation<Bool, Never>] = [:]
    private nonisolated let locationIngress = LocationCallbackIngress()
    private var locationStreamOwner: WeappHostApiCall?
    private var locationStreamStart: WeappHostApiCall?
    private var locationGeneration: UInt64 = 0
    private var locationVisible = true
    private var locationObservers: [NSObjectProtocol] = []
    private var toast: UIView?
    private var loading: UIView?
    private var brightnessBefore: CGFloat?
    private var idleTimerBefore: Bool?
    private var batteryMonitoringBefore: Bool?
    public let supportedApis: Set<String> = [
        "wx.getClipboardData", "wx.setClipboardData", "wx.getNetworkType", "wx.onNetworkStatusChange", "wx.offNetworkStatusChange",
        "wx.getBatteryInfo", "wx.getScreenBrightness", "wx.setScreenBrightness", "wx.setKeepScreenOn", "wx.vibrateLong", "wx.vibrateShort",
        "wx.showToast", "wx.hideToast", "wx.showLoading", "wx.hideLoading", "wx.showModal", "wx.showActionSheet", "wx.makePhoneCall",
        "wx.openAppAuthorizeSetting", "wx.getSetting", "wx.authorize", "wx.getLocation", "wx.getFuzzyLocation",
        "wx.startLocationUpdate", "wx.stopLocationUpdate", "wx.onLocationChange", "wx.offLocationChange", "wx.onLocationChangeError", "wx.offLocationChangeError",
        "wx.startAccelerometer", "wx.stopAccelerometer", "wx.onAccelerometerChange", "wx.offAccelerometerChange",
        "wx.startGyroscope", "wx.stopGyroscope", "wx.onGyroscopeChange", "wx.offGyroscopeChange",
        "wx.startCompass", "wx.stopCompass", "wx.onCompassChange", "wx.offCompassChange",
    ]
    public init(presenter: UIViewController) { self.presenter = presenter; super.init(); location.delegate = self }
    deinit { for observer in locationObservers { NotificationCenter.default.removeObserver(observer) } }
    public func install(in target: WeappContainerSession) throws {
        guard session == nil else { throw WeappHostError(code: .invalidRequest, message: "Device adapter already installed") }
        session = target; scopes.bind(target)
        try target.registerHostResourceCleanup("device-\(UUID().uuidString)") { self.resetResources() }
        try target.registerHostVisibilityHandler("location-\(UUID().uuidString)") { [weak self] visible in self?.locationVisible = visible; if visible { self?.reconcileLocation() } else { self?.pauseLocations() } }
        locationObservers = [
            NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.pauseLocations() } },
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.reconcileLocation() } }
        ]
        for api in supportedApis.sorted() {
            try target.registerApiHandler(api) { [weak self] call in
                guard let self else { throw WeappHostError(code: .cancelled, message: "Device adapter retired") }
                guard call.context != .null else { throw WeappHostError(code: .permissionDenied, message: "Trusted native context required") }
                do { return try await self.invoke(api, call) }
                catch let error as WeappHostError { throw error }
                catch { throw self.failure(api, error is CancellationError ? "cancel" : error.localizedDescription, code: error is CancellationError ? .cancelled : .invalidRequest) }
            }
        }
    }
    private func ok(_ api: String, _ values: [String: WeappJSON] = [:]) -> WeappJSON { .object(values.merging(["errMsg": .string("\(api):ok")]) { _, value in value }) }
    private func failure(_ api: String, _ message: String, code: WeappHostError.Code = .invalidRequest) -> WeappHostError {
        WeappHostError(code: code, message: message, details: ["errMsg": .string("\(api):fail \(message)"), "errCode": .number(code == .permissionDenied ? 2001 : -1)])
    }
    private func invoke(_ api: String, _ call: WeappHostApiCall) async throws -> WeappJSON {
        try Task.checkCancellation()
        guard !call.cancellation.isCancelled else { throw CancellationError() }
        let value = call.payload
        switch api {
        case "wx.getClipboardData": return ok(api, ["data": .string(UIPasteboard.general.string ?? "")])
        case "wx.setClipboardData":
            guard let text = value["data"].string, text.utf8.count <= 1048576 else { throw failure(api, "invalid clipboard data") }
            UIPasteboard.general.string = text; return ok(api)
        case "wx.getNetworkType":
            return try await withCheckedThrowingContinuation { continuation in
                let monitor = NWPathMonitor(); var settled = false
                let finish: @MainActor (Result<WeappJSON, Error>) -> Void = { result in
                    guard !settled else { return }; settled = true; monitor.cancel(); continuation.resume(with: result)
                }
                monitor.pathUpdateHandler = { path in Task { @MainActor in finish(.success(self.ok(api, self.network(path)))) } }
                call.cancellation.onCancel { finish(.failure(CancellationError())) }
                monitor.start(queue: DispatchQueue(label: "WeappContainer.network.once"))
            }
        case "wx.onNetworkStatusChange":
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in Task { @MainActor in self?.emit(call, self?.network(path) ?? [:]) } }
            try retain(call) { monitor.cancel() }; monitor.start(queue: DispatchQueue(label: "WeappContainer.network.subscription")); return ok(api)
        case "wx.offNetworkStatusChange", "wx.offAccelerometerChange", "wx.offGyroscopeChange", "wx.offCompassChange":
            remove(value["subscriptionId"].string ?? ""); return ok(api)
        case "wx.getBatteryInfo":
            if batteryMonitoringBefore == nil { batteryMonitoringBefore = UIDevice.current.isBatteryMonitoringEnabled }
            UIDevice.current.isBatteryMonitoringEnabled = true
            guard UIDevice.current.batteryLevel >= 0 else { throw failure(api, "battery information unavailable", code: .unsupported) }
            return ok(api, ["level": .number(Double(UIDevice.current.batteryLevel * 100)), "isCharging": .bool([.charging, .full].contains(UIDevice.current.batteryState))])
        case "wx.getScreenBrightness": return ok(api, ["value": .number(Double(UIScreen.main.brightness))])
        case "wx.setScreenBrightness":
            guard let brightness = value["value"].number, brightness.isFinite, (0...1).contains(brightness) else { throw failure(api, "brightness must be in 0...1") }
            if brightnessBefore == nil { brightnessBefore = UIScreen.main.brightness }; UIScreen.main.brightness = brightness
            return ok(api)
        case "wx.setKeepScreenOn":
            guard let keep = value["keepScreenOn"].bool else { throw failure(api, "keepScreenOn must be boolean") }
            if idleTimerBefore == nil { idleTimerBefore = UIApplication.shared.isIdleTimerDisabled }; UIApplication.shared.isIdleTimerDisabled = keep
            return ok(api)
        case "wx.vibrateLong": AudioServicesPlaySystemSound(kSystemSoundID_Vibrate); return ok(api)
        case "wx.vibrateShort": UIImpactFeedbackGenerator(style: .light).impactOccurred(); return ok(api)
        case "wx.showToast":
            guard let text = value["title"].string else { throw failure(api, "title required") }
            toast?.removeFromSuperview(); let view = try overlay(text: text, spinner: false); toast = view
            let duration = min(10000, max(1, value["duration"].number ?? 1500)) / 1000
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self, weak view] in if self?.toast === view { view?.removeFromSuperview(); self?.toast = nil } }
            return ok(api)
        case "wx.hideToast": toast?.removeFromSuperview(); toast = nil; return ok(api)
        case "wx.showLoading":
            loading?.removeFromSuperview(); loading = try overlay(text: value["title"].string ?? "", spinner: true)
            return ok(api)
        case "wx.hideLoading": loading?.removeFromSuperview(); loading = nil; return ok(api)
        case "wx.showModal", "wx.showActionSheet": return try await dialog(api, call)
        case "wx.makePhoneCall":
            guard let phone = value["phoneNumber"].string, phone.range(of: "^[+0-9 ()-]{1,64}$", options: .regularExpression) != nil,
                  let url = URL(string: "tel:" + phone.filter { "+0123456789".contains($0) }) else { throw failure(api, "invalid phone number") }
            let opened = await UIApplication.shared.open(url)
            guard opened else { throw failure(api, "phone application unavailable", code: .unsupported) }; return ok(api)
        case "wx.openAppAuthorizeSetting":
            guard let url = URL(string: UIApplication.openSettingsURLString), await UIApplication.shared.open(url) else { throw failure(api, "settings unavailable", code: .unsupported) }; return ok(api)
        case "wx.getSetting": return ok(api, ["authSetting": .object(authSettings(call))])
        case "wx.authorize":
            let granted: Bool
            switch value["scope"].string {
            case "scope.userLocation": granted = await authorizeLocation(call)
            case "scope.camera", "scope.record":
                guard try await consent.request(call, value["scope"].string!) else { throw failure(api, "auth deny", code: .permissionDenied) }
                let media: AVMediaType = value["scope"].string == "scope.camera" ? .video : .audio
                let key = media == .video ? "NSCameraUsageDescription" : "NSMicrophoneUsageDescription"
                guard Bundle.main.object(forInfoDictionaryKey: key) is String else { throw failure(api, "host must configure \(key)", code: .permissionDenied) }
                granted = await AVCaptureDevice.requestAccess(for: media)
            default: throw failure(api, "scope requires a host-specific authorization flow", code: .unsupported)
            }
            guard granted else { throw failure(api, "auth deny", code: .permissionDenied) }; return ok(api)
        case "wx.getLocation", "wx.getFuzzyLocation":
            guard value["type"].string ?? "wgs84" == "wgs84" else { throw failure(api, "GCJ-02 requires a coordinate adapter", code: .unsupported) }
            let accepted = locationGeneration
            guard await authorizeLocation(call) else { throw failure(api, "auth deny", code: .permissionDenied) }
            guard accepted == locationGeneration, locationForeground, !call.cancellation.isCancelled else { throw CancellationError() }
            return try await withCheckedThrowingContinuation { continuation in
                locations[call.id] = (api == "wx.getFuzzyLocation", continuation)
                call.cancellation.onCancel { [weak self] in
                    self?.locations.removeValue(forKey: call.id)?.1.resume(throwing: CancellationError())
                    self?.reconcileLocation()
                }
                reconcileLocation()
            }
        case "wx.startLocationUpdate":
            guard value["type"].string ?? "wgs84" == "wgs84" else { throw failure(api, "GCJ-02 requires a coordinate adapter", code: .unsupported) }
            guard locationStreamStart == nil, locationForeground else { throw failure(api, "location start is pending or outside foreground") }
            locationStreamStart = call; let accepted = locationGeneration
            defer { if locationStreamStart?.id == call.id { locationStreamStart = nil } }
            guard await authorizeLocation(call) else { throw failure(api, "auth deny", code: .permissionDenied) }
            try Task.checkCancellation(); guard accepted == locationGeneration, locationStreamStart?.id == call.id, locationForeground, !call.cancellation.isCancelled else { throw CancellationError() }
            if locationStreamOwner == nil {
                // No object handle is returned by this API; the registered
                // adapter cleanup owns its continuing native producer.
                locationStreamOwner = call
            }
            reconcileLocation(); return ok(api)
        case "wx.stopLocationUpdate": stopLocationStream(); return ok(api)
        case "wx.onLocationChange", "wx.onLocationChangeError":
            guard subscriptions.values.filter({ ["wx.onLocationChange", "wx.onLocationChangeError"].contains($0.method) }).count < 32 else { throw failure(api, "location subscription limit") }
            try retain(call) {}; return ok(api)
        case "wx.offLocationChange", "wx.offLocationChangeError":
            if let id = value["subscriptionId"].string { remove(id) }; return ok(api)
        case "wx.startAccelerometer", "wx.startGyroscope":
            guard value["interval"].string ?? "normal" == "normal" else { throw failure(api, "this adapter supports normal sampling only", code: .unsupported) }
            if api == "wx.startAccelerometer" {
                guard motion.isAccelerometerAvailable else { throw failure(api, "accelerometer unavailable", code: .unsupported) }
                motion.accelerometerUpdateInterval = 0.2
                motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in MainActor.assumeIsolated {
                    if let data { self?.emitFamily("Accelerometer", ["x": .number(data.acceleration.x), "y": .number(data.acceleration.y), "z": .number(data.acceleration.z)]) }
                } }
            } else {
                guard motion.isGyroAvailable else { throw failure(api, "gyroscope unavailable", code: .unsupported) }
                motion.gyroUpdateInterval = 0.2
                motion.startGyroUpdates(to: .main) { [weak self] data, _ in MainActor.assumeIsolated {
                    if let data { self?.emitFamily("Gyroscope", ["x": .number(data.rotationRate.x), "y": .number(data.rotationRate.y), "z": .number(data.rotationRate.z)]) }
                } }
            }
            return ok(api)
        case "wx.stopAccelerometer": motion.stopAccelerometerUpdates(); return ok(api)
        case "wx.stopGyroscope": motion.stopGyroUpdates(); return ok(api)
        case "wx.startCompass":
            guard CLLocationManager.headingAvailable() else { throw failure(api, "compass unavailable", code: .unsupported) }
            location.startUpdatingHeading(); return ok(api)
        case "wx.stopCompass": location.stopUpdatingHeading(); return ok(api)
        case "wx.onAccelerometerChange", "wx.onGyroscopeChange", "wx.onCompassChange": try retain(call) {}; return ok(api)
        default: throw failure(api, "not installed", code: .unsupported)
        }
    }
    private func network(_ path: NWPath) -> [String: WeappJSON] {
        ["isConnected": .bool(path.status == .satisfied), "networkType": .string(path.status != .satisfied ? "none" : path.usesInterfaceType(.wifi) ? "wifi" : "unknown")]
    }
    private func retain(_ call: WeappHostApiCall, dispose: @escaping () -> Void) throws {
        guard let id = call.payload["subscriptionId"].string else { throw failure(call.method, "subscription identity required") }
        resources[id] = dispose; subscriptions[id] = call; sequences[id] = 0
        call.cancellation.retainUntilCancelled(); call.cancellation.onCancel { [weak self] in self?.remove(id) }
    }
    private func remove(_ id: String) { resources.removeValue(forKey: id)?(); subscriptions.removeValue(forKey: id); sequences.removeValue(forKey: id) }
    private func emit(_ call: WeappHostApiCall, _ value: [String: WeappJSON]) {
        guard !call.cancellation.isCancelled, let id = call.payload["subscriptionId"].string, let session else { return }
        let sequence = (sequences[id] ?? 0) + 1; sequences[id] = sequence
        guard sequence <= 9007199254740991 else { remove(id); return }
        do { _ = try session.emitHostApiEvent(["sessionId": call.context["sessionId"], "accountEpoch": call.context["account"]["epoch"], "subscriptionId": .string(id), "sequence": .number(Double(sequence)), "value": .object(value)]) }
        catch { if !call.cancellation.isCancelled { session.report(error) } }
    }
    private func emitFamily(_ family: String, _ value: [String: WeappJSON]) { for call in subscriptions.values where call.method == "wx.on\(family)Change" { emit(call, value) } }
    private func authSettings(_ call: WeappHostApiCall) -> [String: WeappJSON] {
        let os = ["scope.userLocation": [.authorizedAlways, .authorizedWhenInUse].contains(location.authorizationStatus), "scope.camera": AVCaptureDevice.authorizationStatus(for: .video) == .authorized, "scope.record": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized]
        return os.reduce(into: [:]) { result, item in if let granted = consent.setting(call, item.key, osGranted: item.value) { result[item.key] = .bool(granted) } }
    }
    private func authorizeLocation(_ call: WeappHostApiCall) async -> Bool {
        guard (try? await consent.request(call, "scope.userLocation")) == true else { return false }
        guard Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") is String, CLLocationManager.locationServicesEnabled() else { return false }
        if location.authorizationStatus != .notDetermined { return [.authorizedAlways, .authorizedWhenInUse].contains(location.authorizationStatus) }
        return await withCheckedContinuation { continuation in
            locationAuthorization[call.id] = continuation
            call.cancellation.onCancel { [weak self] in self?.locationAuthorization.removeValue(forKey: call.id)?.resume(returning: false) }
            location.requestWhenInUseAuthorization()
        }
    }
    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.changedAuthorization(manager) }
    }
    private func changedAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus != .notDetermined else { return }
        let pending = locationAuthorization; locationAuthorization.removeAll()
        for continuation in pending.values { continuation.resume(returning: [.authorizedAlways, .authorizedWhenInUse].contains(manager.authorizationStatus)) }
        if [.authorizedAlways, .authorizedWhenInUse].contains(manager.authorizationStatus) { reconcileLocation() }
        else if locationStreamOwner != nil || !locations.isEmpty { failedLocation(manager, NSError(domain: kCLErrorDomain, code: CLError.denied.rawValue)) }
    }
    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations values: [CLLocation]) {
        if locationIngress.offer(values, nil) { Task { @MainActor [weak self] in self?.drainLocationCallbacks() } }
    }
    private func receivedLocations(_ manager: CLLocationManager, _ values: [CLLocation]) {
        guard locationForeground, let value = values.last, value.horizontalAccuracy >= 0 else { return }
        let pending = locations; locations.removeAll()
        for (fuzzy, continuation) in pending.values {
            let data: [String: WeappJSON] = fuzzy ? ["latitude": .number((value.coordinate.latitude * 100).rounded() / 100), "longitude": .number((value.coordinate.longitude * 100).rounded() / 100)] : ["latitude": .number(value.coordinate.latitude), "longitude": .number(value.coordinate.longitude), "accuracy": .number(value.horizontalAccuracy), "horizontalAccuracy": .number(value.horizontalAccuracy), "verticalAccuracy": .number(value.verticalAccuracy), "speed": .number(value.speed), "altitude": .number(value.altitude)]
            continuation.resume(returning: ok(fuzzy ? "wx.getFuzzyLocation" : "wx.getLocation", data))
        }
        if let owner = locationStreamOwner, !owner.cancellation.isCancelled {
            emitLocation("wx.onLocationChange", owner: owner, ["latitude": .number(value.coordinate.latitude), "longitude": .number(value.coordinate.longitude), "accuracy": .number(value.horizontalAccuracy), "horizontalAccuracy": .number(value.horizontalAccuracy), "verticalAccuracy": .number(value.verticalAccuracy), "speed": .number(value.speed), "altitude": .number(value.altitude)])
        }
        reconcileLocation()
    }
    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if locationIngress.offer(nil, error) { Task { @MainActor [weak self] in self?.drainLocationCallbacks() } }
    }
    private func failedLocation(_ manager: CLLocationManager, _ error: Error) {
        let pending = locations; locations.removeAll(); for (_, continuation) in pending.values { continuation.resume(throwing: error) }
        if let owner = locationStreamOwner, locationForeground, !owner.cancellation.isCancelled { let native = error as NSError; emitLocation("wx.onLocationChangeError", owner: owner, ["errMsg": .string("startLocationUpdate:fail \(native.localizedDescription)"), "errCode": .number(Double(native.code)), "nativeDomain": .string(native.domain)]) }
        if (error as? CLError)?.code == .denied { manager.stopUpdatingLocation() } else { reconcileLocation() }
    }
    private var locationForeground: Bool { locationVisible && UIApplication.shared.applicationState != .background && presenter?.viewIfLoaded?.window != nil }
    private func reconcileLocation() {
        if locationStreamOwner?.cancellation.isCancelled == true { locationStreamOwner = nil }
        guard locationForeground, locationStreamOwner != nil || !locations.isEmpty else { location.stopUpdatingLocation(); return }
        guard CLLocationManager.locationServicesEnabled(), [.authorizedAlways, .authorizedWhenInUse].contains(location.authorizationStatus) else { location.stopUpdatingLocation(); return }
        location.desiredAccuracy = locationStreamOwner != nil || locations.values.contains(where: { !$0.0 }) ? kCLLocationAccuracyBest : kCLLocationAccuracyKilometer
        location.startUpdatingLocation()
    }
    private func stopLocationStream() { let pending = locationStreamStart; locationStreamStart = nil; pending?.cancellation.cancel(); locationStreamOwner = nil; reconcileLocation() }
    private func pauseLocations() {
        locationGeneration += 1; locationIngress.clear(); location.stopUpdatingLocation()
        let start = locationStreamStart; locationStreamStart = nil; start?.cancellation.cancel()
        let pending = locations; locations.removeAll(); for (_, continuation) in pending.values { continuation.resume(throwing: CancellationError()) }
    }
    private func drainLocationCallbacks() { let (values, error) = locationIngress.take(); if let error { failedLocation(location, error) }; if let values { receivedLocations(location, values) } }
    private func emitLocation(_ method: String, owner: WeappHostApiCall, _ values: [String: WeappJSON]) {
        for call in subscriptions.values where call.method == method && call.context["sessionId"] == owner.context["sessionId"] && call.context["application"] == owner.context["application"] && call.context["account"] == owner.context["account"] { emit(call, values) }
    }
    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateHeading heading: CLHeading) {
        Task { @MainActor [weak self] in self?.emitFamily("Compass", ["direction": .number(heading.magneticHeading), "accuracy": .number(heading.headingAccuracy)]) }
    }
    private func restoreDisplay() {
        if let brightnessBefore { UIScreen.main.brightness = brightnessBefore }; brightnessBefore = nil
        if let idleTimerBefore { UIApplication.shared.isIdleTimerDisabled = idleTimerBefore }; idleTimerBefore = nil
    }
    private func overlay(text: String, spinner: Bool) throws -> UIView {
        guard let host = presenter?.viewIfLoaded, host.window != nil else { throw failure("wx.showToast", "visible host view required") }
        let panel = UIStackView(); panel.axis = .vertical; panel.spacing = 10; panel.alignment = .center
        panel.backgroundColor = UIColor.black.withAlphaComponent(0.8); panel.layer.cornerRadius = 8; panel.isLayoutMarginsRelativeArrangement = true; panel.layoutMargins = UIEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        if spinner { let indicator = UIActivityIndicatorView(style: .medium); indicator.color = .white; indicator.startAnimating(); panel.addArrangedSubview(indicator) }
        let label = UILabel(); label.text = text; label.textColor = .white; label.numberOfLines = 0; label.textAlignment = .center; panel.addArrangedSubview(label)
        panel.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(panel)
        NSLayoutConstraint.activate([panel.centerXAnchor.constraint(equalTo: host.centerXAnchor), panel.centerYAnchor.constraint(equalTo: host.centerYAnchor), panel.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, multiplier: 0.8)])
        return panel
    }
    private func dialog(_ api: String, _ call: WeappHostApiCall) async throws -> WeappJSON {
        guard let presenter, presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else { throw failure(api, "visible idle presenter required") }
        return try await withCheckedThrowingContinuation { continuation in
            var settled = false
            let alert = UIAlertController(title: call.payload["title"].string, message: call.payload["content"].string, preferredStyle: api == "wx.showModal" ? .alert : .actionSheet)
            let finish: (Result<WeappJSON, Error>) -> Void = { result in guard !settled else { return }; settled = true; continuation.resume(with: result) }
            if api == "wx.showModal" {
                alert.addAction(UIAlertAction(title: call.payload["confirmText"].string ?? "确定", style: .default) { _ in finish(.success(self.ok(api, ["confirm": .bool(true), "cancel": .bool(false)]))) })
                if call.payload["showCancel"].bool != false { alert.addAction(UIAlertAction(title: call.payload["cancelText"].string ?? "取消", style: .cancel) { _ in finish(.success(self.ok(api, ["confirm": .bool(false), "cancel": .bool(true)]))) }) }
            } else {
                guard let list = call.payload["itemList"].array, (1...6).contains(list.count), list.allSatisfy({ $0.string != nil }) else { continuation.resume(throwing: failure(api, "itemList requires 1...6 strings")); return }
                for (index, item) in list.enumerated() { alert.addAction(UIAlertAction(title: item.string, style: .default) { _ in finish(.success(self.ok(api, ["tapIndex": .number(Double(index))]))) }) }
                alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in finish(.failure(self.failure(api, "cancel", code: .cancelled))) })
            }
            if let popover = alert.popoverPresentationController { popover.sourceView = presenter.view; popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1); popover.permittedArrowDirections = [] }
            call.cancellation.onCancel { alert.dismiss(animated: false); finish(.failure(CancellationError())) }
            presenter.present(alert, animated: true)
        }
    }
    private func resetResources() {
        pauseLocations(); locationStreamOwner = nil
        consent.reset()
        for id in Array(resources.keys) { remove(id) }; motion.stopAccelerometerUpdates(); motion.stopGyroUpdates(); location.stopUpdatingLocation(); location.stopUpdatingHeading()
        let pending = locations; locations.removeAll(); for (_, continuation) in pending.values { continuation.resume(throwing: CancellationError()) }
        let auth = locationAuthorization; locationAuthorization.removeAll(); for continuation in auth.values { continuation.resume(returning: false) }
        toast?.removeFromSuperview(); loading?.removeFromSuperview(); restoreDisplay()
        if let batteryMonitoringBefore { UIDevice.current.isBatteryMonitoringEnabled = batteryMonitoringBefore }; batteryMonitoringBefore = nil
    }
    public func close() { resetResources(); for observer in locationObservers { NotificationCenter.default.removeObserver(observer) }; locationObservers.removeAll(); session = nil }
}
