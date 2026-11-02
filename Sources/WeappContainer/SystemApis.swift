import Foundation
import UIKit
import Contacts
import ContactsUI
import EventKit
import EventKitUI
import PhotosUI
import Vision
import VisionKit
import LocalAuthentication
@preconcurrency import CoreNFC
@preconcurrency import AVFoundation

/// Supply a real SOTER signing integration. LocalAuthentication alone cannot
/// produce Tencent's attestation or its RSA/PSS signature.
@MainActor public protocol WeappSoterAttestationProvider: AnyObject {
    var supportedAuthModes: Set<String> { get }
    func attest(_ call: WeappHostApiCall, authMode: String, authenticationContext: LAContext) async throws -> WeappSoterAttestation
}
public struct WeappSoterAttestation: Sendable {
    public let resultJSON: String
    public let resultJSONSignature: String
    public init(resultJSON: String, resultJSONSignature: String) { self.resultJSON = resultJSON; self.resultJSONSignature = resultJSONSignature }
}

/// System-owned editors, barcode recognition, signed biometrics and NDEF.
/// These APIs are native operations; physical-device acceptance is recorded
/// separately from simulator compilation. NFC requires explicit provisioning.
@MainActor public final class WeappSystemApis: NSObject, CNContactViewControllerDelegate, EKEventEditViewDelegate, PHPickerViewControllerDelegate, DataScannerViewControllerDelegate, UIAdaptivePresentationControllerDelegate, NFCTagReaderSessionDelegate {
    private weak var presenter: UIViewController?
    private weak var session: WeappContainerSession?
    private let files: WeappManagedFiles?
    private let scopes = WeappManagedFileScopes()
    private lazy var consent = WeappAppPermissionConsent(presenter: { [weak self] in self?.presenter }, auxiliaryRoot: { [unowned self] in try self.scopes.auxiliaryRoot($0) })
    private let signer: (any WeappSoterAttestationProvider)?
    private let nfcEnabled: Bool
    private var closed = false, foreground = false
    private var generation: UInt64 = 0
    private var backgroundObserver: NSObjectProtocol?
    private var uiController: UIViewController?
    private var uiFinish: ((Result<WeappJSON, Error>) -> Void)?
    private var uiCall: WeappHostApiCall?
    private var uiProgress: Progress?
    private var scanJobs: [UUID: Task<VNBarcodeObservation?, Error>] = [:]
    private var authContexts: [String: LAContext] = [:]
    private var activeCalls: Set<String> = []
    private var retiringReaders: [ObjectIdentifier: NFCTagReaderSession] = [:]
    private var uiRetirements = 0
    private var retirementWaiters: [UUID: (CheckedContinuation<Void, Error>, Task<Void, Never>)] = [:]
    private var adapters: [String: NFCResource] = [:]
    private var ndefs: [String: String] = [:]
    private var subscriptions: [String: (WeappHostApiCall, UInt64)] = [:]
    private final class NFCResource {
        let call: WeappHostApiCall
        var reader: NFCTagReaderSession?
        var tag: NFCTag?
        var connected = false, physicalConnected = false
        var tagEpoch: UInt64 = 0
        var activeOperation: String?
        var lastRecords: WeappJSON?
        var timeout: TimeInterval = 5
        var pending: [UUID: () -> Void] = [:]
        init(_ call: WeappHostApiCall) { self.call = call }
    }
    public init(presenter: UIViewController, files: WeappManagedFiles? = nil, soterAttestationProvider: (any WeappSoterAttestationProvider)? = nil, enableNfc: Bool = false) {
        self.presenter = presenter; self.files = files; self.signer = soterAttestationProvider; self.nfcEnabled = enableNfc
        super.init()
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.reset() } }
    }
    /// Source inventory only. supportedApis still applies real native/configuration gates.
    public static let potentialApis: Set<String> = ["object:NFCAdapter.getNdef", "object:NFCAdapter.offDiscovered", "object:NFCAdapter.onDiscovered", "object:NFCAdapter.startDiscovery", "object:NFCAdapter.stopDiscovery", "object:NFCAdapter.tech", "object:Ndef.close", "object:Ndef.connect", "object:Ndef.isConnected", "object:Ndef.offNdefMessage", "object:Ndef.onNdefMessage", "object:Ndef.setTimeout", "object:Ndef.writeNdefMessage", "wx.addPhoneCalendar", "wx.addPhoneContact", "wx.addPhoneRepeatCalendar", "wx.checkIsSoterEnrolledInDevice", "wx.checkIsSupportSoterAuthentication", "wx.getNFCAdapter", "wx.scanCode", "wx.startSoterAuthentication"]
    public var supportedApis: Set<String> {
        var apis: Set<String> = ["wx.scanCode", "wx.checkIsSupportSoterAuthentication", "wx.checkIsSoterEnrolledInDevice"]
        if Bundle.main.object(forInfoDictionaryKey: "NSContactsUsageDescription") is String { apis.insert("wx.addPhoneContact") }
        let calendarKey: String
        if #available(iOS 17.0, *) { calendarKey = "NSCalendarsWriteOnlyAccessUsageDescription" } else { calendarKey = "NSCalendarsUsageDescription" }
        if Bundle.main.object(forInfoDictionaryKey: calendarKey) is String { apis.formUnion(["wx.addPhoneCalendar", "wx.addPhoneRepeatCalendar"]) }
        if signer != nil && !biometricModes().isEmpty { apis.insert("wx.startSoterAuthentication") }
        if nfcEnabled && NFCTagReaderSession.readingAvailable && Bundle.main.object(forInfoDictionaryKey: "NFCReaderUsageDescription") is String {
            apis.formUnion(["wx.getNFCAdapter", "object:NFCAdapter.tech", "object:NFCAdapter.startDiscovery", "object:NFCAdapter.stopDiscovery", "object:NFCAdapter.getNdef", "object:NFCAdapter.onDiscovered", "object:NFCAdapter.offDiscovered", "object:Ndef.connect", "object:Ndef.close", "object:Ndef.isConnected", "object:Ndef.setTimeout", "object:Ndef.writeNdefMessage", "object:Ndef.onNdefMessage", "object:Ndef.offNdefMessage"])
        }
        return apis
    }
    public func install(in target: WeappContainerSession) throws {
        guard session == nil, !closed else { throw failure("system", "adapter already installed or closed") }
        session = target; scopes.bind(target)
        let key = "system-\(UUID().uuidString)"
        // Retain this lifecycle owner until all native invalidation callbacks
        // and editor dismissals finish, including failed final-close retries.
        try target.registerHostResourceCleanup(key) { [self] in reset() }
        try target.registerHostAsyncResourceCleanup(key) { [self] in reset(); try await drainRetirements() }
        try target.registerHostVisibilityHandler(key) { [weak self] visible in self?.foreground = visible; if !visible { self?.reset() } }
        for api in supportedApis.sorted() {
            try target.registerApiHandler(api) { [weak self] call in
                guard let self, !self.closed else { throw CancellationError() }
                _ = try self.scopes.descriptor(call.context)
                self.activeCalls.insert(call.id); defer { self.activeCalls.remove(call.id); self.checkRetirements() }
                do { return try await self.invoke(api, call) }
                catch let error as WeappHostError { throw error }
                catch is CancellationError { throw self.failure(api, "cancel", .cancelled) }
                catch { let native = error as NSError; throw WeappHostError(code: .invalidRequest, message: native.localizedDescription, details: ["errCode": .number(Double(native.code)), "errMsg": .string("\(api):fail \(native.localizedDescription)"), "nativeDomain": .string(native.domain)]) }
            }
        }
    }
    private func ok(_ api: String, _ values: [String: WeappJSON] = [:]) -> WeappJSON { .object(values.merging(["errMsg": .string("\(api):ok")]) { _, value in value }) }
    private func failure(_ api: String, _ message: String, _ code: WeappHostError.Code = .invalidRequest) -> WeappHostError { WeappHostError(code: code, message: message, details: ["errMsg": .string("\(api):fail \(message)")]) }
    private func live(_ call: WeappHostApiCall, _ accepted: UInt64) throws {
        try Task.checkCancellation()
        guard !closed, foreground, generation == accepted, !call.cancellation.isCancelled else { throw CancellationError() }
        _ = try scopes.descriptor(call.context)
    }
    private func visiblePresenter(_ call: WeappHostApiCall, _ accepted: UInt64) throws -> UIViewController {
        try live(call, accepted)
        guard uiFinish == nil, let presenter, presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else { throw failure(call.method, "visible idle presenter required") }; return presenter
    }
    private func invoke(_ api: String, _ call: WeappHostApiCall) async throws -> WeappJSON {
        let accepted = generation
        try Task.checkCancellation(); guard !call.cancellation.isCancelled else { throw CancellationError() }
        switch api {
        case "wx.checkIsSupportSoterAuthentication": return ok(api, ["supportMode": .array(biometricModes().sorted().map(WeappJSON.string))])
        case "wx.checkIsSoterEnrolledInDevice":
            let context = LAContext(); var error: NSError?
            let enrolled = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
            return ok(api, ["isEnrolled": .bool(enrolled && biometricModes(context).contains(call.payload["checkAuthMode"].string ?? ""))])
        case "wx.startSoterAuthentication": return try await authenticate(call, accepted)
        case "wx.addPhoneContact": return try await contact(call, accepted)
        case "wx.addPhoneCalendar", "wx.addPhoneRepeatCalendar": return try await calendar(call, accepted)
        case "wx.scanCode": return try await scan(call, accepted)
        default: return try await nfc(api, call, accepted)
        }
    }
    private func show(_ controller: UIViewController, _ call: WeappHostApiCall, _ accepted: UInt64) async throws -> WeappJSON {
        let presenter = try visiblePresenter(call, accepted)
        return try await withCheckedThrowingContinuation { continuation in
            var settled = false
            uiController = controller; uiCall = call
            uiFinish = { [weak self, weak controller] result in
                guard !settled else { return }; settled = true
                self?.uiProgress?.cancel(); self?.uiProgress = nil
                if let scanner = (controller as? UINavigationController)?.topViewController as? DataScannerViewController { scanner.stopScanning() }
                self?.uiController = nil; self?.uiFinish = nil; self?.uiCall = nil
                if controller?.presentingViewController != nil {
                    self?.uiRetirements += 1
                    controller?.dismiss(animated: false) { [weak self] in self?.uiRetirements -= 1; self?.checkRetirements(); continuation.resume(with: result) }
                }
                else { continuation.resume(with: result) }
            }
            call.cancellation.onCancel { [weak self] in self?.uiFinish?(.failure(CancellationError())) }
            guard !call.cancellation.isCancelled else { return }
            presenter.present(controller, animated: true) { [weak self, weak controller] in
                controller?.presentationController?.delegate = self
                if let scanner = (controller as? UINavigationController)?.topViewController as? DataScannerViewController {
                    do { try scanner.startScanning() } catch { self?.uiFinish?(.failure(error)) }
                }
            }
        }
    }
    public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { if presentationController.presentedViewController === uiController { uiFinish?(.failure(CancellationError())) } }
    @objc private func cancelUI() { uiFinish?(.failure(CancellationError())) }
    private func navigation(_ child: UIViewController) -> UINavigationController { let nav = UINavigationController(rootViewController: child); child.navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelUI)); return nav }
    private func contact(_ call: WeappHostApiCall, _ accepted: UInt64) async throws -> WeappJSON {
        guard let first = call.payload["firstName"].string, !first.isEmpty else { throw failure(call.method, "firstName required") }
        guard Bundle.main.object(forInfoDictionaryKey: "NSContactsUsageDescription") is String else { throw failure(call.method, "host must configure NSContactsUsageDescription", .permissionDenied) }
        guard try await consent.request(call, "scope.addPhoneContact") else { throw failure(call.method, "auth deny", .permissionDenied) }
        try live(call, accepted)
        let value = call.payload, contact = CNMutableContact(); contact.givenName = first
        contact.familyName = value["lastName"].string ?? ""; contact.middleName = value["middleName"].string ?? ""; contact.nickname = value["nickName"].string ?? ""; contact.organizationName = value["organization"].string ?? ""; contact.jobTitle = value["title"].string ?? ""
        contact.phoneNumbers = [("mobilePhoneNumber", CNLabelPhoneNumberMobile), ("homePhoneNumber", CNLabelHome), ("workPhoneNumber", CNLabelWork), ("hostNumber", CNLabelPhoneNumberMain), ("homeFaxNumber", CNLabelPhoneNumberHomeFax), ("workFaxNumber", CNLabelPhoneNumberWorkFax)].compactMap { key, label in value[key].string.map { CNLabeledValue(label: label, value: CNPhoneNumber(stringValue: $0)) } }
        if let email = value["email"].string { contact.emailAddresses = [CNLabeledValue(label: CNLabelOther, value: email as NSString)] }
        if let url = value["url"].string { contact.urlAddresses = [CNLabeledValue(label: CNLabelURLAddressHomePage, value: url as NSString)] }
        for (prefix, label) in [("address", CNLabelOther), ("homeAddress", CNLabelHome), ("workAddress", CNLabelWork)] {
            let address = CNMutablePostalAddress(); address.street = value[prefix + "Street"].string ?? ""; address.city = value[prefix + "City"].string ?? ""; address.state = value[prefix + "State"].string ?? ""; address.country = value[prefix + "Country"].string ?? ""; address.postalCode = value[prefix + "PostalCode"].string ?? ""
            if ![address.street, address.city, address.state, address.country, address.postalCode].allSatisfy(\.isEmpty) { contact.postalAddresses.append(CNLabeledValue(label: label, value: address)) }
        }
        // Contact notes require Apple's restricted notes entitlement. Do not
        // silently drop requested fields or write arbitrary host file paths.
        if value["remark"].string?.isEmpty == false || value["weChatNumber"].string?.isEmpty == false { throw failure(call.method, "contact notes/WeChat fields require an entitled host contact adapter", .unsupported) }
        if let path = value["photoFilePath"].string {
            guard let files else { throw failure(call.method, "managed photo resolver is not installed", .unsupported) }
            let data = try files.readForNative(path, context: call.context)
            guard data.count <= 8 * 1024 * 1024, let image = UIImage(data: data), let encoded = image.jpegData(compressionQuality: 0.9) else { throw failure(call.method, "invalid managed contact photo") }; contact.imageData = encoded
        }
        let editor = CNContactViewController(forNewContact: contact); editor.delegate = self; editor.contactStore = CNContactStore()
        return try await show(navigation(editor), call, accepted)
    }
    nonisolated public func contactViewController(_ viewController: CNContactViewController, didCompleteWith contact: CNContact?) { Task { @MainActor [weak self] in guard let self, (self.uiController as? UINavigationController)?.topViewController === viewController else { return }; self.uiFinish?(contact == nil ? .failure(CancellationError()) : .success(self.ok(self.uiCall?.method ?? "wx.addPhoneContact"))) } }
    private func calendar(_ call: WeappHostApiCall, _ accepted: UInt64) async throws -> WeappJSON {
        let value = call.payload
        guard let title = value["title"].string, !title.isEmpty, title.utf8.count <= 4096 else { throw failure(call.method, "bounded title required") }
        guard value["path"] == .null, value["signature"] == .null else { throw failure(call.method, "signed WeChat calendar links require a host link adapter", .unsupported) }
        let (start, end) = try WeappSystemApiPayloads.calendarTimes(value)
        guard try await consent.request(call, "scope.addPhoneCalendar") else { throw failure(call.method, "auth deny", .permissionDenied) }
        let store = EKEventStore(), granted: Bool
        if #available(iOS 17.0, *) {
            guard Bundle.main.object(forInfoDictionaryKey: "NSCalendarsWriteOnlyAccessUsageDescription") is String else { throw failure(call.method, "host must configure NSCalendarsWriteOnlyAccessUsageDescription", .permissionDenied) }
            granted = try await store.requestWriteOnlyAccessToEvents()
        } else {
            guard Bundle.main.object(forInfoDictionaryKey: "NSCalendarsUsageDescription") is String else { throw failure(call.method, "host must configure NSCalendarsUsageDescription", .permissionDenied) }
            granted = try await store.requestAccess(to: .event)
        }
        try live(call, accepted); guard granted else { throw failure(call.method, "calendar auth deny", .permissionDenied) }
        let event = EKEvent(eventStore: store); event.title = title; event.startDate = Date(timeIntervalSince1970: start); event.endDate = Date(timeIntervalSince1970: end); event.isAllDay = value["allDay"].bool ?? false; event.location = value["location"].string; event.notes = value["description"].string
        if value["alarm"].bool != false { let offset = value["alarmOffset"].number ?? 0; guard offset.isFinite, offset >= 0 else { throw failure(call.method, "alarmOffset must be nonnegative") }; event.addAlarm(EKAlarm(relativeOffset: -offset)) }
        if call.method == "wx.addPhoneRepeatCalendar" {
            let frequencies: [String: EKRecurrenceFrequency] = ["day": .daily, "week": .weekly, "month": .monthly, "year": .yearly]
            guard let frequency = frequencies[value["repeatInterval"].string ?? "month"] else { throw failure(call.method, "invalid repeatInterval") }
            if frequency == .monthly && Calendar.current.component(.day, from: event.startDate) > 28 { throw failure(call.method, "monthly date must not exceed 28") }
            var recurrenceEnd: EKRecurrenceEnd?
            if let end = value["repeatEndTime"].number { guard end.isFinite, end >= start else { throw failure(call.method, "invalid repeatEndTime") }; recurrenceEnd = EKRecurrenceEnd(end: Date(timeIntervalSince1970: end)) }
            event.recurrenceRules = [EKRecurrenceRule(recurrenceWith: frequency, interval: 1, end: recurrenceEnd)]
        }
        let editor = EKEventEditViewController(); editor.eventStore = store; editor.event = event; editor.editViewDelegate = self
        return try await show(editor, call, accepted)
    }
    nonisolated public func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) { Task { @MainActor [weak self] in guard let self, self.uiController === controller else { return }; self.uiFinish?(action == .saved ? .success(self.ok(self.uiCall?.method ?? "wx.addPhoneCalendar")) : .failure(CancellationError())) } }
    private func scanSymbologies(_ call: WeappHostApiCall) throws -> [VNBarcodeSymbology] {
        let types = call.payload["scanType"].array?.compactMap(\.string) ?? ["barCode", "qrCode"]
        guard !types.isEmpty, types.allSatisfy({ ["barCode", "qrCode", "datamatrix", "pdf417"].contains($0) }) else { throw failure(call.method, "wxCode and unknown barcode formats require their official decoder", .unsupported) }
        var values: Set<VNBarcodeSymbology> = []
        for type in types { switch type { case "qrCode": values.insert(.qr); case "datamatrix": values.insert(.dataMatrix); case "pdf417": values.insert(.pdf417); default: values.formUnion([.code39, .code93, .code128, .ean8, .ean13, .itf14, .upce, .i2of5, .aztec]) } }
        return Array(values)
    }
    private func scan(_ call: WeappHostApiCall, _ accepted: UInt64) async throws -> WeappJSON {
        let symbologies = try scanSymbologies(call)
        let camera: Bool
        if call.payload["onlyFromCamera"].bool == true { camera = true }
        else {
            let alert = UIAlertController(title: "扫码", message: nil, preferredStyle: .actionSheet)
            alert.addAction(UIAlertAction(title: "相机", style: .default) { [weak self] _ in self?.uiFinish?(.success(.bool(true))) })
            alert.addAction(UIAlertAction(title: "相册", style: .default) { [weak self] _ in self?.uiFinish?(.success(.bool(false))) })
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in self?.cancelUI() })
            if let popover = alert.popoverPresentationController { popover.sourceView = presenter?.view; popover.sourceRect = presenter?.view.bounds ?? .zero }
            camera = try await show(alert, call, accepted).bool ?? false
        }
        try live(call, accepted)
        if camera {
            guard DataScannerViewController.isSupported, Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") is String else { throw failure(call.method, "camera scanner unavailable or NSCameraUsageDescription missing", .unsupported) }
            guard try await consent.request(call, "scope.camera"), await AVCaptureDevice.requestAccess(for: .video) else { throw failure(call.method, "camera auth deny", .permissionDenied) }
            try live(call, accepted); guard DataScannerViewController.isAvailable else { throw failure(call.method, "camera scanner restricted", .permissionDenied) }
            let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: symbologies)], qualityLevel: .balanced, recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false, isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true); scanner.delegate = self
            return try await show(navigation(scanner), call, accepted)
        }
        var configuration = PHPickerConfiguration(); configuration.filter = .images; configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration); picker.delegate = self
        return try await show(picker, call, accepted)
    }
    private func scanResult(_ observation: VNBarcodeObservation, _ call: WeappHostApiCall) throws -> WeappJSON {
        guard let text = observation.payloadStringValue, text.utf8.count <= 1024 * 1024 else { throw failure(call.method, "barcode has no bounded text payload", .unsupported) }
        let types: [VNBarcodeSymbology: String] = [.qr: "QR_CODE", .dataMatrix: "DATA_MATRIX", .pdf417: "PDF_417", .aztec: "AZTEC", .code39: "CODE_39", .code93: "CODE_93", .code128: "CODE_128", .ean8: "EAN_8", .ean13: "EAN_13", .itf14: "ITF", .upce: "UPC_E", .i2of5: "CODE_25"]
        return ok(call.method, ["result": .string(text), "scanType": .string(types[observation.symbology] ?? observation.symbology.rawValue), "charSet": .string("UTF-8"), "rawData": .string(Data(text.utf8).base64EncodedString()), "path": .string("")])
    }
    public func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) { for item in addedItems { self.dataScanner(dataScanner, didTapOn: item); if uiFinish == nil { break } } }
    public func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
        guard (uiController as? UINavigationController)?.topViewController === dataScanner, let call = uiCall, case .barcode(let barcode) = item else { return }
        do { uiFinish?(.success(try scanResult(barcode.observation, call))) } catch { uiFinish?(.failure(error)) }
    }
    public func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) { if (uiController as? UINavigationController)?.topViewController === dataScanner { uiFinish?(.failure(error)) } }
    public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        guard uiController === picker, let call = uiCall else { return }
        guard let item = results.first?.itemProvider, item.canLoadObject(ofClass: UIImage.self) else { uiFinish?(.failure(CancellationError())); return }
        let accepted = generation
        uiProgress = item.loadObject(ofClass: UIImage.self) { [weak self, weak picker] value, error in
            Task { @MainActor in
                guard let self, self.uiController === picker else { return }
                do {
                    try self.live(call, accepted)
                    if let error { throw error }
                    guard let image = value as? UIImage, let cgImage = image.cgImage, cgImage.width <= 16384, cgImage.height <= 16384, Int64(cgImage.width) * Int64(cgImage.height) <= 32 * 1024 * 1024 else { throw self.failure(call.method, "image exceeds scan budget") }
                    let symbologies = try self.scanSymbologies(call), id = UUID()
                    let job = Task.detached(priority: .userInitiated) { () throws -> VNBarcodeObservation? in
                        try Task.checkCancellation()
                        let request = VNDetectBarcodesRequest(); request.symbologies = symbologies
                        try VNImageRequestHandler(cgImage: cgImage).perform([request]); try Task.checkCancellation()
                        return request.results?.first
                    }
                    self.scanJobs[id] = job; defer { self.scanJobs.removeValue(forKey: id); self.checkRetirements() }
                    let result = try await job.value
                    try self.live(call, accepted); guard self.uiController === picker else { return }
                    guard let result else { throw self.failure(call.method, "no matching barcode") }
                    self.uiFinish?(.success(try self.scanResult(result, call)))
                } catch { if self.uiController === picker { self.uiFinish?(.failure(error)) } }
            }
        }
    }
    private func biometricModes(_ supplied: LAContext? = nil) -> Set<String> {
        guard let signer else { return [] }; let context = supplied ?? LAContext(); var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        let mode = context.biometryType == .faceID ? "facial" : context.biometryType == .touchID ? "fingerPrint" : ""
        if mode == "facial", !(Bundle.main.object(forInfoDictionaryKey: "NSFaceIDUsageDescription") is String) { return [] }
        return signer.supportedAuthModes.contains(mode) ? [mode] : []
    }
    private func authenticate(_ call: WeappHostApiCall, _ accepted: UInt64) async throws -> WeappJSON {
        try live(call, accepted)
        guard let signer, let challenge = call.payload["challenge"].string, !challenge.isEmpty, challenge.utf8.count <= 4096 else { throw failure(call.method, "real SOTER signer and bounded challenge required", .unsupported) }
        guard try await consent.request(call, "scope.biometric") else { throw failure(call.method, "auth deny", .permissionDenied) }; try live(call, accepted)
        let context = LAContext(), requested = Set(call.payload["requestAuthModes"].array?.compactMap(\.string) ?? [])
        guard let mode = biometricModes(context).intersection(requested).first else { throw failure(call.method, "requested biometric mode unavailable", .unsupported) }
        if mode == "facial", !(Bundle.main.object(forInfoDictionaryKey: "NSFaceIDUsageDescription") is String) { throw failure(call.method, "host must configure NSFaceIDUsageDescription", .permissionDenied) }
        authContexts[call.id] = context; defer { authContexts.removeValue(forKey: call.id); context.invalidate() }
        call.cancellation.onCancel { context.invalidate() }
        context.localizedFallbackTitle = ""
        guard try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: call.payload["authContent"].string ?? "验证此小程序操作") else { throw failure(call.method, "auth deny", .permissionDenied) }
        try live(call, accepted)
        let result = try await signer.attest(call, authMode: mode, authenticationContext: context)
        try live(call, accepted)
        try WeappSystemApiPayloads.attestation(resultJSON: result.resultJSON, signature: result.resultJSONSignature, challenge: challenge)
        return ok(call.method, ["authMode": .string(mode), "errCode": .number(0), "resultJSON": .string(result.resultJSON), "resultJSONSignature": .string(result.resultJSONSignature)])
    }
    private func nfcOwner(_ call: WeappHostApiCall, child: Bool = false) throws -> NFCResource {
        let object = call.payload["objectId"].string ?? "", id = child ? ndefs[object] ?? "" : object
        guard let owner = adapters[id], !owner.call.cancellation.isCancelled, sameOwner(owner.call.context, call.context) else { throw failure(call.method, "NFC object owner retired", .cancelled) }; return owner
    }
    private func sameOwner(_ lhs: WeappJSON, _ rhs: WeappJSON) -> Bool { lhs["application"] == rhs["application"] && lhs["account"] == rhs["account"] && lhs["sessionId"] == rhs["sessionId"] }
    private func nfc(_ api: String, _ call: WeappHostApiCall, _ accepted: UInt64) async throws -> WeappJSON {
        try live(call, accepted)
        if api == "wx.getNFCAdapter" {
            guard nfcEnabled, NFCTagReaderSession.readingAvailable, adapters.count < 16, let id = call.payload["objectId"].string, adapters[id] == nil else { throw failure(api, "NFC unavailable or object limit reached", .unsupported) }
            adapters[id] = NFCResource(call); call.cancellation.retainUntilCancelled(); call.cancellation.onCancel { [weak self] in self?.removeAdapter(id) }
            let tech: [String: WeappJSON] = ["isoDep": .string("ISO_DEP"), "mifareClassic": .string("MIFARE_CLASSIC"), "mifareUltralight": .string("MIFARE_ULTRALIGHT"), "ndef": .string("NDEF"), "nfcA": .string("NFC_A"), "nfcB": .string("NFC_B"), "nfcF": .string("NFC_F"), "nfcV": .string("NFC_V")]
            return ok(api, ["objectId": .string(id), "properties": .object(["tech": .object(tech)])])
        }
        if api == "object:NFCAdapter.getNdef" {
            guard let parent = call.payload["receiverId"].string, let owner = adapters[parent], sameOwner(owner.call.context, call.context), ndefs.count < 64, let id = call.payload["objectId"].string, ndefs[id] == nil else { throw failure(api, "NDEF receiver unavailable", .cancelled) }
            ndefs[id] = parent; call.cancellation.retainUntilCancelled(); call.cancellation.onCancel { [weak self] in self?.ndefs.removeValue(forKey: id) }; return ok(api, ["objectId": .string(id)])
        }
        if api.hasSuffix(".onDiscovered") || api.hasSuffix(".onNdefMessage") || api.hasSuffix(".offDiscovered") || api.hasSuffix(".offNdefMessage") {
            _ = try nfcOwner(call, child: api.hasPrefix("object:Ndef."))
            guard let id = call.payload["subscriptionId"].string else { throw failure(api, "subscriptionId required") }
            if api.contains(".off") { subscriptions.removeValue(forKey: id) }
            else {
                guard subscriptions.count < 64 else { throw failure(api, "NFC subscription limit reached") }; subscriptions[id] = (call, 0); call.cancellation.retainUntilCancelled(); call.cancellation.onCancel { [weak self] in self?.subscriptions.removeValue(forKey: id) }
                let owner = try nfcOwner(call, child: api.hasPrefix("object:Ndef."))
                if api == "object:Ndef.onNdefMessage", owner.connected, let records = owner.lastRecords { emitNfc(owner, event: api, values: ["records": records], only: id) }
            }
            return ok(api)
        }
        let owner = try nfcOwner(call, child: api.hasPrefix("object:Ndef."))
        let exclusive = api == "object:Ndef.connect" || api == "object:Ndef.writeNdefMessage"
        if exclusive { guard owner.activeOperation == nil else { throw failure(api, "another NDEF operation is active") }; owner.activeOperation = call.id }
        defer { if exclusive && owner.activeOperation == call.id { owner.activeOperation = nil } }
        switch api {
        case "object:NFCAdapter.tech": return ok(api)
        case "object:NFCAdapter.startDiscovery":
            guard adapters.values.allSatisfy({ $0.reader == nil }) else { throw failure(api, "another NFC discovery is active") }
            guard try await consent.request(call, "scope.nfc") else { throw failure(api, "auth deny", .permissionDenied) }; try live(call, accepted)
            guard owner.reader == nil, adapters.values.contains(where: { $0 === owner }) else { throw CancellationError() }
            guard adapters.values.allSatisfy({ $0.reader == nil }), retiringReaders.isEmpty else { throw failure(api, "another NFC reader is active or retiring") }
            var polling: NFCTagReaderSession.PollingOption = [.iso14443, .iso15693]
            if let codes = Bundle.main.object(forInfoDictionaryKey: "com.apple.developer.nfc.readersession.felica.systemcodes") as? [String], !codes.isEmpty { polling.insert(.iso18092) }
            guard let reader = NFCTagReaderSession(pollingOption: polling, delegate: self, queue: .main) else { throw failure(api, "NFC reader unavailable", .unsupported) }
            reader.alertMessage = "将 NFC 标签靠近手机顶部"; owner.reader = reader; reader.begin(); return ok(api)
        case "object:NFCAdapter.stopDiscovery", "object:Ndef.close": stopNfc(owner); return ok(api)
        case "object:Ndef.isConnected": guard owner.connected else { throw failure(api, "NDEF tag is disconnected") }; return ok(api)
        case "object:Ndef.setTimeout": guard let milliseconds = call.payload["timeout"].number, milliseconds.isFinite, (100...60000).contains(milliseconds) else { throw failure(api, "timeout must be 100...60000 ms") }; owner.timeout = milliseconds / 1000; return ok(api)
        case "object:Ndef.connect":
            guard let reader = owner.reader, let tag = owner.tag else { throw failure(api, "discover a tag before connecting") }
            if !owner.physicalConnected { try await nfcOperation(owner, call) { finish in reader.connect(to: tag) { error in Task { @MainActor in finish(error.map(Result.failure) ?? .success(())) } } } }
            try live(call, accepted); guard owner.reader === reader else { throw CancellationError() }; owner.connected = true; owner.physicalConnected = true
            try await readNdef(owner, call); return ok(api)
        case "object:Ndef.writeNdefMessage":
            guard owner.connected, let tag = owner.tag else { throw failure(api, "NDEF tag is disconnected") }
            let ndef = try ndefTag(tag), message = try ndefMessage(call)
            let status: (NFCNDEFStatus, Int) = try await nfcOperation(owner, call) { finish in ndef.queryNDEFStatus { state, capacity, error in Task { @MainActor in finish(error.map(Result.failure) ?? .success((state, capacity))) } } }
            guard status.0 == .readWrite, message.length <= status.1 else { throw failure(api, "NDEF tag is read-only or capacity is insufficient") }
            try live(call, accepted)
            try await nfcOperation(owner, call) { finish in ndef.writeNDEF(message) { error in Task { @MainActor in finish(error.map(Result.failure) ?? .success(())) } } }
            try live(call, accepted); return ok(api)
        default: throw failure(api, "NFC technology is not installed", .unsupported)
        }
    }
    private func ndefTag(_ tag: NFCTag) throws -> any NFCNDEFTag { switch tag { case .miFare(let value): return value; case .iso7816(let value): return value; case .iso15693(let value): return value; case .feliCa(let value): return value; @unknown default: throw failure("NDEF", "unsupported NFC tag", .unsupported) } }
    private func binary(_ data: Data) -> WeappJSON { .object(["__weappBinary": .object(["type": .string("ArrayBuffer"), "bytes": .array(data.map { .number(Double($0)) })])]) }
    private func bytes(_ value: WeappJSON) throws -> Data {
        try WeappSystemApiPayloads.binary(value)
    }
    private func ndefMessage(_ call: WeappHostApiCall) throws -> NFCNDEFMessage {
        let value = call.payload; var records: [NFCNDEFPayload] = []
        for text in value["texts"].array ?? [] { guard let text = text.string, let payload = NFCNDEFPayload.wellKnownTypeTextPayload(string: text, locale: Locale(identifier: "en")) else { throw failure(call.method, "invalid NDEF text") }; records.append(payload) }
        for uri in value["uris"].array ?? [] { guard let uri = uri.string, let payload = NFCNDEFPayload.wellKnownTypeURIPayload(string: uri) else { throw failure(call.method, "invalid NDEF URI") }; records.append(payload) }
        for record in value["records"].array ?? [] {
            guard let number = record["tnf"].number, number.isFinite, (0...7).contains(number), number.rounded() == number, let format = NFCTypeNameFormat(rawValue: UInt8(number)) else { throw failure(call.method, "record tnf required") }
            records.append(NFCNDEFPayload(format: format, type: try bytes(record["type"]), identifier: try bytes(record["id"]), payload: try bytes(record["payload"])))
        }
        guard !records.isEmpty, records.count <= 64 else { throw failure(call.method, "NDEF requires 1...64 records") }
        let message = NFCNDEFMessage(records: records); guard message.length <= 1024 * 1024 else { throw failure(call.method, "NDEF message exceeds 1 MiB") }; return message
    }
    private func nfcOperation<T>(_ owner: NFCResource, _ call: WeappHostApiCall, _ operation: (@escaping @MainActor (Result<T, Error>) -> Void) -> Void) async throws -> T {
        guard let reader = owner.reader, owner.pending.isEmpty else { throw failure(call.method, "NFC reader disconnected or busy") }
        let tagEpoch = owner.tagEpoch
        return try await withCheckedThrowingContinuation { continuation in
            let id = UUID(); var settled = false; var timeout: Task<Void, Never>?
            let finish: @MainActor (Result<T, Error>) -> Void = { result in
                guard !settled else { return }; settled = true; timeout?.cancel(); owner.pending.removeValue(forKey: id)
                if case .success = result, owner.reader !== reader || owner.tagEpoch != tagEpoch { continuation.resume(throwing: CancellationError()) }
                else { continuation.resume(with: result) }
            }
            owner.pending[id] = { finish(.failure(CancellationError())) }
            if call.id != owner.call.id { call.cancellation.onCancel { [weak self] in finish(.failure(CancellationError())); self?.stopNfc(owner) } }
            guard !call.cancellation.isCancelled else { return }
            timeout = Task { @MainActor [weak self] in do { try await Task.sleep(nanoseconds: UInt64(owner.timeout * 1_000_000_000)); finish(.failure(self?.failure(call.method, "NFC operation timed out", .timeout) ?? CancellationError())); self?.stopNfc(owner) } catch {} }
            operation(finish)
        }
    }
    private func readNdef(_ owner: NFCResource, _ call: WeappHostApiCall) async throws {
        guard owner.connected, let tag = owner.tag else { throw CancellationError() }; let ndef = try ndefTag(tag)
        let message: NFCNDEFMessage
        do { message = try await nfcOperation(owner, call) { finish in ndef.readNDEF { message, error in Task { @MainActor in if let error { finish(.failure(error)) } else if let message { finish(.success(message)) } else { finish(.failure(WeappHostError(code: .invalidRequest, message: "empty NDEF response"))) } } } } }
        catch { let native = error as NSError; if native.domain == NFCErrorDomain && native.code == NFCReaderError.Code.ndefReaderSessionErrorZeroLengthMessage.rawValue { owner.lastRecords = .array([]); emitNfc(owner, event: "object:Ndef.onNdefMessage", values: ["records": .array([])]); return }; throw error }
        guard message.length <= 1024 * 1024, owner.connected else { throw failure(call.method, "NDEF message unavailable or exceeds budget") }
        let records: WeappJSON = .array(message.records.map { .object(["tnf": .number(Double($0.typeNameFormat.rawValue)), "type": binary($0.type), "id": binary($0.identifier), "payload": binary($0.payload)]) })
        owner.lastRecords = records
        emitNfc(owner, event: "object:Ndef.onNdefMessage", values: ["records": records])
    }
    private func emitNfc(_ owner: NFCResource, event: String, values: [String: WeappJSON], only subscriptionId: String? = nil) {
        guard !closed, foreground, let session else { return }
        for (id, (call, sequence)) in subscriptions where (subscriptionId == nil || subscriptionId == id) && call.method == event && !call.cancellation.isCancelled {
            let object = call.payload["objectId"].string ?? "", adapter = event.contains("Ndef.") ? ndefs[object] ?? "" : object
            guard adapters[adapter] === owner else { continue }
            let next = sequence + 1; subscriptions[id] = (call, next)
            do { _ = try session.emitHostApiEvent(["sessionId": call.context["sessionId"], "accountEpoch": call.context["account"]["epoch"], "objectId": .string(object), "subscriptionId": .string(id), "sequence": .string(String(next)), "value": .object(values)]) }
            catch { subscriptions.removeValue(forKey: id); stopNfc(owner); session.report(error); return }
        }
    }
    nonisolated public func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}
    nonisolated public func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.retiringReaders.removeValue(forKey: ObjectIdentifier(session)) != nil { self.checkRetirements(); return }
            guard let owner = self.adapters.values.first(where: { $0.reader === session }) else { return }
            self.stopNfc(owner, alreadyInvalidated: true); self.session?.report(error)
        }
    }
    nonisolated public func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        Task { @MainActor [weak self] in
            guard let self, self.foreground, let owner = self.adapters.values.first(where: { $0.reader === session }) else { return }
            guard tags.count == 1, let tag = tags.first else { session.alertMessage = "请只放置一个 NFC 标签"; session.restartPolling(); return }
            owner.tagEpoch &+= 1; owner.lastRecords = nil
            let pending = Array(owner.pending.values); for cancel in pending { cancel() }
            owner.tag = tag; owner.connected = false; owner.physicalConnected = false
            let id: Data, tech: String
            switch tag { case .miFare(let value): id = value.identifier; tech = "NFC_A"; case .iso7816(let value): id = value.identifier; tech = "ISO_DEP"; case .iso15693(let value): id = value.identifier; tech = "NFC_V"; case .feliCa(let value): id = value.currentIDm; tech = "NFC_F"; @unknown default: self.stopNfc(owner); return }
            do {
                try await self.nfcOperation(owner, owner.call) { finish in session.connect(to: tag) { error in Task { @MainActor in finish(error.map(Result.failure) ?? .success(())) } } }
                guard owner.reader === session else { return }; owner.physicalConnected = true
                let ndef = try self.ndefTag(tag)
                let state: NFCNDEFStatus = try await self.nfcOperation(owner, owner.call) { finish in ndef.queryNDEFStatus { status, _, error in Task { @MainActor in finish(error.map(Result.failure) ?? .success(status)) } } }
                guard owner.reader === session else { return }
                let techs = state == .notSupported ? [tech] : [tech, "NDEF"]
                self.emitNfc(owner, event: "object:NFCAdapter.onDiscovered", values: ["id": self.binary(id), "techs": .array(techs.map(WeappJSON.string))])
            } catch { self.stopNfc(owner); if !owner.call.cancellation.isCancelled { self.session?.report(error) } }
        }
    }
    private func stopNfc(_ owner: NFCResource, alreadyInvalidated: Bool = false) {
        let reader = owner.reader; owner.reader = nil; owner.tag = nil; owner.connected = false; owner.physicalConnected = false; owner.tagEpoch &+= 1; owner.lastRecords = nil
        let pending = Array(owner.pending.values); owner.pending.removeAll(); for cancel in pending { cancel() }
        if let reader, !alreadyInvalidated { retiringReaders[ObjectIdentifier(reader)] = reader; reader.invalidate() }
    }
    private func removeAdapter(_ id: String) { if let owner = adapters.removeValue(forKey: id) { stopNfc(owner) }; let children = Set(ndefs.filter { $0.value == id }.map(\.key)); ndefs = ndefs.filter { $0.value != id }; subscriptions = subscriptions.filter { !children.contains($0.value.0.payload["objectId"].string ?? "") && $0.value.0.payload["objectId"].string != id } }
    private func reset() { generation &+= 1; consent.reset(); uiFinish?(.failure(CancellationError())); for job in scanJobs.values { job.cancel() }; for context in authContexts.values { context.invalidate() }; authContexts.removeAll(); for owner in adapters.values { stopNfc(owner) }; adapters.removeAll(); ndefs.removeAll(); subscriptions.removeAll() }
    private func checkRetirements() {
        guard retiringReaders.isEmpty, uiRetirements == 0, scanJobs.isEmpty, activeCalls.isEmpty else { return }
        let waiting = retirementWaiters; retirementWaiters.removeAll()
        for (continuation, timer) in waiting.values { timer.cancel(); continuation.resume() }
    }
    private func drainRetirements() async throws {
        guard !retiringReaders.isEmpty || uiRetirements != 0 || !scanJobs.isEmpty || !activeCalls.isEmpty else { return }
        try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            let timer = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    if let self, let waiting = self.retirementWaiters.removeValue(forKey: id) { waiting.0.resume(throwing: self.failure("system.close", "native reader/editor/authorization retirement did not complete; retry cleanup", .timeout)) }
                } catch {}
            }
            retirementWaiters[id] = (continuation, timer)
        }
    }
    public func close() async throws { closed = true; reset(); try await drainRetirements(); if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }; backgroundObserver = nil }
}
