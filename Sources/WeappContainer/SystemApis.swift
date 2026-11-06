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
@MainActor public final class WeappSystemApis: NSObject, CNContactViewControllerDelegate, EKEventEditViewDelegate, PHPickerViewControllerDelegate, DataScannerViewControllerDelegate, UIAdaptivePresentationControllerDelegate {
    private weak var presenter: UIViewController?
    private weak var session: WeappContainerSession?
    private let files: WeappManagedFiles?
    private let scopes = WeappManagedFileScopes()
    private lazy var consent = WeappAppPermissionConsent(presenter: { [weak self] in self?.presenter }, auxiliaryRoot: { [unowned self] in try self.scopes.auxiliaryRoot($0) })
    private let signer: (any WeappSoterAttestationProvider)?
    private let nfc: WeappNfcApis?
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
    private var uiRetirements = 0
    private var retirementWaiters: [UUID: (CheckedContinuation<Void, Error>, Task<Void, Never>)] = [:]
    public init(presenter: UIViewController, files: WeappManagedFiles? = nil, soterAttestationProvider: (any WeappSoterAttestationProvider)? = nil, enableNfc: Bool = false, nfcConfiguration: WeappNfcConfiguration? = nil) {
        self.presenter = presenter; self.files = files; self.signer = soterAttestationProvider; self.nfc = (nfcConfiguration ?? (enableNfc ? WeappNfcConfiguration() : nil)).map { WeappNfcApis(presenter: presenter, configuration: $0) }
        super.init()
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.reset() } }
    }
    /// Source inventory only. supportedApis still applies real native/configuration gates.
    public static let potentialApis: Set<String> = ["object:IsoDep.close", "object:IsoDep.connect", "object:IsoDep.getHistoricalBytes", "object:IsoDep.isConnected", "object:IsoDep.setTimeout", "object:IsoDep.transceive", "object:MifareUltralight.close", "object:MifareUltralight.connect", "object:MifareUltralight.isConnected", "object:MifareUltralight.setTimeout", "object:MifareUltralight.transceive", "object:NFCAdapter.getIsoDep", "object:NFCAdapter.getMifareUltralight", "object:NFCAdapter.getNdef", "object:NFCAdapter.getNfcF", "object:NFCAdapter.getNfcV", "object:NFCAdapter.offDiscovered", "object:NFCAdapter.onDiscovered", "object:NFCAdapter.startDiscovery", "object:NFCAdapter.stopDiscovery", "object:NFCAdapter.tech", "object:Ndef.close", "object:Ndef.connect", "object:Ndef.isConnected", "object:Ndef.offNdefMessage", "object:Ndef.onNdefMessage", "object:Ndef.setTimeout", "object:Ndef.writeNdefMessage", "object:NfcF.close", "object:NfcF.connect", "object:NfcF.getMaxTransceiveLength", "object:NfcF.isConnected", "object:NfcF.setTimeout", "object:NfcF.transceive", "object:NfcV.close", "object:NfcV.connect", "object:NfcV.getMaxTransceiveLength", "object:NfcV.isConnected", "object:NfcV.setTimeout", "object:NfcV.transceive", "wx.addPhoneCalendar", "wx.addPhoneContact", "wx.addPhoneRepeatCalendar", "wx.checkIsSoterEnrolledInDevice", "wx.checkIsSupportSoterAuthentication", "wx.getNFCAdapter", "wx.scanCode", "wx.startSoterAuthentication"]
    public var supportedApis: Set<String> {
        var apis: Set<String> = ["wx.scanCode", "wx.checkIsSupportSoterAuthentication", "wx.checkIsSoterEnrolledInDevice"]
        if Bundle.main.object(forInfoDictionaryKey: "NSContactsUsageDescription") is String { apis.insert("wx.addPhoneContact") }
        let calendarKey: String
        if #available(iOS 17.0, *) { calendarKey = "NSCalendarsWriteOnlyAccessUsageDescription" } else { calendarKey = "NSCalendarsUsageDescription" }
        if Bundle.main.object(forInfoDictionaryKey: calendarKey) is String { apis.formUnion(["wx.addPhoneCalendar", "wx.addPhoneRepeatCalendar"]) }
        if signer != nil && !biometricModes().isEmpty { apis.insert("wx.startSoterAuthentication") }
        return apis.union(nfc?.supportedApis ?? [])
    }
    public func install(in target: WeappContainerSession) throws {
        guard session == nil, !closed else { throw failure("system", "adapter already installed or closed") }
        session = target; scopes.bind(target); try nfc?.install(in: target)
        let key = "system-\(UUID().uuidString)"
        // Retain this lifecycle owner until all native invalidation callbacks
        // and editor dismissals finish, including failed final-close retries.
        try target.registerHostResourceCleanup(key) { [self] in reset() }
        try target.registerHostAsyncResourceCleanup(key) { [self] in reset(); try await drainRetirements() }
        try target.registerHostVisibilityHandler(key) { [weak self] visible in self?.foreground = visible; if !visible { self?.reset() } }
        for api in supportedApis.subtracting(nfc?.supportedApis ?? []).sorted() {
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
        default: throw failure(api, "system API unavailable", .unsupported)
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
    private func reset() { generation &+= 1; consent.reset(); uiFinish?(.failure(CancellationError())); for job in scanJobs.values { job.cancel() }; for context in authContexts.values { context.invalidate() }; authContexts.removeAll() }
    private func checkRetirements() {
        guard uiRetirements == 0, scanJobs.isEmpty, activeCalls.isEmpty else { return }
        let waiting = retirementWaiters; retirementWaiters.removeAll()
        for (continuation, timer) in waiting.values { timer.cancel(); continuation.resume() }
    }
    private func drainRetirements() async throws {
        guard uiRetirements != 0 || !scanJobs.isEmpty || !activeCalls.isEmpty else { return }
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
    public func close() async throws { try await nfc?.close(); closed = true; reset(); try await drainRetirements(); if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }; backgroundObserver = nil }
}
