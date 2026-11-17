import Foundation
import UIKit
@preconcurrency import CoreNFC

/// Explicit host opt-in. CoreNFC, not this declaration, validates signed TAG entitlement.
public struct WeappNfcConfiguration: Sendable {
    public let ndef: Bool, isoDep: Bool, mifareUltralight: Bool, nfcF: Bool, nfcV: Bool
    public init(ndef: Bool = true, isoDep: Bool = false, mifareUltralight: Bool = false, nfcF: Bool = false, nfcV: Bool = false) {
        self.ndef = ndef; self.isoDep = isoDep; self.mifareUltralight = mifareUltralight; self.nfcF = nfcF; self.nfcV = nfcV
    }
}

/// Owns only this container's reader session and waits for its native terminal callbacks.
@MainActor public final class WeappNfcApis: NSObject, NFCTagReaderSessionDelegate {
    private weak var presenter: UIViewController?
    private weak var session: WeappContainerSession?
    private let configuration: WeappNfcConfiguration
    private let scopes = WeappManagedFileScopes()
    private lazy var consent = WeappAppPermissionConsent(presenter: { [weak self] in self?.presenter }, auxiliaryRoot: { [unowned self] in try self.scopes.auxiliaryRoot($0) })
    private var closed = false, foreground = false
    private var generation: UInt64 = 0
    private var backgroundObserver: NSObjectProtocol?
    private var retiringReaders: [ObjectIdentifier: NFCTagReaderSession] = [:]
    private var nativeOperations: Set<UUID> = []
    private var retirementWaiters: [UUID: (CheckedContinuation<Void, Error>, Task<Void, Never>)] = [:]
    private var adapters: [String: NFCResource] = [:]
    private struct Child { let parent: String; let technology: String; var epoch: UInt64? }
    private var children: [String: Child] = [:]
    private var subscriptions: [String: (WeappHostApiCall, UInt64)] = [:]
    private static weak var readerLease: WeappNfcApis?
    public init(presenter: UIViewController, configuration: WeappNfcConfiguration) {
        self.presenter = presenter; self.configuration = configuration; super.init()
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.reset() } }
    }
    /// Potential source capabilities; actual registration applies host/OS gates.
    public static let potentialApis: Set<String> = ["object:IsoDep.close", "object:IsoDep.connect", "object:IsoDep.getHistoricalBytes", "object:IsoDep.isConnected", "object:IsoDep.setTimeout", "object:IsoDep.transceive", "object:MifareUltralight.close", "object:MifareUltralight.connect", "object:MifareUltralight.isConnected", "object:MifareUltralight.setTimeout", "object:MifareUltralight.transceive", "object:NFCAdapter.getIsoDep", "object:NFCAdapter.getMifareUltralight", "object:NFCAdapter.getNdef", "object:NFCAdapter.getNfcF", "object:NFCAdapter.getNfcV", "object:NFCAdapter.offDiscovered", "object:NFCAdapter.onDiscovered", "object:NFCAdapter.startDiscovery", "object:NFCAdapter.stopDiscovery", "object:NFCAdapter.tech", "object:Ndef.close", "object:Ndef.connect", "object:Ndef.isConnected", "object:Ndef.offNdefMessage", "object:Ndef.onNdefMessage", "object:Ndef.setTimeout", "object:Ndef.writeNdefMessage", "object:NfcF.close", "object:NfcF.connect", "object:NfcF.getMaxTransceiveLength", "object:NfcF.isConnected", "object:NfcF.setTimeout", "object:NfcF.transceive", "object:NfcV.close", "object:NfcV.connect", "object:NfcV.getMaxTransceiveLength", "object:NfcV.isConnected", "object:NfcV.setTimeout", "object:NfcV.transceive", "wx.getNFCAdapter"]
    private var enabledTechnologies: Set<String> {
        var result: Set<String> = []
        if configuration.ndef { result.insert("Ndef") }
        if configuration.mifareUltralight { result.insert("MifareUltralight") }
        if configuration.nfcV { result.insert("NfcV") }
        if configuration.isoDep, let aids = Bundle.main.object(forInfoDictionaryKey: "com.apple.developer.nfc.readersession.iso7816.select-identifiers") as? [String], !aids.isEmpty, aids.allSatisfy({ $0.range(of: "^(?:[0-9a-fA-F]{2}){5,16}$", options: .regularExpression) != nil }) { result.insert("IsoDep") }
        if configuration.nfcF, let codes = Bundle.main.object(forInfoDictionaryKey: "com.apple.developer.nfc.readersession.felica.systemcodes") as? [String], !codes.isEmpty, codes.allSatisfy({ $0.range(of: "^[0-9a-fA-F]{4}$", options: .regularExpression) != nil && !$0.uppercased().hasPrefix("FF") && !$0.uppercased().hasSuffix("FF") }) { result.insert("NfcF") }
        return result
    }
    public var supportedApis: Set<String> {
        guard NFCTagReaderSession.readingAvailable, let usage = Bundle.main.object(forInfoDictionaryKey: "NFCReaderUsageDescription") as? String, !usage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let technologies = enabledTechnologies
        guard !technologies.isEmpty else { return [] }
        return Self.potentialApis.filter { api in
            if api.hasPrefix("object:NFCAdapter.get") { return technologies.contains(String(api.dropFirst("object:NFCAdapter.get".count))) }
            if api.hasPrefix("object:"), !api.hasPrefix("object:NFCAdapter.") { return technologies.contains(String(api.dropFirst(7).split(separator: ".")[0])) }
            return true
        }
    }
    public func install(in target: WeappContainerSession) throws {
        guard session == nil, !closed else { throw failure("nfc", "adapter already installed or closed") }; session = target; scopes.bind(target)
        let key = "nfc-\(UUID().uuidString)"
        try target.registerHostResourceCleanup(key) { [self] in reset() }
        try target.registerHostAsyncResourceCleanup(key) { [self] in reset(); try await drainRetirements() }
        try target.registerHostVisibilityHandler(key) { [weak self] visible in self?.foreground = visible; if !visible { self?.reset() } }
        for api in supportedApis.sorted() {
            try target.registerApiHandler(api) { [weak self] call in
                guard let self, !self.closed else { throw CancellationError() }
                do { return try await self.nfc(api, call, self.generation) }
                catch let error as WeappHostError { throw error }
                catch is CancellationError { throw self.failure(api, "cancel", .cancelled) }
                catch { let native = error as NSError; throw WeappHostError(code: .invalidRequest, message: native.localizedDescription, details: ["errCode": .number(Double(native.code)), "nativeDomain": .string(native.domain), "errMsg": .string("\(api):fail \(native.localizedDescription)")]) }
            }
        }
    }
    private func ok(_ api: String, _ values: [String: WeappJSON] = [:]) -> WeappJSON { .object(values.merging(["errMsg": .string("\(api):ok")]) { _, value in value }) }
    private func failure(_ api: String, _ message: String, _ code: WeappHostError.Code = .invalidRequest) -> WeappHostError { .init(code: code, message: message, details: ["errMsg": .string("\(api):fail \(message)")]) }
    private func live(_ call: WeappHostApiCall, _ accepted: UInt64) throws {
        try Task.checkCancellation(); guard !closed, foreground, generation == accepted, !call.cancellation.isCancelled else { throw CancellationError() }; _ = try scopes.descriptor(call.context)
    }
    private static let technologyValues = ["Ndef":"NDEF", "IsoDep":"ISO_DEP", "MifareUltralight":"MIFARE_ULTRALIGHT", "NfcF":"NFC_F", "NfcV":"NFC_V"]
    private final class NFCResource {
        let call: WeappHostApiCall
        var reader: NFCTagReaderSession?
        var readerBegan = false
        var starting: CheckedContinuation<Void, Error>?
        var tag: NFCTag?
        var connected = false, physicalConnected = false
        var tagEpoch: UInt64 = 0
        var activeOperation: String?
        var lastRecords: WeappJSON?
        var timeout: TimeInterval = 5
        var pending: [UUID: () -> Void] = [:]
        init(_ call: WeappHostApiCall) { self.call = call }
    }
    private func nfcOwner(_ call: WeappHostApiCall, child: Bool = false) throws -> NFCResource {
        let object = call.payload["objectId"].string ?? "", id = child ? children[object]?.parent ?? "" : object
        guard let owner = adapters[id], !owner.call.cancellation.isCancelled, sameOwner(owner.call.context, call.context) else { throw failure(call.method, "NFC object owner retired", .cancelled) }
        if child, var value = children[object], owner.tag != nil {
            if let epoch = value.epoch { guard epoch == owner.tagEpoch else { throw failure(call.method, "NFC technology object belongs to a retired tag", .cancelled) } }
            else { value.epoch = owner.tagEpoch; children[object] = value }
        }
        return owner
    }
    private func sameOwner(_ lhs: WeappJSON, _ rhs: WeappJSON) -> Bool { lhs["application"] == rhs["application"] && lhs["account"] == rhs["account"] && lhs["sessionId"] == rhs["sessionId"] }
    private func nfc(_ api: String, _ call: WeappHostApiCall, _ accepted: UInt64) async throws -> WeappJSON {
        try live(call, accepted)
        if api == "wx.getNFCAdapter" {
            guard !supportedApis.isEmpty, NFCTagReaderSession.readingAvailable, adapters.count < 16, let id = call.payload["objectId"].string, adapters[id] == nil else { throw failure(api, "NFC unavailable or object limit reached", .unsupported) }
            adapters[id] = NFCResource(call); call.cancellation.retainUntilCancelled(); call.cancellation.onCancel { [weak self] in self?.removeAdapter(id) }
            let tech = Dictionary(uniqueKeysWithValues: enabledTechnologies.compactMap { type -> (String, WeappJSON)? in guard let value = Self.technologyValues[type] else { return nil }; return (type.prefix(1).lowercased() + type.dropFirst(), .string(value)) })
            return ok(api, ["objectId": .string(id), "properties": .object(["tech": .object(tech)])])
        }
        if api.hasPrefix("object:NFCAdapter.get") {
            let technology = String(api.dropFirst("object:NFCAdapter.get".count))
            guard enabledTechnologies.contains(technology), let parent = call.payload["receiverId"].string, let owner = adapters[parent], sameOwner(owner.call.context, call.context), children.count < 64, let id = call.payload["objectId"].string, children[id] == nil else { throw failure(api, "NFC receiver unavailable", .cancelled) }
            children[id] = Child(parent: parent, technology: technology, epoch: owner.tag == nil ? nil : owner.tagEpoch)
            call.cancellation.retainUntilCancelled(); call.cancellation.onCancel { [weak self] in self?.children.removeValue(forKey: id) }
            return ok(api, ["objectId": .string(id)])
        }
        if api.hasSuffix(".onDiscovered") || api.hasSuffix(".onNdefMessage") || api.hasSuffix(".offDiscovered") || api.hasSuffix(".offNdefMessage") {
            guard let id = call.payload["subscriptionId"].string else { throw failure(api, "subscriptionId required") }
            if api.contains(".off") || call.payload["action"].string == "unsubscribe" {
                let object = call.payload["objectId"].string ?? "", parent = children[object]?.parent ?? object
                guard let owner = adapters[parent], sameOwner(owner.call.context, call.context) else { throw CancellationError() }
                subscriptions.removeValue(forKey: id)
            }
            else {
                _ = try nfcOwner(call, child: api.hasPrefix("object:Ndef."))
                guard subscriptions.count < 64 else { throw failure(api, "NFC subscription limit reached") }; subscriptions[id] = (call, 0); call.cancellation.retainUntilCancelled(); call.cancellation.onCancel { [weak self] in self?.subscriptions.removeValue(forKey: id) }
                let owner = try nfcOwner(call, child: api.hasPrefix("object:Ndef."))
                if api == "object:Ndef.onNdefMessage", owner.connected, let records = owner.lastRecords { emitNfc(owner, event: api, values: ["records": records], only: id) }
            }
            return ok(api)
        }
        let owner = try nfcOwner(call, child: !api.hasPrefix("object:NFCAdapter."))
        if !api.hasPrefix("object:NFCAdapter."), !api.hasPrefix("object:Ndef.") { return try await technology(api, call, owner, accepted) }
        let exclusive = api == "object:Ndef.connect" || api == "object:Ndef.writeNdefMessage"
        if exclusive { guard owner.activeOperation == nil else { throw failure(api, "another NDEF operation is active") }; owner.activeOperation = call.id }
        defer { if exclusive && owner.activeOperation == call.id { owner.activeOperation = nil } }
        switch api {
        case "object:NFCAdapter.tech": return ok(api)
        case "object:NFCAdapter.startDiscovery":
            guard adapters.values.allSatisfy({ $0.reader == nil }) else { throw failure(api, "another NFC discovery is active") }
            guard try await consent.request(call, "scope.nfc") else { throw failure(api, "auth deny", .permissionDenied) }; try live(call, accepted)
            guard owner.reader == nil, adapters.values.contains(where: { $0 === owner }) else { throw CancellationError() }
            guard Self.readerLease == nil, adapters.values.allSatisfy({ $0.reader == nil }), retiringReaders.isEmpty, nativeOperations.isEmpty else { throw failure(api, "another NFC reader is active or retiring") }
            var polling: NFCTagReaderSession.PollingOption = []
            if !enabledTechnologies.isDisjoint(with: ["Ndef", "IsoDep", "MifareUltralight"]) { polling.insert(.iso14443) }
            if !enabledTechnologies.isDisjoint(with: ["Ndef", "NfcV"]) { polling.insert(.iso15693) }
            if enabledTechnologies.contains("NfcF") { polling.insert(.iso18092) }
            guard let reader = NFCTagReaderSession(pollingOption: polling, delegate: self, queue: .main) else { throw failure(api, "NFC reader unavailable", .unsupported) }
            reader.alertMessage = "将 NFC 标签靠近手机顶部"; owner.reader = reader; Self.readerLease = self
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                owner.starting = continuation
                call.cancellation.onCancel { [weak self] in self?.stopNfc(owner) }
                if call.cancellation.isCancelled { stopNfc(owner) } else { owner.readerBegan = true; reader.begin() }
            }
            try live(call, accepted); return ok(api)
        case "object:NFCAdapter.stopDiscovery", "object:Ndef.close": stopNfc(owner); try await drainRetirements(); return ok(api)
        case "object:Ndef.isConnected": return ok(api, ["isConnected": .bool(owner.connected && owner.physicalConnected)])
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
    private func technology(_ api: String, _ call: WeappHostApiCall, _ owner: NFCResource, _ accepted: UInt64) async throws -> WeappJSON {
        guard let id = call.payload["objectId"].string, let child = children[id], let tag = owner.tag, let reader = owner.reader else { throw failure(api, "discover a matching tag first") }
        switch (child.technology, tag) {
        case ("IsoDep", .iso7816), ("NfcF", .feliCa), ("NfcV", .iso15693): break
        case ("MifareUltralight", .miFare(let value)) where value.mifareFamily == .ultralight: break
        default: throw failure(api, "discovered tag does not support this technology", .unsupported)
        }
        let method = String(api.split(separator: ".").last ?? "")
        if method == "isConnected" { return ok(api, ["isConnected": .bool(owner.connected && owner.physicalConnected)]) }
        if method == "setTimeout" {
            guard let milliseconds = call.payload["timeout"].number, milliseconds.isFinite, milliseconds.rounded() == milliseconds, (100...60000).contains(milliseconds) else { throw failure(api, "timeout must be an integer 100...60000 ms") }
            owner.timeout = milliseconds / 1000; return ok(api)
        }
        if method == "close" { stopNfc(owner); try await drainRetirements(); return ok(api) }
        if method == "getMaxTransceiveLength" {
            guard child.technology == "NfcF" || child.technology == "NfcV" else { throw failure(api, "CoreNFC exposes no hardware maximum for this technology", .unsupported) }
            return ok(api, ["length": .number(child.technology == "NfcF" ? 255 : 256)])
        }
        if method == "getHistoricalBytes", case .iso7816(let value) = tag {
            guard let data = value.historicalBytes else { throw failure(api, "this native tag has no Type A historical bytes", .unsupported) }
            return ok(api, ["histBytes": binary(data)])
        }
        guard owner.activeOperation == nil else { throw failure(api, "another NFC operation is active") }; owner.activeOperation = call.id
        defer { if owner.activeOperation == call.id { owner.activeOperation = nil } }
        if method == "connect" {
            if !owner.physicalConnected { try await nfcOperation(owner, call) { finish in reader.connect(to: tag) { error in Task { @MainActor in finish(error.map(Result.failure) ?? .success(())) } } } }
            try live(call, accepted); guard owner.reader === reader else { throw CancellationError() }
            owner.connected = true; owner.physicalConnected = true; return ok(api)
        }
        guard method == "transceive", owner.connected, owner.physicalConnected else { throw failure(api, "connect this technology before transceive") }
        let data = try bytes(call.payload["data"])
        guard !data.isEmpty, data.count <= 65544 else { throw failure(api, "transceive data must contain 1...65544 bytes") }
        let response: Data
        switch tag {
        case .iso7816(let value):
            guard let apdu = NFCISO7816APDU(data: data) else { throw failure(api, "CoreNFC supports valid ISO7816 APDU only", .unsupported) }
            response = try await nfcOperation(owner, call) { finish in value.sendCommand(apdu: apdu) { data, sw1, sw2, error in Task { @MainActor in finish(error.map(Result.failure) ?? .success(data + Data([sw1, sw2]))) } } }
        case .miFare(let value):
            response = try await nfcOperation(owner, call) { finish in value.sendMiFareCommand(commandPacket: data) { data, error in Task { @MainActor in finish(error.map(Result.failure) ?? .success(data)) } } }
        case .feliCa(let value):
            let packet = try WeappNfcFrames.felicaCommand(data)
            let result: Data = try await nfcOperation(owner, call) { finish in value.sendFeliCaCommand(commandPacket: packet) { data, error in Task { @MainActor in finish(error.map(Result.failure) ?? .success(data)) } } }
            response = try WeappNfcFrames.felicaResponse(result)
        case .iso15693(let value):
            let (flags, command, payload) = try WeappNfcFrames.vicinityCommand(data)
            response = try await nfcOperation(owner, call) { finish in value.sendRequest(requestFlags: Int(flags), commandCode: Int(command), data: payload) { result in Task { @MainActor in finish(result.map { Data([UInt8($0.0.rawValue)]) + ($0.1 ?? Data()) }) } } }
        @unknown default: throw failure(api, "unsupported native tag", .unsupported)
        }
        try live(call, accepted); guard response.count <= 1048576 else { throw failure(api, "native response exceeds 1 MiB") }
        return ok(api, ["data": binary(response)])
    }
    private func ndefTag(_ tag: NFCTag) throws -> any NFCNDEFTag { switch tag { case .miFare(let value): return value; case .iso7816(let value): return value; case .iso15693(let value): return value; case .feliCa(let value): return value; @unknown default: throw failure("NDEF", "unsupported NFC tag", .unsupported) } }
    private func binary(_ data: Data) -> WeappJSON { .object(["__weappBinary": .object(["type": .string("ArrayBuffer"), "bytes": .array(data.map { .number(Double($0)) })])]) }
    private func bytes(_ value: WeappJSON) throws -> Data {
        try WeappSystemApiPayloads.binary(value)
    }
    private func ndefMessage(_ call: WeappHostApiCall) throws -> NFCNDEFMessage {
        let value = call.payload; var records: [NFCNDEFPayload] = []
        let count = (value["texts"].array?.count ?? 0) + (value["uris"].array?.count ?? 0) + (value["records"].array?.count ?? 0)
        guard (1...64).contains(count) else { throw failure(call.method, "NDEF requires 1...64 records") }
        var budget = 0
        @MainActor func consume(_ size: Int) throws { guard size <= 1048576 - budget else { throw failure(call.method, "NDEF input exceeds 1 MiB") }; budget += size }
        for text in value["texts"].array ?? [] { guard let text = text.string else { throw failure(call.method, "invalid NDEF text") }; try consume(text.utf8.count + 3); guard let payload = NFCNDEFPayload.wellKnownTypeTextPayload(string: text, locale: Locale(identifier: "en")) else { throw failure(call.method, "invalid NDEF text") }; records.append(payload) }
        for uri in value["uris"].array ?? [] { guard let uri = uri.string else { throw failure(call.method, "invalid NDEF URI") }; try consume(uri.utf8.count); guard let payload = NFCNDEFPayload.wellKnownTypeURIPayload(string: uri) else { throw failure(call.method, "invalid NDEF URI") }; records.append(payload) }
        for record in value["records"].array ?? [] {
            guard let number = record["tnf"].number, number.isFinite, (0...7).contains(number), number.rounded() == number, let format = NFCTypeNameFormat(rawValue: UInt8(number)) else { throw failure(call.method, "record tnf required") }
            let type = try bytes(record["type"]), id = try bytes(record["id"]), data = try bytes(record["payload"])
            try consume(type.count + id.count + data.count)
            records.append(NFCNDEFPayload(format: format, type: type, identifier: id, payload: data))
        }
        guard !records.isEmpty, records.count <= 64 else { throw failure(call.method, "NDEF requires 1...64 records") }
        let message = NFCNDEFMessage(records: records); guard message.length <= 1024 * 1024 else { throw failure(call.method, "NDEF message exceeds 1 MiB") }; return message
    }
    private func nfcOperation<T>(_ owner: NFCResource, _ call: WeappHostApiCall, _ operation: (@escaping @MainActor (Result<T, Error>) -> Void) -> Void) async throws -> T {
        guard let reader = owner.reader, owner.pending.isEmpty else { throw failure(call.method, "NFC reader disconnected or busy") }
        let tagEpoch = owner.tagEpoch
        return try await withCheckedThrowingContinuation { continuation in
            let id = UUID(); var timeout: Task<Void, Never>?
            nativeOperations.insert(id)
            let boundary = WeappNfcNativeBoundary<T>(settle: { result in continuation.resume(with: result) }, terminal: { [self] in
                timeout?.cancel(); owner.pending.removeValue(forKey: id); nativeOperations.remove(id); checkRetirements()
            })
            owner.pending[id] = { boundary.cancel(CancellationError()) }
            call.cancellation.onCancel { [weak self] in boundary.cancel(CancellationError()); self?.stopNfc(owner) }
            guard !call.cancellation.isCancelled else { boundary.finish(.failure(CancellationError())); return }
            timeout = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(owner.timeout * 1_000_000_000)); boundary.cancel(self?.failure(call.method, "NFC operation timed out", .timeout) ?? CancellationError()); self?.stopNfc(owner) } catch {}
            }
            operation { result in
                if owner.reader !== reader || owner.tagEpoch != tagEpoch || call.cancellation.isCancelled { boundary.finish(.failure(CancellationError())) }
                else { boundary.finish(result) }
            }
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
            let object = call.payload["objectId"].string ?? "", adapter = event.contains("Ndef.") ? children[object]?.parent ?? "" : object
            guard adapters[adapter] === owner else { continue }
            if event.contains("Ndef."), children[object]?.epoch != owner.tagEpoch { continue }
            let next = sequence + 1; subscriptions[id] = (call, next)
            do { _ = try session.emitHostApiEvent(["sessionId": call.context["sessionId"], "accountEpoch": call.context["account"]["epoch"], "objectId": .string(object), "subscriptionId": .string(id), "sequence": .string(String(next)), "value": .object(values)]) }
            catch { subscriptions.removeValue(forKey: id); stopNfc(owner); session.report(error); return }
        }
    }
    nonisolated public func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        Task { @MainActor [weak self] in
            guard let owner = self?.adapters.values.first(where: { $0.reader === session }) else { return }
            let continuation = owner.starting; owner.starting = nil; continuation?.resume()
        }
    }
    nonisolated public func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.retiringReaders.removeValue(forKey: ObjectIdentifier(session)) != nil { self.checkRetirements(); return }
            guard let owner = self.adapters.values.first(where: { $0.reader === session }) else { return }
            let continuation = owner.starting; owner.starting = nil
            self.stopNfc(owner, alreadyInvalidated: true); continuation?.resume(throwing: error)
            self.checkRetirements(); self.session?.report(error)
        }
    }
    nonisolated public func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        Task { @MainActor [weak self] in
            guard let self, self.foreground, let owner = self.adapters.values.first(where: { $0.reader === session }) else { return }
            guard owner.pending.isEmpty else { self.stopNfc(owner); return }
            guard tags.count == 1, let tag = tags.first else { owner.tag = nil; owner.tagEpoch &+= 1; session.alertMessage = "请只放置一个 NFC 标签"; session.restartPolling(); return }
            owner.tagEpoch &+= 1; owner.lastRecords = nil; owner.tag = tag; owner.connected = false; owner.physicalConnected = false
            let id: Data; var techs: [String] = []
            switch tag {
            case .miFare(let value): id = value.identifier; if value.mifareFamily == .ultralight && self.enabledTechnologies.contains("MifareUltralight") { techs.append("MIFARE_ULTRALIGHT") }
            case .iso7816(let value): id = value.identifier; if self.enabledTechnologies.contains("IsoDep") { techs.append("ISO_DEP") }
            case .iso15693(let value): id = value.identifier; if self.enabledTechnologies.contains("NfcV") { techs.append("NFC_V") }
            case .feliCa(let value): id = value.currentIDm; if self.enabledTechnologies.contains("NfcF") { techs.append("NFC_F") }
            @unknown default: self.stopNfc(owner); return
            }
            do {
                try await self.nfcOperation(owner, owner.call) { finish in session.connect(to: tag) { error in Task { @MainActor in finish(error.map(Result.failure) ?? .success(())) } } }
                guard owner.reader === session else { return }; owner.physicalConnected = true
                if self.enabledTechnologies.contains("Ndef") {
                    let ndef = try self.ndefTag(tag)
                    let state: NFCNDEFStatus = try await self.nfcOperation(owner, owner.call) { finish in ndef.queryNDEFStatus { status, _, error in Task { @MainActor in finish(error.map(Result.failure) ?? .success(status)) } } }
                    if state != .notSupported { techs.append("NDEF") }
                }
                guard owner.reader === session else { return }
                guard !techs.isEmpty else { owner.tag = nil; owner.physicalConnected = false; owner.tagEpoch &+= 1; session.restartPolling(); return }
                self.emitNfc(owner, event: "object:NFCAdapter.onDiscovered", values: ["id": self.binary(id), "techs": .array(techs.map(WeappJSON.string))])
            } catch { self.stopNfc(owner); if !owner.call.cancellation.isCancelled { self.session?.report(error) } }
        }
    }
    private func stopNfc(_ owner: NFCResource, alreadyInvalidated: Bool = false) {
        let reader = owner.reader; owner.reader = nil; owner.tag = nil; owner.connected = false; owner.physicalConnected = false; owner.tagEpoch &+= 1; owner.lastRecords = nil
        let pending = Array(owner.pending.values); for cancel in pending { cancel() }
        let continuation = owner.starting; owner.starting = nil; continuation?.resume(throwing: CancellationError())
        if let reader, !alreadyInvalidated, owner.readerBegan { retiringReaders[ObjectIdentifier(reader)] = reader; reader.invalidate() }
        owner.readerBegan = false; checkRetirements()
    }
    private func removeAdapter(_ id: String) { if let owner = adapters.removeValue(forKey: id) { stopNfc(owner) }; let ids = Set(children.filter { $0.value.parent == id }.map(\.key)); children = children.filter { $0.value.parent != id }; subscriptions = subscriptions.filter { !ids.contains($0.value.0.payload["objectId"].string ?? "") && $0.value.0.payload["objectId"].string != id } }
    func reset() { generation &+= 1; consent.reset(); for owner in adapters.values { stopNfc(owner) }; adapters.removeAll(); children.removeAll(); subscriptions.removeAll() }
    private func checkRetirements() {
        guard retiringReaders.isEmpty, nativeOperations.isEmpty else { return }
        if Self.readerLease === self, adapters.values.allSatisfy({ $0.reader == nil }) { Self.readerLease = nil }
        let waiting = retirementWaiters; retirementWaiters.removeAll()
        for (continuation, timer) in waiting.values { timer.cancel(); continuation.resume() }
    }
    private func drainRetirements() async throws {
        guard !retiringReaders.isEmpty || !nativeOperations.isEmpty else { checkRetirements(); return }
        try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            let timer = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 5_000_000_000); if let self, let waiting = self.retirementWaiters.removeValue(forKey: id) { waiting.0.resume(throwing: self.failure("nfc.close", "native reader/transceive terminal pending; retry cleanup", .timeout)) } } catch {}
            }
            retirementWaiters[id] = (continuation, timer)
        }
    }
    public func close() async throws { closed = true; reset(); try await drainRetirements(); if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }; backgroundObserver = nil }
}
